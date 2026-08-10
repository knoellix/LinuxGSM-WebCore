# steamcmd/Wine: user-native control + monitoring

**Datum:** 2026-07-04  
**Status:** Umgesetzt  
**Vorgänger:** `2026-07-04-monitor-lgsm-native.md`

## Ziel

Nicht-LGSM-Spiele (steamcmd/Wine, z. B. Windrose) starten/stoppen und überwachen **als Game-User** — kein root-Cron, keine root-Neustarts. Gleiches Muster wie `steamcmd_install.sh` → `steamcmd_install_user.sh`.

## Migration (keine Server-Neuinstallation)

| Was | Aktion |
|-----|--------|
| Game-Dateien (`serverfiles/`, `.wine-*`, Launcher) | **unverändert** |
| Registry (`instances`) | **unverändert** |
| Modul | `.wbm` installieren / `postinstall.pl` baut Cron neu |
| Cron | Automatisch bei Upgrade oder einmal Start/Stop/Monitor-Toggle |
| Laufender Server | Optional einmal Stop→Start nach Upgrade (empfohlen, nicht zwingend) |

**Neuinstallation der Game-Instanz ist nicht nötig.**

## Architektur

```
manage.cgi (Webmin/root)
  └─ steamcmd_control.sh          ← dünner su-Dispatch
       └─ steamcmd_control_user.sh  ← echte Logik (Game-User)

/etc/cron.d (Game-User-Zeile)
  └─ monitor_instance_user.sh native
       └─ steamcmd_control_user.sh start   ← Neustart ohne root
```

- `PRIO_HIGH` (`nice -n -5`) entfällt im User-Worker — default Scheduling.
- Monitor-Job-Records bei Auto-Restart: `sync_monitor_job_pointers()` in `jobs.pl` spiegelt
  Game-User-Jobs unter `/home/<user>/jobs/` als Pointer in Webmin — kein root-Writer nötig.

## Bekannte Design-Schuld (offen / akzeptiert)

| Thema | Status |
|-------|--------|
| Webmin-CGI dispatcht Worker noch via root → su | OK (einmalige Privilegien-Grenze) |
| `steamcmd_install.sh` root für apt | OK (apt braucht root) |
| `provision.pl` chown nach mkdir | OK (einmalig bei Provisionierung) |
| `jobs.pl` chown für Job-Pointer unter `/etc/webmin` | OK (Webmin-Job-UI) |
| `source=provisioned` vs `lgsm` | **behoben** (`instance_is_lgsm`) |
| root-Monitor-Cron | **behoben** (pro Instanz, Game-User) |
| root steamcmd restart | **behoben** (`steamcmd_control_user.sh`) |

## Dateien

- Neu: `src/scripts/steamcmd_control_user.sh`
- Geändert: `steamcmd_control.sh`, `monitor_instance_user.sh`, `monitor.pl`, `postinstall.pl`
- Entfernt: `monitor_native_root.sh`
