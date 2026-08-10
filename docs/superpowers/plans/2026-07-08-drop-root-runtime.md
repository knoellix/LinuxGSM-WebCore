# Plan: Root aus der Runtime entfernen (user-native Worker)

Datum: 2026-07-08
Status: **Implementiert** (2026-07-12) — Runtime user-native; verbleibendes Debt: einheitliche
Dispatch-Helfer (`user_worker_launch_cmd`) für alle Worker, keine neuen root-Worker.

## Ziel

Nach einem einmaligen **Root-Bootstrap** (User anlegen, Verzeichnisse, initiales
`chown`, System-Pakete, Firewall) läuft die gesamte **Runtime** (Minecraft
Loader/Mods/Modpack-Install, LGSM install/update, Start/Stop/Update/Validate,
Config-/Profil-Schreiben) zu **100 % als Game-User** — ohne Root-Operationen auf
Spieldaten.

Der einzige verbleibende Root-Touch zur Laufzeit ist der **Privilegien-Abwurf**
(`su` beim Dispatch), weil die Webmin-CGI als root läuft. Das ist *keine*
privilegierte Operation auf Spieldaten, sondern nur „root gibt Rechte ab".

## Warum das geht (Ist-Analyse)

Heutige Worker-Kategorien:

| Skript | Läuft heute als | Braucht echtes Root? | Interne `su`-Nutzung |
|---|---|---|---|
| `mc_java_install_user.sh` | user ✅ | nein | – (konvertiert, PR 2) |
| `mc_loader_install_user.sh` | user ✅ | nein | – (konvertiert, PR 2) |
| `mc_mod_install_user.sh` | user ✅ | nein | – (konvertiert, PR 2) |
| `game_action_user.sh` (LGSM install/update) | user ✅ | nein | – (konvertiert, PR 3) |
| `server_control.sh`, `engine_switch.sh` | – | – | gelöscht (tot, PR 3) |
| `steamcmd_control.sh` → `_user.sh` | root→user | nein (nur su-Dispatch) | sauber getrennt ✅ |
| `mc_modpack_install.sh` → `_user.sh` | root→user | nein (+Adopt-Root-Step) | sauber getrennt ✅ |
| `steamcmd_install.sh` → `_user.sh` | root→user | **ja** (apt-Deps) | Root-Phase + User-Phase ✅ |
| `setup_lgsm.sh` | root | **ja** (apt-Deps, dpkg arch) | Root-Phase + su-Download |
| `provision.pl` | root | **ja** (useradd/mkdir/chown/rollback) | – |
| `firewall.pl` | root | **ja** (Webmin Firewall-API) | – |

**Erkenntnis:** Bei den vier „root-aber-nur-su" Skripten braucht nicht die
*Aufgabe* Root, sondern nur unser *Aufrufmodell*. Wenn wir sie — wie bei
SteamCMD/Modpack bereits erprobt — direkt **als User** starten, fällt jede
interne `su` weg und alle Dateien gehören sauber dem User.

Referenzmodelle existieren schon: `steamcmd_control.sh` (reiner su-Dispatch) und
`steamcmd_install.sh` (Root-Deps-Phase → User-Phase).

## Zielarchitektur

### 1. Einmaliger Root-Bootstrap (bei Provisionierung)

Alles Root wird nach vorne gezogen, damit die Runtime rein user-nativ ist:

- `useradd -m -s /usr/sbin/nologin` (+ Rollback `userdel -r -f`)
- `$SERVER_DIR` anlegen + **einmaliges** `chown` auf den User
- **System-Pakete vorab**: bekannte `apt_deps` aus `games_meta.json` +
  Runtime-Deps (wine etc.) beim Anlegen installieren (statt später im Worker)
- Firewall-Regeln (Webmin-API)
- optional Root-/System-Cron (Monitor global), falls genutzt
- Markierung `bootstrap_done`

### 2. User-native Runtime (Perl-Dispatch-Helper)

Ein **einziger** Perl-Helper `user_worker_launch_cmd()` (in `jobs.pl`) erzeugt das
`su`-gewrappte, backgroundete Kommando und ersetzt die verstreuten
`setsid nohup bash <worker>` (root) Strings. **Kein zusätzliches Shell-Skript.**

```perl
my $cmd = user_worker_launch_cmd(
    unix_user   => $unix_user,
    module_root => $module_root,
    worker      => "$module_root/scripts/<worker>.sh",
    args        => [ $job_dir, $unix_user, $server_dir, ... ],
    env         => { STEAMCMD_PATH => ... },   # optional
);
# -> setsid nohup su -s /bin/bash -c "MODULE_ROOT=... exec bash <worker> <args>" <user> &
```

- Der Helper macht **nichts** außer Env setzen + Privilegien abwerfen.
- Garantie: kein Runtime-Worker läuft mehr privilegiert.
- Zentral getestet (String-Form + Quoting), überall statt Ad-hoc-Kommandos.

### 3. Worker werden `_user` (kein internes `su` mehr)

Konvertieren zu Game-User-Workern (Muster: `mc_modpack_install_user.sh`):

- `job_log_init` → `job_log_init_as_user`
- alle `su -s /bin/bash -c "…" $UNIX_USER` entfernen → direkte Befehle
- Datei-/Profil-/Meta-Writes direkt (Dateien gehören dem User)

Betroffen:
- `mc_java_install.sh` → `mc_java_install_user.sh` ✅ (PR 2)
- `mc_loader_install.sh` → `mc_loader_install_user.sh` ✅ (PR 2)
- `mc_mod_install.sh` → `mc_mod_install_user.sh` ✅ (PR 2)
- `game_action.sh` → `game_action_user.sh` ✅ (PR 3)
- `server_control.sh`, `engine_switch.sh` → gelöscht (toter Code, nicht referenziert) ✅ (PR 3)

### 4. Perl-Libs: Direkt-Write statt `su`

- `mc_profile.pl` `write_mc_profile()`: Direkt-Schreibpfad, wenn der Prozess
  bereits der Ziel-User ist (`$> == (getpwnam($user))[2]`), sonst wie bisher via
  `su` (Root-Kontext, z. B. Provisionierung/Adopt).
- Gleiches Prinzip für Profil-Merge/Meta-Schreiber.
- Damit entfällt der Root-Umweg im Adopt-Schritt: **Manifest = Source of Truth**
  kann komplett im User-Worker laufen (Java→Loader gepinnt→Mods in einem Job) —
  löst den offenen Punkt aus dem Modpack-first-Plan.

### 5. Root-only (bleibt bewusst root)

- User-Management (useradd/userdel/usermod)
- initiales `mkdir` + einmaliges `chown` von `$SERVER_DIR`
- `apt`/dpkg (System-Pakete)
- Firewall (Webmin-API)
- globale System-Cron/Dienste

## Umsetzung in PR-Blöcken (kein Big Bang)

**PR 1 — Fundament (risikoarm, keine Verhaltensänderung)**
- `run_as_user.sh` Shim + `dispatch_user_worker()` Helper einführen
- `write_mc_profile()` Direkt-Write-Pfad (euid==user) + Tests
- Security-Regel `security-isolation.mdc` um das neue Modell ergänzen

**PR 2 — Minecraft user-native**
- `mc_java/loader/mod_install` → `_user`-Worker, Dispatch via Shim
- Adopt/Modpack-Orchestrierung komplett in den User-Job ziehen
  (Java→Loader gepinnt→Mods, ein Status, ein Live-Log)
- MC-Provision: sicherstellen, dass keine apt-Deps nötig sind (unzip/curl prüfen
  ggf. im Bootstrap)
- Tests: `t/test_mc_*`, Loader-Pin-Regression

**PR 3 — LGSM/Steam Runtime user-native** ✅ (Runtime-Worker-Teil)
- `game_action.sh` → `game_action_user.sh` (user-nativ, kein internes `su`) ✅
- Dispatch der 5 LGSM-Stellen in `manage.cgi` (install/update/validate/reinstall/
  start-stop) auf `user_worker_launch_cmd()` umgestellt ✅
- Tote Skripte `server_control.sh`/`engine_switch.sh` gelöscht ✅
- Neue Invariante-Test `t/test_user_native_workers.pl`: kein `_user.sh` enthält
  internes `su -s /bin/bash` ✅
- **Verschoben nach PR 4** (weil Provisioning-Änderung): apt-Deps von
  `setup_lgsm.sh`/`steamcmd_install.sh` in den Root-Bootstrap vorziehen. Diese
  beiden bleiben bis dahin bewusst das dokumentierte Modell „Root-Deps-Phase →
  User-Phase". Der eigentliche Runtime-Pfad (Start/Stop/Update/Validate,
  Reinstall, MC-Installs) ist bereits root-frei.

**PR 4 — Bootstrap-Konsolidierung & Aufräumen** ✅ (apt→Bootstrap)
- Neuer Root-Worker `provision_deps.sh`: einmaliger apt-Bootstrap (i386 +
  contrib/non-free, Basis-Tools, per-Game `apt_deps`, Wine-Runtime). ✅
- apt aus `setup_lgsm.sh` + `steamcmd_install.sh` entfernt → beide apt-frei
  (bleiben reine su-Dispatch/Download-Wrapper). ✅
- Neue Job-Action `provision_deps` (manage.cgi) mit Live-Log; der Wizard leitet
  nach dem Anlegen **immer** zuerst dorthin. ✅
- Modpack-first-Kette: Pack wird gestasht (`$config_directory/.pending_modpack_*`)
  und startet automatisch, sobald der Deps-Job zurück auf die Instanzseite
  landet (`job_notice=ok`) — JS-unabhängig. ✅
- Invarianten-Test erweitert: `setup_lgsm.sh`/`steamcmd_install.sh` ohne
  `apt-get`; `provision_deps.sh` ist der einzige apt-Owner. ✅
- **Offen / optionales Aufräumen**: die verbliebenen su-Dispatch-Wrapper
  (`setup_lgsm.sh`, `steamcmd_install.sh`, `steamcmd_control.sh`,
  `mc_modpack_install.sh`) auf `user_worker_launch_cmd()` vereinheitlichen bzw.
  wo möglich ganz entfernen. Sicherheitsziel ist bereits erreicht (kein
  Runtime-/Install-Worker fasst apt an; Spieldaten gehören dem User).
- **Hinweis**: Legacy `provision.cgi` (`provision_server` → `install_lgsm.sh`)
  bleibt unverändert und ist nicht Teil des Wizard-Flows.

## Migration / Kompatibilität

- **Bestehende Instanzen**: Job-Dir liegt bereits unter `/home/<user>/jobs/`
  (siehe `steamcmd_control.sh`-Kommentar); user-native Logging ist erprobt.
  Sicherstellen, dass Alt-Instanzen korrektes Ownership haben (einmaliges
  Repair-`chown` im Bootstrap/Adopt-Pfad).
- **Root-erzeugte Dateien** aus der alten Welt (z. B. root-owned serverfiles nach
  altem Loader-Install) via einmaligem `chown -R` beim ersten user-nativen Lauf
  reparieren.
- Rückwärtskompatibel ausrollen: Shim + Direkt-Write zuerst (PR1), Worker
  einzeln umstellen; alte Root-Wrapper erst am Ende entfernen.

## Sicherheit / Regeln

- Neues Invariant: **kein Runtime-Worker führt privilegierte Operationen aus**;
  der einzige `su` ist der Dispatch-Privilegien-Abwurf.
- `security-isolation.mdc` und `workers-shell.mdc` entsprechend aktualisieren.
- `t/test_security_guards.pl`: Guard gegen Reintroduktion von root-Writes auf
  `$SERVER_DIR`.

## Entscheidungen (festgelegt 2026-07-08)

1. **apt-Deps komplett in den Bootstrap vorziehen** → Runtime ist danach 100 %
   root-frei. Alle bekannten `apt_deps`/Runtime-Deps werden bei der
   Provisionierung installiert; kein Install-Worker fasst mehr `apt` an.
2. **Kein zusätzliches Shell-Skript** → der Privilegien-Abwurf wird als reiner
   **Perl-Dispatch-Helper** (`user_worker_launch_cmd()` in `jobs.pl`) gebaut, der
   das `su`-gewrappte, backgroundete Kommando erzeugt. Ersetzt die verstreuten
   `setsid nohup bash <worker>`-Strings.
3. **Ein User-Job**: Modpack-Adopt + Java + Loader (gepinnt) + Mods laufen in
   **einem** Game-User-Job (ein Status, ein Live-Log).
4. **Reparatur voll automatisch**: einmaliges `chown -R` auf `$SERVER_DIR` +
   Job-Dir wird beim Bootstrap bzw. beim ersten user-nativen Lauf automatisch
   ausgeführt (kein manueller Button).
```
