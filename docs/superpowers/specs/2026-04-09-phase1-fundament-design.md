# Design: Phase 1 — Fundament

**Datum:** 2026-04-09
**Status:** Abgesegnet
**Scope:** `core.pl`, `instance.pl`, `index.cgi`

---

## Kontext

Das Scaffold ist vollständig (22 Skeleton-Dateien). Phase 1 implementiert das Fundament:
- Echte Instanz-Erkennung via `/etc/passwd` + LGSM-Config-Parsing
- Health-Check mit Empfehlungen bei abweichender Konfiguration
- Dashboard (`index.cgi`) mit kompakter Tabelle + Expand-Zeile

Entwicklung lokal, Deploy und Test auf dem Debian-Root-Server.

---

## Architektur & Datenfluss

```
HTTP-Request → index.cgi
  → list_instances()               [instance.pl]
      → /etc/passwd scannen        (Shell = nologin UND ~/user-Script vorhanden)
      → get_instance($user)
          → _parse_lgsm_config()   liest common.cfg + <user>.cfg
          → _detect_status()       ruft `su ... details` auf (on demand)
          → _check_instance_health() prüft Shell, Script, Config-Pfad
  → HTML-Tabelle rendern           [index.cgi]
      → kompakte Zeile: User | Game | Port | Status | Health-Icon | Expand-Button
      → Expand-Zeile (GET ?expand=<user>): Details + Firewall + Start/Stop
```

### Datenstruktur pro Instanz

```perl
{
    user     => 'mc-survival',      # System-Username
    home     => '/home/mc-survival', # Home-Verzeichnis aus /etc/passwd
    game     => 'mcserver',         # aus LGSM-Config: gamename=
    port     => '25565',            # aus LGSM-Config: port=
    status   => 'online',           # 'online' | 'offline' | 'unknown'
    fw_open  => 1,                  # Firewall-Port offen? (1/0)
    warnings => [],                 # Arrayref mit Health-Warnungen
}
```

---

## Komponenten

### 1. core.pl

Läuft beim ersten `require` in jeder CGI-Datei. Setzt globalen State.

**Text-Loading:**
```perl
&read_file("$module_root/lang/en", \%text);
&read_file("$module_root/lang/$current_lang", \%text) if $current_lang ne 'en';
&read_file("$config_directory/config", \%config) if -f "$config_directory/config";
```

**Helpers:**

| Funktion | Verhalten |
|----------|-----------|
| `error_if_root()` | Bricht mit Webmin-Fehlermeldung ab wenn `$< == 0` |
| `sanitize_input($str)` | Entfernt alles außer `[a-zA-Z0-9_-]`; wenn Ergebnis leer → `&error(...)` |
| `run_server_action($user, $action)` | Validiert `$action` gegen Whitelist `(start\|stop\|restart\|update\|details)`, dann `su -s /bin/bash -c "./$user $action" $user` |
| `firewall_status($port)` | Delegiert an `firewall.pl`; prüft ob Port in ufw/iptables offen ist; gibt `1` oder `0` zurück |

**Sicherheits-Invarianten:**
- `sanitize_input` gibt nie einen leeren String zurück — bei leerem Ergebnis wird `&error()` gerufen
- `run_server_action` validiert `$action` gegen eine explizite Whitelist vor der Shell-Ausführung
- Keine Ausführung als root — `su -s /bin/bash -c ...` immer mit Game-User

---

### 2. instance.pl

#### `list_instances()`

Scannt `/etc/passwd`:
1. Nur User mit Shell `/usr/sbin/nologin`
2. Nur User bei denen `$home/$user` (LGSM-Script) existiert
3. Ruft `get_instance($user)` für jeden Treffer auf

#### `get_instance($user)`

Gibt Instanz-Hashref zurück oder `undef` wenn nicht gefunden.

```
1. getpwnam($user) → home ermitteln
2. LGSM-Script-Existenz prüfen
3. _parse_lgsm_config($home, $user) aufrufen
4. _detect_status($home, $user) aufrufen
5. firewall_status($port) aufrufen
6. _check_instance_health($user, $home, $cfg_ref) aufrufen
7. Hashref zurückgeben
```

#### `_parse_lgsm_config($home, $user)`

Liest LGSM-Config in dieser Reihenfolge (spätere überschreibt frühere):

1. `$home/lgsm/config-lgsm/common.cfg`
2. `$home/lgsm/config-lgsm/$user/$user.cfg`

Parser-Regex: `/^\s*(\w+)\s*=\s*["']?([^"'\n]+?)["']?\s*$/`
Kommentar-Zeilen (beginnen mit `#`) werden übersprungen.

Rückgabe: `%cfg` Hash mit allen geparsten Schlüsseln (u.a. `gamename`, `port`).

#### `_detect_status($home, $user)`

```perl
my $out = `su -s /bin/bash -c "./$user details" $user 2>/dev/null`;
return 'unknown' unless defined $out && length $out;
return $out =~ /Online/ ? 'online' : 'offline';
```

Wird on-demand aufgerufen (beim Laden von `index.cgi` oder Expand-Zeile).
`unknown` wird zurückgegeben wenn der Befehl fehlschlägt (z.B. User existiert nicht mehr, Script nicht ausführbar).

#### `_check_instance_health($user, $home, $cfg_ref)`

Gibt Arrayref mit Warnungs-Strings zurück. Leer = alles ok.

| Prüfung | Bedingung | Empfehlung |
|---------|-----------|------------|
| Shell | `shell ne '/usr/sbin/nologin'` | `"Shell auf nologin setzen: usermod -s /usr/sbin/nologin $user"` |
| LGSM-Script | `!-f "$home/$user"` | `"Kein LGSM-Script gefunden — Installation evtl. unvollständig"` |
| Config-Pfad | `!-d "$home/lgsm/config-lgsm"` | `"LGSM-Config-Verzeichnis fehlt — abweichende Struktur?"` |

---

### 3. index.cgi

#### Kompakte Tabelle

Spalten: **User | Game | Port | Status | Health | [▼]**

- Status als farbiger Text: `online` (grün), `offline` (rot), `unknown` (grau)
- Health-Spalte: ✅ wenn `@warnings` leer, ⚠️ mit Anzahl wenn Warnungen vorhanden
- `[▼]`-Link: `index.cgi?expand=<user>`

#### Expand-Zeile

Aktiviert wenn GET-Parameter `expand=<user>` gesetzt. Zeigt direkt unterhalb der Instanz-Zeile:

```
Port:       25565
Firewall:   ✅ offen    [Port schließen]
            ❌ geschlossen  [Port öffnen]

[Start]  [Stop]  [Restart]  [Update]

⚠ Warnungen:
  → Shell ist nicht nologin — usermod -s /usr/sbin/nologin mc-survival
```

- Firewall-Buttons: POST zu `index.cgi` mit `action=fw_open|fw_close&user=<user>`
- Server-Buttons: POST zu `manage.cgi` mit `action=<action>&user=<user>`
- Kein JavaScript — reines HTML mit GET/POST

#### Kein JavaScript

Expand via `?expand=<user>` GET-Parameter. Webmin-Standardklassen (`ui_table`, `ui_submit`).

---

## Sicherheits-Invarianten

- Game-User behalten `/usr/sbin/nologin` — Health-Check warnt aktiv bei Abweichung
- Plugin führt Befehle niemals als root aus — ausschließlich `su -s /bin/bash -c ...`
- Alle CGI-Eingaben laufen durch `sanitize_input()` bevor sie in Shell-Befehle fließen
- `run_server_action` validiert `$action` gegen explizite Whitelist

---

## Abgrenzung (nicht in Phase 1)

- SFTP-Management → Phase 3
- Provisionierung → Phase 2
- Engine-Switch → Phase 4
- Monitoring/Watchdog → Phase 4
- Logs-Anzeige (Live-Konsole) → Phase 2

---

## Dateien die geändert werden

| Datei | Änderung |
|-------|---------|
| `src/lib/core.pl` | Vollständige Implementierung aller Helpers + `firewall_status()` |
| `src/lib/instance.pl` | Vollständige Implementierung mit Config-Parsing + Health-Check |
| `src/index.cgi` | Echte Instanz-Liste + Expand-Zeile + Firewall-Buttons |
| `src/lang/en` | Neue Texte für Health-Warnungen, Firewall-Status |
| `src/lang/de` | Neue Texte für Health-Warnungen, Firewall-Status |
