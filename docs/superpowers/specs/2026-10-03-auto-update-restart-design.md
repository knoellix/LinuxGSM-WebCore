# Design: Auto-Update-Check + Neustart mit Spieler-Warnung

**Datum:** 2026-10-03  
**Status:** implemented 2026-10-03  
**Scope v1:** Project Zomboid (modular, andere Spiele später)  
**UI-Ort:** Manage → **Upgrades and maintenance** (`#upgrades`)  
**Version:** Bump erst mit diesem Feature (Fixes Gamedig/Monitor-Grace fließen mit ein)

---

## In einem Satz

Alle X Minuten prüfen, ob Spiel-Build oder Workshop-Mods neuer sind; wenn ja und niemand online → sofort neu starten; wenn Spieler da → Ansagen (15/10/5/1 Min), dann trotzdem neu starten. Game- und Workshop-Check getrennt schaltbar.

---

## Warum

| Problem | Heute |
|---|---|
| Client hat Workshop-Update, Server noch alt | Spieler kommt oft nicht rein |
| LinuxGSM „Update“ | Nur Server-Build, **nicht** Workshop-Mods |
| Workshop aktuell | Oft erst beim **Serverstart** (PZ lädt Items) |
| DayZ-Style „alle 30 Min + Ansagen“ | Fehlt in WebCore |

---

## Feste Entscheidungen

| Thema | Wahl |
|---|---|
| Architektur | Modular; v1 nur PZ-Adapter |
| Spieler online | Countdown, dann **harter** Neustart |
| Ansagen | Festes Raster T−15 / T−10 / T−5 / T−1 / T−0, Texte anpassbar |
| Was beim Neustart | Stop → ggf. LGSM-Spiel-Update → Start; Workshop vor allem über PZ-Boot |
| Schalter | **Game prüfen** und **Workshop prüfen** getrennt (Defaults: an) |
| UI | Block unter Upgrades/Wartung (nicht Monitoring) |
| Cron-Stil | Kurzer Check-Job + State-Datei (wie Monitor/Schedule), kein 15‑Min-Block-Worker |

---

## So läuft es ab (Alltagssprache)

1. **Alle 30 Minuten** (einstellbar) läuft ein kleiner Job als Game-User.
2. Ist Auto-Update aus oder das Spiel hat keinen Adapter → nichts.
3. **Game-Schalter an:** Gibt’s bei Steam einen neueren Dedicated-Build (PZ App 380870) als lokal?
4. **Workshop-Schalter an:** Hat eine Mod-ID aus `WorkshopItems=` bei Steam ein neueres `time_updated` als der Ordner auf der Platte?
5. **Nichts neu** → nur „letzter Check“ speichern, fertig.
6. **Etwas neu:**
   - **0 Spieler** → sofort Neustart-Job.
   - **Spieler online** → Countdown starten; im Spiel Ansagen (anpassbare Texte); bei „jetzt“ hart neu starten.
7. Während ein Countdown läuft, startet der 30‑Min-Check **keinen zweiten** Countdown.
8. Läuft schon Start/Stop/Update → nicht dazwischenfunken.

**Neustart-Job:**

1. Offene Ansagen bis T−0 (falls Countdown).
2. Sauber stoppen (wie manueller Stop).
3. Nur wenn Game-Update nötig: `./script update` (LGSM).
4. Starten (`lgsm_start_reliable`) — PZ holt Workshop beim Boot.
5. Pending löschen, Job merken, Monitor-Grace wie bei manuellem Start.

---

## Architektur (modular)

```
Adapter (v1: PZ)
  - can_check_game / can_check_workshop
  - game_build_local / game_build_remote
  - workshop_ids + local/remote timestamps
  - player_count
  - broadcast(text)  →  tmux console: servermsg "…"

Check-Cron (interval_min)
  → schreibt .monitor/auto_update
  → startet ggf. Restart-Job oder pflegt Countdown/Messages

Restart-Job
  → Lifecycle stop → [update] → start
```

Spätere Spiele = neuer Adapter, gleiche UI/State/Cron-Hülle.

---

## Config / State

**Datei:** `$SERVER_DIR/.monitor/auto_update` (Game-User, Key=Value wie `schedule`)

| Feld | Default | Bedeutung |
|---|---|---|
| `enabled` | 0 | Master an/aus |
| `check_game` | 1 | Spiel-Build prüfen |
| `check_workshop` | 1 | Workshop-Items prüfen |
| `interval_min` | 30 | Check-Abstand |
| `warn_minutes` | `15,10,5,1,0` | Ansage-Raster (CSV) |
| `msg_template` | s. u. | Text mit `{minutes}` während Countdown |
| `msg_now` | s. u. | Text bei T−0 |
| `pending` | 0/1 | Update erkannt, Neustart ausstehend |
| `countdown_deadline` | epoch | Ende des Countdowns (0 = keiner) |
| `need_game` / `need_workshop` | 0/1 | Was der Restart tun soll |
| `reason` / `mods` | Text | Für Platzhalter / UI |
| `last_check` / `last_restart_job` | — | Statuszeile |

**Platzhalter:** `{minutes}` `{reason}` `{mods}` `{game}`

**Default-Texte (DE):**

- Template: `Server-Neustart in {minutes} Min — {reason}`
- Now: `Server startet jetzt neu — {reason}`

---

## UI

Manage → collapsible **Upgrades and maintenance**:

- **Erklärungstext** (immer sichtbar im Auto-Update-Block, auch wenn Master aus): Workshop-/PZ-Server sind ungewohnt — Clients laden Mods selbst; der Server holt Workshop-Updates typischerweise beim **Neustart**. Auto-Update prüft regelmäßig Spiel-Build und Workshop und plant bei Bedarf einen Neustart (mit Ansagen), damit Server und Clients wieder zusammenpassen. Ohne Neustart bleiben alte Workshop-Stände oft liegen.
- Checkbox Master + Game + Workshop  
- Intervall (Minuten)  
- Warn-Raster (CSV)  
- Zwei Textfelder (Template / Now)  
- Status: letzter Check / Pending + Countdown / letzter Restart-Job-Link  
- Speichern mit Flash (wie Schedule), Cron neu bauen  

Nur anzeigen bzw. sinnvoll nutzbar, wenn Adapter für die Instanz existiert (v1: PZ / `mod_support=workshop` + LGSM).

**Lang-Keys (vorschlag):** `auto_update_howto_title`, `auto_update_howto_body` (DE + EN, 2–4 Sätze, kein Marketing-Fluff).

---

## Erkennung (PZ v1)

**Game:** Steam/LGSM Build-ID für Dedicated App **380870** vs. lokal (`appmanifest_380870.acf` o. ä. unter `serverfiles`).

**Workshop:** IDs aus Server-INI `WorkshopItems=`; remote `time_updated` (Steam Web API, vorhandener API-Key); lokal mtime/Marker unter  
`…/steamapps/workshop/content/108600/<id>/` (alle bekannten Content-Roots, wie Inventory).

**Spielerzahl:** Query/A2S bzw. vorhandener Instanz-Query-Pfad; bei Unklarheit konservativ „Spieler da“ annehmen (lieber warnen als still neu starten).

**Broadcast:** `lgsm_tmux_send_console` → `servermsg "…"`.

---

## Fehlerfälle / Schutz

| Fall | Verhalten |
|---|---|
| Steam API / Netzwerk weg | Check überspringen, loggen; kein Neustart nur wegen API-Fehler |
| Kein API-Key, Workshop an | Workshop-Check überspringen + Hinweis in UI; Game-Check kann weiterlaufen |
| Parallel Start/Stop/Update | Pending behalten, diesen Lauf keine Aktion |
| Restart-Job failed | Monitor-`starting` freigeben (wie Gamedig-Fix); nächster Check darf neu planen |
| Server offline bei Pending | Trotzdem Restart-Job (Start nach Stop/Update) — bringt Workshop/Game auf Stand |
| Countdown, Server crasht | Monitor darf wie gewohnt starten; Auto-Update-Pending bleibt bis erfolgreicher Update-Restart oder manuell cleared |

---

## Tests (Plan)

- State lesen/schreiben + Validierung `warn_minutes` / Interval  
- Adapter stubs: Diff ja/nein für Game und Workshop getrennt  
- 0 Spieler → Restart geplant; >0 → Countdown + Message-Raster  
- Kein zweiter Countdown bei Pending  
- Job-running → Skip Aktion  
- UI: Save + Flash; Cron-Zeile nur wenn enabled  
- Shell: Broadcast-Escaping; Restart-Pfad need_game an/aus  

---

## Nicht in v1

- Freie Message-Liste pro Minute (nur festes Raster + Texte)  
- „Warten bis leer“ nach Countdown  
- Explizites `workshop_download_item` für alle IDs bei jedem Update (Boot reicht für PZ)  
- Andere Spiele außer PZ (Schema schon modular)  
- Discord/Webhook-Ansagen  

---

## Bezug zu aktuellen Fixes (mitinstallieren)

Beim Release dieses Features mit ausliefern:

- Gamedig-Preflight vor LGSM-Start (kein Timeout mitten in `npm install`)  
- Failed Start/Restart gibt Monitor-`starting`-Grace frei  

---

## Nächster Schritt

Nach Freigabe dieser Spec → Implementation Plan unter `docs/superpowers/plans/`, dann Bau + Version-Bump.
