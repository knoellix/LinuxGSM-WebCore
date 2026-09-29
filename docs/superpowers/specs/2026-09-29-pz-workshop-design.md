# Project Zomboid Workshop — Design Spec

**Datum:** 2026-09-29  
**Status:** V1 in Umsetzung  
**Plan:** `docs/superpowers/plans/` / Cursor-Plan „PZ Workshop UI Fixes“

---

## Ziel

Steam-Workshop-Mods für Project-Zomboid-Instanzen (`pzserver`) suchen, abonnieren und in `servertest.ini` aktivieren — analog zur Minecraft-Mods-Seite, aber über Steam Web API + SteamCMD + INI, nicht über `mc_mods`.

---

## Entscheidungen (V1)

| Thema | Entscheidung |
|-------|--------------|
| API-Key | Modul-Config `steam_web_api_key` unter Integrationen (wie CurseForge) |
| Worker-Secrets | Key in `$JOB_DIR/.worker_secrets` bei Subscribe-Jobs |
| UI | Eigene CGI `workshop.cgi` für Spiele mit `mod_support: workshop` |
| Manage | Nur Link „Workshop verwalten“, wenn Meta passt |
| Suche | Steam `IPublishedFileService/QueryFiles` (appid Workshop = 108600) |
| Download | SteamCMD `+workshop_download_item 108600 <id>` als Game-User |
| Aktivierung | `WorkshopItems=` + `Mods=` in Server-INI patchen |
| Mod-IDs | Aus `mod.info` (`id=…`) im Workshop-Ordner lesen |
| Deps | Hinweis nur; kein transitiver Auto-Graph (**superseded** by deps-design for Subscribe) |
| Restart | Hinweis (Server stoppen empfohlen); kein Zwangs-Restart |
| Success | Job `status=ok` nach Verify Download-Ordner + INI-Write |

---

## Nicht in V1

- Collections, Bewertungen, Live-Updates wie Steam-Client
- Nexus / andere Quellen
- Automatischer Restart-Job
- Palworld/andere Workshop-Spiele (Meta-Flag vorbereitet, UI/Worker PZ-first)

**Nachgezogen (eigene Specs):** Inventory-UI → `2026-09-29-pz-workshop-inventory-design.md`; transitive Steam-Deps beim Subscribe → `2026-09-29-pz-workshop-deps-design.md`.

---

## Architektur

```
integrations (steam_web_api_key)
        │
workshop.cgi ──search──► pz_workshop.pl (QueryFiles)
        │
   subscribe ──job──► pz_workshop_subscribe_user.sh
                          │ SteamCMD workshop_download_item
                          │ parse mod.info
                          └ patch servertest.ini (WorkshopItems, Mods)
```

| Schicht | Inhalt |
|---------|--------|
| `games_meta.json` (`pzserver`) | `mod_support: workshop`, `workshop_appid`, `workshop_ini_rel`, Content-Pfad |
| `src/lib/pz_workshop.pl` | API-Suche, INI lesen/schreiben, `mod.info` parsen, Pfad-Validierung |
| `src/workshop.cgi` | Suche, Treffer, Abonnieren, installierte Liste, Entfernen |
| `src/scripts/pz_workshop_subscribe_user.sh` | User-native Worker |
| Integrationen | `steam_web_api_key` speichern/anzeigen |

---

## Pfade (PZ / LGSM)

- Workshop-App-ID: **108600** (Client Workshop; Dedicated nutzt dieselben Items)
- Dedicated App-ID (SteamCMD login/install): **380870** (nur Kontext; Download per Workshop-App)
- INI (Default): `$HOME/Zomboid/Server/servertest.ini` (`workshop_ini_rel`)
- Content nach SteamCMD: unter Home/`Steam` oder lokalem SteamCMD-Prefix  
  `steamapps/workshop/content/108600/<id>/`

INI-Writes nur nach Canonical-Pfad-Check (unter Home des Unix-Users bzw. erlaubtem Relativpfad aus Meta).

---

## UX

1. Suchfeld → Treffer: Titel, Autor (SteamID), Kurzbeschreibung, Workshop-ID  
2. **Abonnieren** → Hintergrund-Job → `job_live.cgi`  
3. Liste: Workshop-ID + erkannte Mod-IDs; Entfernen entfernt aus INI (Ordner optional belassen)  
4. Ohne API-Key: Suche blockiert mit Link zu Integrationen; Subscribe per ID möglich wenn Key für Details fehlt (V1: ID-Eingabe + Suche)

---

## Tests

- `WorkshopItems` / `Mods` Round-Trip
- Suche mit Fixture-JSON (kein Live-Steam)
- INI-Pfad außerhalb Home abgelehnt
- `bash scripts/verify.sh`
