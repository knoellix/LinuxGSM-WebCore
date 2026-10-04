# Design: Spieleranzeige im Instanz-Status (Admin-Query)

**Datum:** 2026-10-04  
**Status:** implemented  
**Scope v1:** Minecraft (alle Varianten), Project Zomboid, Palworld  
**UI-Ort:** Manage → Status-Zeile (neben Runtime / Monitor / …)  
**Nicht v1:** Windrose (kein Vanilla-Admin-Query), Auto-Update-Anbindung (kann dieselbe Lib später nutzen)

**Windrose note:** In `games_meta.json` → `windrose` leave an English string field (e.g. `player_query_note`) stating that as of this feature Windrose has no supported player-query path yet (needs Windrose+/RCON mod later). Ignored by code; for maintainers only.

---

## In einem Satz

Modulare Admin-Query (RCON/REST) liefert die Spielerzahl in der Status-Zeile: nur wenn Config ready; sonst „RCON fehlt“ mit generischem Tooltip; Poll nur bei offener, sichtbarer Manage-Seite.

---

## Warum

| Problem | Heute |
|---|---|
| Spielerzahl nur sporadisch via A2S | Fragil, kein Challenge, MC/Windrose gar nicht |
| Kein gemeinsamer Ready-Check | RCON oft aus / Passwort leer → Query sinnlos |
| Pro-Spiel-UI droht | Tooltips/Parser würden duplizieren |
| Manage-Seite soll live bleiben | Ohne Hintergrund-Cron und ohne Tab-Spam |

---

## Feste Entscheidungen

| Thema | Wahl |
|---|---|
| Architektur | Meta `player_query` + eine Lib `player_query.pl`; Manage kennt nur Ready/Count/HTML |
| Quelle | Admin-Protokoll (`rcon` / `rest`), **nicht** A2S für diese UI |
| Ohne Meta | Status-Zelle **nicht** rendern |
| Ready fehlt | Anzeige `RCON fehlt` + generischer Tooltip (lang, einmal) |
| Anzeige | `N/M` wenn Max aus Config bekannt, sonst nur `N` |
| Wann query | Erst wenn Runtime zuverlässig **online** (nicht starting) |
| Poll | Alle **60 s** solange Manage offen **und** Tab sichtbar |
| Cache | Server-seitig ~60 s pro Instanz → mehrere Viewer = ein RCON |
| Host | Immer `127.0.0.1` — kein öffentliches Firewall-Öffnen für RCON |
| A2S-Spielerzeile | Entfernen, sobald `player_query` für das Spiel gesetzt ist |
| Windrose | Kein Meta in v1 |

---

## Meta-Schema

Optionales Feld pro Script in `games_meta.json`:

```json
"player_query": {
  "kind": "rcon",
  "source": "game_config",
  "enabled_key": "enable-rcon",
  "port_key": "rcon.port",
  "password_key": "rcon.password",
  "max_players_key": "max-players",
  "command": "list",
  "parse": "mc_list"
}
```

| Key | Bedeutung |
|---|---|
| `kind` | `rcon` \| `rest` |
| `source` | Wo Keys gelesen werden (`game_config`, `server_properties`, …) — über bestehende Config-Reader |
| `enabled_key` | Optional; fehlt oder truthy-Wert = an. Fehlt der Key in Meta = kein Enable-Check (nur Passwort/Port), z. B. PZ |
| `port_key` | RCON/REST-Port in der Game-Config |
| `password_key` | Pflicht für Ready: nicht leer |
| `max_players_key` | Optional; für `N/M`-Anzeige |
| `command` | RCON-Befehl **oder** REST-Pfad (z. B. `/v1/api/metrics`) |
| `parse` | Parser-Typ in der Lib (kein spielspezifischer Code in Manage) |
| Extra für REST | z. B. `players_field`, `max_field`, `auth: basic_admin` |

### Parser-Typen (v1)

| `parse` | Verhalten |
|---|---|
| `mc_list` | Minecraft `list` → `There are N of a max of M` (M nur Fallback, Prefer Config-Max) |
| `lines_skip_header` | Antwortzeilen zählen (Header-Zeile überspringen) — PZ `players` |
| `json_field` | JSON-Objekt, Felder aus Meta (`players_field` / optional `max_field`) — Palworld Metrics |

### v1 Meta-Belegung

**Minecraft** (Basis `mcserver`, Varianten erben / spiegeln):

- `kind: rcon`, `source: server_properties` (bzw. game_config properties)
- Keys: `enable-rcon`, `rcon.port`, `rcon.password`, max `max-players`
- `command: list`, `parse: mc_list`
- Config-Felder in Meta ergänzen, falls noch nicht editierbar

**Project Zomboid:**

- `kind: rcon`, INI `RCONPort` / `RCONPassword` (kein separates Enable — leeres Passwort = aus)
- `command: players`, `parse: lines_skip_header`
- max `MaxPlayers`
- `RCONPort` / `RCONPassword` in `game_config_fields` aufnehmen (fehlen heute)

**Palworld:**

- `kind: rest` (bevorzugt vor ShowPlayers)
- Auth über `AdminPassword`; Enable `RESTAPIEnabled` (Meta-Felder ergänzen falls nötig)
- `command: /v1/api/metrics`, `parse: json_field`, `players_field: currentplayernum`
- max `ServerPlayerMaxNum`

---

## Lib-API (`src/lib/player_query.pl`)

```text
player_query_meta($script)            → hashref | undef
player_query_readiness($dir, $script) → { ok => 0|1, reason => '…' }
player_query_count($dir, $script)     → { ok, players, max, err }
player_query_status_html(...)         → HTML für Status-Zelle (escaped, lang keys)
```

- `reason`: `missing_enabled` | `missing_password` | `missing_port` | `no_meta` | …
- `player_query_count` nur sinnvoll bei `ok` Readiness; sonst nicht aufrufen
- Interne Handler: `_pq_rcon`, `_pq_rest` + `_pq_parse_*`
- Timeouts kurz (z. B. 2 s); Fehler → `{ ok => 0, err => '…' }`
- Cache-Datei unter Instanz-Job/Monitor-State (z. B. `.monitor/player_query.json`): `{ ts, players, max, state }` — TTL ~60 s

Kein Auto-Update in v1 — Adapter dort können später `player_query_count` nutzen.

---

## Status-UI

Teil der bestehenden Status-Zeile (`ui_instance_status_part`):

| Zustand | Text | Tooltip |
|---|---|---|
| Offline / starting | `—` | wartet auf Start (lang) |
| Ready fehlt | `RCON fehlt` | RCON muss an sein, Passwort gesetzt, Port gültig (generisch, ein Text) |
| Ready + Query ok | `3/32` oder `3` | — |
| Ready + Query fail | `?` | RCON nicht erreichbar / Auth fehlgeschlagen |

Lang-Keys einmal in `de` + `en` (+ UTF-8-Varianten wie üblich), z. B.:

- `manage_players_label`
- `manage_players_rcon_missing`
- `manage_players_rcon_missing_tip`
- `manage_players_waiting`
- `manage_players_unreachable_tip`

---

## Polling

1. Manage rendert initiale Zelle (Cache oder Ready-State ohne Query beim starting).
2. JS: Interval **60 s**, Endpoint `manage.cgi?action=poll_players&instance_id=…`.
3. `document.hidden` / `visibilitychange`: Pausieren im Hintergrund; beim Sichtbar-Werden sofort refresh wenn Cache abgelaufen.
4. Endpoint: Runtime nicht online → `—`; Ready fehlt → `RCON fehlt`; sonst Count (mit Cache).
5. Mehrere Browser: mehr HTTP, ein RCON pro TTL dank Cache.

Kein dauerhafter System-Cron für die UI.

---

## Sicherheit

- Nur localhost.
- Passwort nur server-seitig lesen, nie im Poll-JSON zurückgeben.
- RCON/REST nicht über Webmin-Firewall „aufmachen“ — Dokumentation: lokal reicht.
- Inputs an Endpoint wie üblich sanitizen; ACL Instanz-Zugriff.

---

## Tests

- Meta fehlt → keine Zelle
- Ready: Enable aus / Passwort leer / Port 0
- Parser: `mc_list`, `lines_skip_header`, `json_field` (Fixturen)
- Cache: zweiter Count innerhalb TTL ohne erneuten Netzwerk-Mock-Hit
- Manage/poll_players: JSON-Shape + HTML-Escaping
- Kein Blind-Success: Query-Fail ≠ „0 Spieler“

---

## Out of scope / Follow-up

1. **Windrose** — kein `player_query` in v1; English maintainer note `player_query_note` in meta (see above). Real support later with Windrose+/RCON mod + meta.
2. **Auto-Update** — `player_query_count` statt/neben A2S.
3. **Docs: Meta-Einstieg erleichtern** — README / ggf. Wiki / `docs/` auf Konsistenz prüfen und straffen. Ziel: kurzer „Neues Spiel in `games_meta`“-Pfad (Minimal-Set zuerst, dann optionale Blöcke: start phases, workshop, `player_query`, …), nicht die ganze Meta-Oberfläche auf einmal. **Nach** Implementierung dieses Features, eigener kleiner Docs-Pass.

---

## Implementierungsreihenfolge (Skizze)

1. Lib + Meta-Schema + Tests (ohne UI)
2. Meta v1 für MC / PZ / Palworld (+ fehlende Config-Felder)
3. Manage Status-Zelle + `poll_players` + Visibility-JS
4. A2S-Spielerzeile für Spiele mit `player_query` entfernen
5. `verify.sh`
6. Follow-up: Meta-Docs/README-Einstieg
