# IMPLEMENTATION PLAN

## Ziel
Game-Config-Handling fuer `.ini`-Dateien robuster machen: byte-genaues Speichern ohne Formatmanipulation und Bootstrap-Flow, falls die Game-Config-Datei noch nicht existiert.

## Schritte
1. Regressionstest fuer exaktes Datei-Schreiben in `src/lib/config_editor.pl` ergaenzen (keine zusaetzlichen Zeichen/Zeilenumbrueche).
2. Helper fuer byte-genaues Speichern von Raw-Game-Configs in `src/lib/config_editor.pl` ergaenzen.
3. In `src/manage.cgi` Game-Config-Save auf den neuen Exact-Write-Helper umstellen.
4. Bootstrap-Flow ergaenzen: falls Game-Config fehlt, Server kurz starten/stoppen, damit Datei erzeugt wird (Button + Save-Fallback).
5. Sprachtexte in `src/lang/de` und `src/lang/en` fuer Bootstrap-Hinweise ergaenzen.
6. Syntax- und Test-Verifikation ausfuehren.

## Verifikation
- `perl -c src/lib/config_editor.pl`
- `perl -c src/manage.cgi`
- `perl t/test_config_editor.pl`
- `bash scripts/build.sh`
