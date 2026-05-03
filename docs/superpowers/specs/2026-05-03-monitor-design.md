# Monitor-Feature Design

**Datum:** 2026-05-03
**Status:** Genehmigt

## Ziel

Automatisches Monitoring aller verwalteten Game-Server: Crash-Erkennung via PID-Check,
Freeze-Erkennung via A2S-Query, Auto-Restart (max. 5×/Stunde), Pause bei manuellem Stop,
und Player-Count-Anzeige auf der Instanz-Seite.

## Architektur-Überblick

```
/etc/cron.d/linuxgsm-webcore-monitor   (alle 2 Min, root)
  └─ monitor_all.sh
       └─ für jede Instanz: monitor_instance.sh <id> <user> <type> <query_port>

Perl-Seite (nur bei CGI-Aufruf):
  src/lib/query.pl     ← a2s_query() für Player-Count in manage.cgi
  src/lib/monitor.pl   ← State lesen/schreiben, Status-Abfragen
```

## Neue Dateien

| Datei | Zweck |
|-------|-------|
| `src/scripts/monitor_all.sh` | Iteriert alle Instanzen, ruft monitor_instance.sh auf |
| `src/scripts/monitor_instance.sh` | Prüft eine Instanz, LGSM-Delegation oder eigener Flow |
| `src/scripts/query_a2s.pl` | CLI-Wrapper für A2S-Query (Exit 0 = ok, JSON-Output) |
| `src/lib/query.pl` | Pure-Perl A2S-Query-Lib (eingebunden in manage.cgi) |
| `src/lib/monitor.pl` | State-Datei lesen/schreiben, Status-Helfer |

## Geänderte Dateien

| Datei | Änderung |
|-------|----------|
| `src/manage.cgi` | Player-Count-Anzeige, State-File bei Start/Stop schreiben |
| `games_meta.json` | Neuer Key `query_port_field` pro Game-Eintrag |
| `src/index.cgi` (Instanzliste) | Monitor-Status-Badge (running/failed/paused) |

## State-File

**Pfad:** `$config_dir/monitor/<instance_id>/state`

```ini
restart_count=3
window_start=1746270000
status=running
```

### Status-Werte

| Status | Bedeutung |
|--------|-----------|
| `running` | Server läuft, Monitor aktiv |
| `restarting` | Auto-Restart wird gerade durchgeführt |
| `failed` | 5 Restarts/Stunde erreicht — kein weiterer Auto-Restart |
| `disabled` | Monitoring für diese Instanz dauerhaft deaktiviert |
| `paused` | Server manuell gestoppt — Monitor pausiert bis manueller Start |

**Initialisierung:** Existiert kein State-File beim ersten Monitor-Lauf, wird es mit
`restart_count=0`, `window_start=<now>`, `status=running` angelegt.

## LGSM-Server vs. Non-LGSM-Server

### LGSM-Server (z.B. Minecraft, CS2, Valheim via LGSM)

`monitor_instance.sh` delegiert vollständig:
```bash
su -s /bin/bash -c "./$script_name monitor" "$user"
```
LGSM übernimmt PID-Check, Query-Check und Restart intern.
Danach: LGSM-Status auslesen und ins State-File schreiben (für Webmin-Anzeige).
Player-Count: A2S-Query in `manage.cgi` wenn verfügbar.

### Non-LGSM-Server (Windrose / Wine / UE5)

Eigener Flow in `monitor_instance.sh`:

```
1. PID-Check: ps aux | grep <user>
   → kein PID: direkter Crash → Restart-Flow
2. A2S-Query: perl query_a2s.pl <host> <query_port>
   → Timeout (2s): Freeze erkannt → Restart-Flow
3. Beide ok: status=running, kein Eingriff
```

## Restart-Flow

```
1. Ausfall erkannt (PID weg ODER A2S-Timeout)
2. window_start älter als 3600s? → window_start=now, restart_count=0 (Fenster reset)
3. restart_count >= 5? → status=failed, Webmin-Log-Eintrag, STOP
4. restart_count++, status=restarting
5. Neustart-Kommando ausführen
6. 30s warten, erneut prüfen
7. Läuft wieder → status=running
8. Läuft nicht → beim nächsten Cron-Tick erneut geprüft (restart_count steigt)
```

**Benachrichtigung bei `failed`:** Eintrag in Webmin-Log (kein E-Mail in v1).

**Reset durch Admin:** Button "Monitoring aktivieren" auf Instanz-Seite
→ schreibt `status=running`, `restart_count=0`.

## Monitor-Pause bei manuellem Start/Stop

`manage.cgi` schreibt bei jeder manuellen Aktion ins State-File:

| Aktion | State-File-Änderung |
|--------|---------------------|
| Manueller Stop | `status=paused` |
| Manueller Start | `status=running`, `restart_count=0` |

`monitor_instance.sh` überspringt Instanzen mit `status=paused` oder `status=disabled`
vollständig — kein ungewollter Auto-Restart bei bewusstem manuellem Stop.

## A2S-Query-Implementierung

**`src/lib/query.pl`** — Pure Perl, keine externen Module:

```perl
sub a2s_query {
    my ($host, $port, $timeout) = @_;
    $timeout //= 2;
    # UDP-Socket via IO::Socket::INET
    # Request: "\xFF\xFF\xFF\xFF\x54Source Engine Query\x00"
    # select()-basierter Timeout
    # Parsed: players, max_players
    # Returns: { players => N, max => M } oder undef bei Fehler/Timeout
}
```

**Kein Passwort-Handling:** A2S_INFO ist immer offen — Passwörter betreffen nur RCON,
nicht den Query-Port.

**`src/scripts/query_a2s.pl`** — CLI-Wrapper:
```
perl query_a2s.pl <host> <query_port>
Exit 0: {"players":3,"max":20}
Exit 1: Timeout oder Fehler
```

## Player-Count-Anzeige

**Wo:** `src/manage.cgi` (Instanz-Detailseite)

**Wann:** Nur bei Seitenaufruf (kein Hintergrund-Job), nur wenn Server-Status `running`.

**Ablauf:**
1. `query_port_field` aus `games_meta.json` lesen (z.B. `"queryport"`)
2. Tatsächlichen Port-Wert aus Instanz-Config lesen (LGSM-Config oder Modul-Config)
3. `a2s_query($host, $port)` aufrufen (2s Timeout)
4. Anzeige: `"Spieler: 3 / 20"` neben Status-Badge
5. Kein Ergebnis (Timeout, Server antwortet nicht): kein Badge, kein Fehler

## games_meta.json — Neuer Key

```json
{
  "minecraft": {
    "query_port_field": "queryport",
    ...
  },
  "windrose": {
    "query_port_field": "queryport",
    ...
  }
}
```
`query_port_field` gibt den Feldnamen in der Instanz-Config an.
Der tatsächliche Port-Wert wird aus der Instanz-Config (LGSM-Config oder Modul-Config) gelesen —
analog zum bestehenden `ports.sh`-Mechanismus.

## Cron-Job

**Pfad:** `/etc/cron.d/linuxgsm-webcore-monitor`

```
*/2 * * * * root /opt/webmin/linuxgsm-webcore/../scripts/monitor_all.sh >> /var/log/linuxgsm-webcore-monitor.log 2>&1
```

**Installation:** via `postinstall.pl` (Webmin-Modul-Install-Hook) oder manuell.

## Deployment auf laufende Server

Das Feature ist rein additiv:
- Laufende Server werden nicht berührt
- Beim ersten Monitor-Lauf: State-File wird als `running, count=0` angelegt
- Kein Neustart, kein Eingriff in laufende Prozesse

## v1-Scope (bewusst ausgeschlossen)

- E-Mail-Benachrichtigung bei `failed` (erweiterbar)
- Konfigurierbares Restart-Limit pro Instanz (fix: 5/h)
- Konfigurierbares Cron-Intervall (fix: 2 Min)
- Grafische Restart-Historie
