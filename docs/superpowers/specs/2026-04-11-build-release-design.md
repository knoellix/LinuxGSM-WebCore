# Design: Build & Release System

**Datum:** 2026-04-11
**Status:** Abgesegnet
**Scope:** `scripts/build.sh`, `dist/install.sh` (generiert), `.github/workflows/ci.yml`, `.github/workflows/release.yml`

---

## Ziel

- Lokales Build-Script: Tests → `.wbm` + `install.sh` bauen
- CI: Tests bei jedem Push/PR
- Release: Bei `v*`-Tag automatisch bauen und auf GitHub Releases veröffentlichen
- One-Liner-Install für Endnutzer

---

## Artefakte

| Datei | Inhalt |
|-------|--------|
| `dist/linuxgsm-webcore-<version>.wbm` | Webmin Module Archive (tar.gz von `src/`) |
| `dist/install.sh` | Generiertes Installer-Script mit eingebetteter Version + Download-URL |

---

## `scripts/build.sh`

### Ablauf

```
1. Version aus src/module.info lesen  (Zeile: version=X.Y.Z)
2. Wenn $TAG gesetzt (CI): prüfen ob Tag v<version> == module.info-Version → Abbruch bei Mismatch
3. Tests ausführen: find t/ -name "test_*.pl" | xargs -I{} perl {}
   → Abbruch bei Exit-Code != 0
4. dist/ anlegen / leeren
5. src/ → tmp/linuxgsm-webcore/ kopieren
6. tar czf dist/linuxgsm-webcore-<version>.wbm -C tmp linuxgsm-webcore/
7. install.sh generieren → dist/install.sh
8. tmp/ aufräumen
```

### Versions-Sync-Prüfung

Der Release-Workflow setzt `TAG` auf den Git-Tag (z.B. `v0.1.0`). Das Script vergleicht:
```bash
tag_version="${TAG#v}"   # "v0.1.0" → "0.1.0"
# muss == version aus module.info sein
```
Abbruch mit Fehlermeldung wenn nicht übereinstimmend.

---

## `dist/install.sh` (generiert)

Wird von `build.sh` erzeugt. Version und Download-URL werden zur Build-Zeit eingebettet.

### Ablauf

```bash
1. Root-Check: [ "$EUID" -ne 0 ] → Abbruch mit Hinweis "sudo ..."
2. Webmin-Check: [ -d /usr/share/webmin ] || Abbruch mit Hinweis
3. .wbm von GitHub Releases herunterladen:
   curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/download/v<VERSION>/linuxgsm-webcore-<VERSION>.wbm -o /tmp/linuxgsm-webcore.wbm
4. Installieren: perl /usr/share/webmin/install-module.pl /tmp/linuxgsm-webcore.wbm
5. Webmin neu starten: /etc/webmin/restart
6. Aufräumen: rm /tmp/linuxgsm-webcore.wbm
```

### One-Liner für Endnutzer

```bash
bash <(curl -sL https://github.com/knoellix/LinuxGSM-WebCore/releases/latest/download/install.sh)
```

---

## `.github/workflows/ci.yml`

```yaml
Trigger: push (alle Branches), pull_request
Runner: ubuntu-latest
Steps:
  - actions/checkout@v4
  - name: Run tests
    run: find t/ -name "test_*.pl" | sort | xargs -I{} perl {}
```

---

## `.github/workflows/release.yml`

```yaml
Trigger: push tags ["v*"]
Runner: ubuntu-latest
Permissions: contents: write  # Pflicht für GitHub Release erstellen
Steps:
  - actions/checkout@v4
  - name: Build
    run: TAG=${{ github.ref_name }} bash scripts/build.sh
  - name: Create GitHub Release
    uses: softprops/action-gh-release@v2
    with:
      tag_name: ${{ github.ref_name }}
      name: "LinuxGSM-WebCore ${{ github.ref_name }}"
      files: |
        dist/linuxgsm-webcore-*.wbm
        dist/install.sh
```

---

## Dateien die angelegt werden

| Datei | Aktion |
|-------|--------|
| `scripts/build.sh` | Neu anlegen |
| `.github/workflows/ci.yml` | Neu anlegen |
| `.github/workflows/release.yml` | Neu anlegen |
| `packaging/debian/` | Bleibt, wird nicht mehr aktiv genutzt |
| `packaging/rpm/` | Bleibt, wird nicht mehr aktiv genutzt |

---

## Sicherheits-Invarianten

- `install.sh` prüft Root und Webmin-Existenz vor jeder Aktion
- Download via HTTPS (kein HTTP-Fallback)
- Webmin's `install-module.pl` übernimmt die eigentliche Installation (kein manuelles Entpacken in Systempfade)
