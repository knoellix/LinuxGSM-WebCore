# LinuxGSM-WebCore Audit Checklist

Kompakte Prüfliste — Details in `.cursor/rules/*.mdc`.

## Project core

- [ ] Pläne für grosse Features in `docs/superpowers/plans/`
- [ ] UI-Strings in `src/lang/de` **und** `src/lang/en`
- [ ] Code/Kommentare Englisch
- [ ] Nur `ui_*` für UI; keine hardcoded Styles/Farben
- [ ] `ui_submit` mit CSS-Klasse (5. Arg): `btn-danger` / `btn-default` / `btn-primary`
- [ ] Keine hardcoded System-Pfade ausserhalb Modul-Resolution
- [ ] `.wbm`-only; kein deb/rpm ohne Anfrage

## Security & isolation

- [ ] Game-Ops und `$SERVER_DIR`-Writes als Game-User (`su` dispatch oder `_write_file_as_user`)
- [ ] `apt`/dpkg nur in `provision_deps.sh` (Bootstrap)
- [ ] Kein Game-Server als root
- [ ] Runtime-Worker: kein internes `su` auf Spieldaten
- [ ] Dispatch via `user_worker_launch_cmd()` — keine ad-hoc root-Worker-Strings
- [ ] Input validiert; optionale Params **nicht** durch `sanitize_input()` (strip manuell)
- [ ] Dynamisches HTML: `html_escape()`
- [ ] Firewall nur Webmin-API
- [ ] Config: `validate_config_target()`; nie `_default.cfg` überschreiben
- [ ] Provisioning: Rollback bei Fehler

## No blind success feedback

- [ ] Kein Erfolgs-Banner nur wegen `?saved=1` / `?ok=1`
- [ ] Config-Save: `module_config_save()` + Flash consume
- [ ] Async: Erfolg erst bei `$JOB_DIR/status` = `ok`
- [ ] Return-Werte geprüft (`write_file`, `system_logged`, `firewall_*`, …)
- [ ] Kein stilles `eval` auf Persistenz ohne Log/Fallback

## Webmin CGI

- [ ] Bootstrap-Reihenfolge (web-lib → ui-lib → init_config → require libs)
- [ ] `&redirect(...); exit;` immer beide
- [ ] `text()` Platzhalter: **`$1`, `$2`** — nie `%s`
- [ ] `module_config_bool()` für Radio/Checkbox (Perl-Truthiness!)
- [ ] ACL über `acl_security.pl`

## Workers & jobs

- [ ] Lange Tasks → Job + `job_live.cgi`
- [ ] `MODULE_ROOT` an Worker übergeben
- [ ] Game-User: `.worker_secrets` für API-Keys
- [ ] `job_log_init` / `job_log_init_as_user` korrekt
- [ ] Status `ok|failed|aborted`; pgid cleanup
- [ ] Monitor/Schedule-Jobs: Pointer-Sync in `jobs.pl`

## Minecraft / modpack (if in scope)

- [ ] Worker-Fehler: `mc_modpack_error_message` — nicht generisch
- [ ] Resolve im Worker, nicht blind OK in CGI

## Tests

- [ ] Neue Flows: Test in `t/`; Shell-Tests in `scripts/verify.sh` critical list
- [ ] `use Test::More tests => N` stimmt mit Plan überein
- [ ] Lang: `bash .cursor/skills/linuxgsm-webcore-audit/scripts/lang-parity.sh` grün
- [ ] `bash scripts/verify.sh` grün; Release: `bash scripts/verify-full.sh`

## Dead code & drift

- [ ] Ungenutzte Subs/Scripts
- [ ] Duplizierte Logik CGI ↔ lib
- [ ] Verwaiste Lang-Keys
- [ ] Kommentierte Code-Blöcke / unreachable branches
- [ ] Legacy-Redirects dokumentiert und noch beabsichtigt

## Efficiency

- [ ] Redundante `su`-Aufrufe (Caller schon als User?)
- [ ] Schwere Arbeit nicht im CGI synchron
- [ ] Doppelte Registry/State-Reads zusammenfassen wo sinnvoll
- [ ] Keine überflüssigen `require` in Hot Paths ohne Nutzen
