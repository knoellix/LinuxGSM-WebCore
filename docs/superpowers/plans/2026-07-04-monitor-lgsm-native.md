# Monitoring: LGSM-native, root-frei, zuverlässig

**Datum:** 2026-07-04
**Status:** Umgesetzt
**Kontext:** Bestehendes Watchdog-Monitoring soll LGSM-first werden, der root-Cron entfällt, Auto-Neustart bei Problemen muss sehr zuverlässig laufen.

## Getroffene Entscheidungen (umgesetzt)
- Cron-Mechanismus: **eine `/etc/cron.d`-Datei, pro Instanz eine Zeile mit Benutzerfeld**.
  **Alle** Instanzen (LGSM und steamcmd/native) laufen als **Game-User** via
  `monitor_instance_user.sh` — kein root-Cron für Monitoring.
- Intervall: **alle 5 Minuten** (LGSM-Standard).
- Umbau: **vollständig** (Source-Fix + root-Cron entfernt + per-Instanz-Cron + robustes Status-Parsing).

**Hinweis (2026-07-12):** Frühere Plan-Versionen erwähnten noch root-Cron für Nicht-LGSM;
das ist obsolet — siehe `steamcmd-user-native.md` und `monitor.pl` (`monitor_cron_line`).

---

## 1. Ist-Zustand

### Ablauf heute
- `/etc/cron.d/linuxgsm-webcore-monitor` läuft **als root** alle 2 Min → `monitor_all.sh`.
- `monitor_all.sh` liest `instances`, `su` zum Game-User → `monitor_instance_user.sh` (PID-Check, A2S, State), root-Wrapper macht Neustart-Dispatch (`nice -n -5` braucht root).
- Zwei Pfade in `monitor_instance_user.sh`:
  - **LGSM-Pfad** (`INST_SOURCE == "lgsm"`): `./script monitor` + `./script status | grep ONLINE`.
  - **Nicht-LGSM-Pfad**: `run.pid`-Check + A2S-Query + Neustart via `steamcmd_control.sh start`.

### Bug 1 — Source-Mismatch (kritisch)
LGSM-Spiele (inkl. Minecraft `mcserver`) werden mit `source = provisioned` registriert
(`wizard.cgi`: `($game_source eq 'lgsm') ? 'provisioned' : $game_source`).
Der Monitor prüft aber auf `== "lgsm"`. Bestätigt an Live-Daten:

```
gs_mc_atm_atm10   ...  /home/gs_mc_atm/atm10/mcserver   provisioned  ...
gs_windrose_...   ...  /home/.../windrose               steamcmd     ...
```

→ `provisioned != lgsm` ⇒ MC fällt in den **Nicht-LGSM-Pfad**:
1. `run.pid` existiert bei LGSM/MC nicht (nur steamcmd/Wine erzeugen sie) → gilt immer als „tot".
2. A2S-Query passt nicht zu Minecraft → Timeout → Fehlalarm „freeze".
3. Neustart über `steamcmd_control.sh start` ist für MC falsch (müsste `./mcserver start` sein).

Effektiv wird der `== "lgsm"`-Zweig für reale Instanzen nie erreicht.

### Bug 2 — Cron läuft als root
Widerspricht LGSMs Design (Monitor als Game-User) und `security-isolation.mdc`
(keine Game-Ops als root). Root-Neustart kann root-eigene Dateien im Server-Dir erzeugen.

### Weitere Schwächen
- `grep -ci 'ONLINE' || echo "0"` ist fragil (grep gibt bei 0 Treffern „0" **und** Exit 1 →
  doppelte Ausgabe → Bash-Arithmetikfehler möglich).
- `monitor_instance.sh` ist deprecated, dupliziert aber die gesamte Logik → Drift-Risiko.
- Magic-String `"lgsm"` an mehreren Stellen statt zentraler Typ-Erkennung.

---

## 2. Zielbild

**Grundsatz:** LGSM ist die Autorität für LGSM-Spiele. Wir bauen dessen Health-Check/Restart
nicht nach, sondern rufen `./script monitor` als Game-User auf. LGSM prüft Status (Query),
startet nur neu, wenn der Server laut Lockfile laufen *soll* (respektiert bewusstes Stop),
und macht optional Alerts.

### A) LGSM-Instanzen (source != steamcmd)
- Monitoring = **Cron-Eintrag als Game-User**: `*/N * * * * /home/<user>/<script> monitor > /dev/null 2>&1`.
- Verwaltung über **Webmin Cron-Modul** (`foreign_require('cron','cron-lib.pl')`,
  `create_cron_job`/`delete_cron_job`, Feld `user => <gameuser>`). Webmin-native-first.
- Enable = Cron-Job anlegen; Pause/Disable/Stop = Cron-Job entfernen.
  LGSMs Lockfile kennt den Soll-Zustand → kein Kampf gegen bewusstes Stoppen.
- Kein eigener `.monitor/state`-Automat nötig; UI-Status = „Cron vorhanden?".

### B) Nicht-LGSM (steamcmd/Wine)
- Ebenfalls **als Game-User** in Cron (kein root).
- Watchdog-Logik (`monitor_instance_user.sh`, PID + optional A2S) bleibt, aber Neustart via
  `steamcmd_start_user.sh` (läuft bereits als Game-User) statt `steamcmd_control.sh`.
- `nice -n -5` entfällt bzw. best-effort ohne root (`nice`/`ionice` im User-Limit).
- Restart-Backoff/Zähler (`.monitor/state`, max N pro Fenster) bleibt hier erhalten (LGSM verwaltet diese nicht).

### C) Root-Cron entfernen
- `postinstall.pl`: vorhandenes `/etc/cron.d/linuxgsm-webcore-monitor` **entfernen** (Migration).
- `_ensure_monitor_cron()` → per-User-Cron via Webmin-Cron-API statt Kopie nach `/etc/cron.d`.
- `monitor_all.sh` wird nicht mehr per Cron installiert (optional als manuelles „alle jetzt prüfen"-Tool behalten, aber nicht als root-Cron).

### D) Zentrale Typ-Erkennung
- Helper `instance_is_lgsm($source)` / `instance_monitor_kind(...)`: LGSM außer `source eq 'steamcmd'`
  (und künftige Nicht-LGSM-Marker). Ersetzt Magic-String an allen Stellen und behebt Bug 1.

### E) Zuverlässigkeit
- LGSM-Restart ist Lockfile-gated (kein Fight gegen Stop, kein Restart bei bewusstem Stop).
- Optionaler Alarm via `logger`, wenn LGSM wiederholt neu startet (Schleifen sichtbar).
- Nur **ein** Monitor-Mechanismus aktiv (kein Doppel-Watchdog).

---

## 3. Offene Entscheidungen (vor Umsetzung klären)

1. **Cron-Mechanismus für Game-User (Kernfrage):**
   - (a) **Per-User-Crontab** (`crontab -u <user>` / Webmin `cron` mit `user=>`): LGSM-kanonisch.
   - (b) **System `/etc/cron.d`-Zeile mit Benutzerfeld** (`*/N * * * * <user> /home/.../script monitor`):
     zentral verwaltbar, läuft trotzdem als Game-User.
   - **Risiko bei beiden:** Game-User hat `/usr/sbin/nologin`. Cron führt Kommandos zwar
     shell-unabhängig aus, aber PAM (`crond`-Service unter Arch/cronie) könnte nologin-User
     ablehnen. **Muss auf dem Zielsystem (CachyOS/cronie) verifiziert werden.**
   - Fallback falls PAM blockt: cron.d-Zeile mit User-Feld + ggf. PAM-Anpassung, oder systemd-Timer.

2. **Intervall:** LGSM empfiehlt ~5 Min; für schnellere Recovery ggf. 2–3 Min. Vorschlag: 3 Min.

3. **Migration bestehender Instanzen:** beim Upgrade root-Cron entfernen und für laufende
   Instanzen die neuen per-User-Crons anlegen (oder erst beim nächsten Start/Enable).

---

## 4. Umsetzungsschritte (nach Klärung)

1. Helper `instance_is_lgsm()` in `instance.pl` (+ Test).
2. `monitor_instance_user.sh`: LGSM-Pfad über Helper, robustes Status-Parsing (Exit-Code statt grep-Trick).
3. Nicht-LGSM-Neustart auf `steamcmd_start_user.sh` umstellen (kein root).
4. Cron-Verwaltung: `_ensure_monitor_cron()` → Webmin-Cron per Game-User; Enable/Disable = Job an/aus.
5. `postinstall.pl`: root-Cron entfernen (Migration).
6. `monitor_all.sh` aus dem Cron-Pfad nehmen; deprecated `monitor_instance.sh` löschen.
7. UI (`manage.cgi`): Monitor-Status aus Cron-Präsenz ableiten; Buttons anpassen.
8. Lang-Keys de/en anpassen.
9. Tests: `t/test_monitor_state.pl` erweitern; neuer Test für `instance_is_lgsm` und Cron-Toggle-Logik.
10. `bash scripts/verify.sh` grün.

---

## 5. Betroffene Dateien
- `src/lib/instance.pl` (Helper)
- `src/lib/monitor.pl` (State ggf. vereinfachen)
- `src/scripts/monitor_instance_user.sh`, `monitor_all.sh`, `monitor_instance.sh` (löschen)
- `src/scripts/linuxgsm-webcore-monitor.cron` (entfällt / ersetzt)
- `src/manage.cgi` (`_ensure_monitor_cron`, Monitor-Actions, UI)
- `src/postinstall.pl` (Migration)
- `src/lang/de`, `src/lang/en`
- `t/test_monitor_state.pl` (+ neue Tests)
