# IMPLEMENTATION PLAN

## Ziel
Verifikationsdaten und Projektregeln weiter pflegen: Full-Verify-Skript ergaenzen, kritische ACL-Testluecke beheben und Richtlinien/Ignore-Listen aktualisieren.

## Schritte
1. `scripts/verify-full.sh` fuer komplette Testsuite hinzufuegen.
2. ACL-Filterlogik robust machen, wenn Instanzen kein `id`-Feld liefern.
3. `CLAUDE.md` um Full-Verify-Regel ergaenzen.
4. `.gitignore` um Full-Verify-Logdateien ergaenzen.
5. `verify.sh` und `verify-full.sh` laufen lassen.

## Verifikation
- `bash scripts/verify.sh`
- `bash scripts/verify-full.sh`
