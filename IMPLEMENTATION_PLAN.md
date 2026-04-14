# IMPLEMENTATION PLAN

## Ziel
FTP/FTPS-Verwaltung fuer ProFTPD Virtual Users integrieren: Audit inkl. Safe-Fix, User-CRUD nur via `ftpasswd`, sowie Instanz-Zuordnung und Cleanup-Integration.

## Schritte
1. Neue ProFTPD-Helper-Lib (`src/lib/ftp_proftpd.pl`) fuer Config-Discovery, Audit, Safe-Fix und `ftpasswd`-Aktionen erstellen.
2. Neue Seite `src/ftp_settings.cgi` fuer Audit+Safe-Fix, globale FTP-User-Liste und Instanz-Zuordnung/CRUD erstellen.
3. Uebersichts-Button in `src/index.cgi` fuer FTP/FTPS-Bereich ergaenzen.
4. Instanz-Cleanup in `src/manage.cgi` an ProFTPD-User-Loeschung via `ftpasswd --delete-user` koppeln.
5. Sprachtexte in `src/lang/de` und `src/lang/en` fuer FTP/FTPS-Oberflaeche ergaenzen.
6. Tests fuer ProFTPD-Parser/Helper ergaenzen und Build-Verifikation ausfuehren.

## Verifikation
- `perl -c src/lib/ftp_proftpd.pl`
- `perl -c src/ftp_settings.cgi`
- `perl -c src/manage.cgi`
- `perl t/test_ftp_proftpd.pl`
- `bash scripts/build.sh`
