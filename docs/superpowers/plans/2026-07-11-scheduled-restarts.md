# Geplante Neustarts (täglicher Cron)

Datum: 2026-07-11  
Status: Implementiert

## Entscheidungen (v1)

- Neustart **nur wenn online**; offline → skip + Eintrag in `logs/schedule.log` + `last_skip_at`
- **System-Zeitzone** in der UI angezeigt (Cron nutzt Lokalzeit)
- **Eine Uhrzeit pro Tag** (keine Mehrfachzeiten in v1)

## Ziel

Pro Instanz optional **einmal täglich** neu starten (LGSM + SteamCMD/Wine), konfigurierbar auf der Instanzseite unter Monitoring:

- Ein/Aus
- Uhrzeit (HH:MM, Server-Lokalzeit)
- sichtbarer Job in der Job-Übersicht (`scheduled_restart`)

## Architektur (LGSM-Stil)

| Komponente | Rolle |
|------------|--------|
| `$SERVER_DIR/.monitor/schedule` | `enabled=1`, `time=04:00`, `last_run=epoch` |
| `/etc/cron.d/linuxgsm-webcore-schedule` | pro aktiver Instanz eine Zeile als **Game-User** |
| `scripts/scheduled_restart_user.sh` | stop → start, Job + Live-Log wie bei manuellem Start |
| `manage.cgi` | Formular speichern → State + `rebuild_schedule_cron()` |
| `postinstall.pl` | Cron nach Modul-Update neu schreiben |

## Ablauf Worker

1. Cron triggert `scheduled_restart_user.sh <instance_id> <kind> <server_dir> <script> <module_root>`
2. Liest `schedule` — wenn `enabled=0`, exit 0
3. Prüft `last_run` (nicht zweimal am selben Kalendertag)
4. Legt Job an (`action=scheduled_restart`), führt aus:
   - **lgsm:** `./script stop` → `./script start` (als User)
   - **native:** `steamcmd_control_user.sh stop` → `start`
5. Schreibt `last_run`, Status ok/failed in Job

## UI (manage.cgi)

Unter Monitor-Block:

- Checkbox „Geplanter Neustart“
- Zeitfeld `HH:MM` (24h)
- Hinweis: Server muss laufen; bei manuellem Stop bleibt Schedule aktiv, startet aber erst nach erneutem Start (optional: trotzdem restart wenn offline — Entscheidung: **nur wenn online**, sonst skip + Log)

## Sicherheit

- Kein root auf Spieldaten; Cron-Zeile nur mit validiertem Unix-User
- Zeit/Einstellungen per `su` als Game-User in `.monitor/schedule` schreiben (wie Monitor-State)
- Neustart zählt nicht gegen Monitor-Backoff (separater Pfad)

## Tests

- `t/test_schedule_cron.pl` — Cron-Zeilen-Generierung
- `t/test_schedule_restart.sh` — Mock LGSM stop/start + Job-Datei

## Offen (v2+)

- Mehrere Zeiten pro Tag
