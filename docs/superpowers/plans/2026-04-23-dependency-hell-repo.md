# Linux-Game-Server-Dependency-Hell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a GitHub repository with automated CI that packages per-game shared libraries from the Valve Scout Runtime and publishes them as GitHub Releases for the LinuxGSM-WebCore plugin to consume.

**Architecture:** `games.yml` is the source-of-truth; `gen_index.py` generates `index.json` (URL mapping) from it; `build-game.yml` runs in Docker `debian:bookworm`, installs the game via LGSM, scans binaries with `ldd`, packages `.so` files from Scout Runtime as `libs.tar.gz`; `issue-handler.yml` automates adding new games via Steam API validation + PR. Release tag `{game_id}-latest` is always overwritten on each build — URL stays stable, plugin always gets the freshest libs.

**Tech Stack:** GitHub Actions, Docker `debian:bookworm`, Bash 5, Python 3 + PyYAML, Valve Scout Runtime, SteamCMD, LinuxGSM, `jq`, `gh` CLI, `yamllint`.

**Working directory:** New repo, cloned from `https://github.com/knoellix/Linux-Game-Server-Dependency-Hell`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `games.yml` | Source-of-truth: all supported games |
| `index.json` | Generated: game_id → release URL mapping |
| `scripts/gen_index.py` | Reads games.yml → writes index.json |
| `scripts/build_game.sh` | ldd scan + Scout lookup + tar.gz package |
| `scripts/detect_engine.sh` | Detects engine (source/unity/unreal) from installed files |
| `scripts/lib_package_map.json` | .so filename → apt package fallback |
| `.github/ISSUE_TEMPLATE/game-request.yml` | New-game issue template |
| `.github/workflows/build-game.yml` | Main build: Docker debian:bookworm |
| `.github/workflows/gen-index.yml` | games.yml push → rebuild index.json |
| `.github/workflows/issue-handler.yml` | Issue → Steam API → PR |
| `.github/workflows/build-all.yml` | Weekly cron rebuild of all games |

---

## Prerequisites (manual, before Task 1)

- [ ] Create GitHub repo `knoellix/Linux-Game-Server-Dependency-Hell` (public)
- [ ] Clone locally: `git clone https://github.com/knoellix/Linux-Game-Server-Dependency-Hell && cd Linux-Game-Server-Dependency-Hell`
- [ ] Ensure `gh` CLI is authenticated: `gh auth status`

---

## Task 1: Repo-Grundstruktur

**Files:**
- Create: `README.md`
- Create: `.gitignore`
- Create: `games.yml`
- Create: `index.json`

- [ ] **Step 1: Create README.md**

```markdown
# Linux-Game-Server-Dependency-Hell

Automated shared-library packages for LinuxGSM game servers.

## How it works

1. CI installs a game server on Debian Bookworm via LinuxGSM
2. `ldd` scans all binaries for missing libraries
3. Found libs are packaged from the Valve Scout Runtime
4. Packages are published as GitHub Releases
5. The LinuxGSM-WebCore Webmin plugin downloads the right package per game

## Supported games

See [games.yml](games.yml) for the current list.

## Request a new game

[Open an issue](../../issues/new?template=game-request.yml) with the Steam App ID.

## Package format

Each release contains:
- `libs.tar.gz` — `.so` files from the Scout Runtime
- `apt-hints.json` — apt packages for libs not in Scout Runtime
- `manifest.json` — metadata (game, lib count, build date)
```

- [ ] **Step 2: Create .gitignore**

```
__pycache__/
*.pyc
.pytest_cache/
*.egg-info/
dist/
.env
```

- [ ] **Step 3: Create games.yml**

```yaml
games:
  - id: csgoserver
    steam_app_id: 740
    lgsm_script: csgoserver
    engine: source
    platform: linux/amd64
    login_required: false
    added: 2026-04-23
```

- [ ] **Step 4: Create index.json (initial, will be regenerated)**

```json
{}
```

- [ ] **Step 5: Initial commit**

```bash
git add README.md .gitignore games.yml index.json
git commit -m "chore: initial repo structure with csgoserver"
git push origin main
```

---

## Task 2: lib_package_map.json + gen_index.py + Tests

**Files:**
- Create: `scripts/lib_package_map.json`
- Create: `scripts/gen_index.py`
- Create: `tests/test_gen_index.py`

- [ ] **Step 1: Create scripts/lib_package_map.json**

```json
{
  "libgcc_s.so.1":            "lib32gcc-s1",
  "libstdc++.so.6":           "lib32stdc++6",
  "libsdl2-2.0.so.0":        "libsdl2-2.0-0:i386",
  "libcurl.so.4":             "libcurl4:i386",
  "libssl.so.1.0.0":         "libssl1.0.0",
  "libtcmalloc_minimal.so.4": "libgoogle-perftools4:i386",
  "libm.so.6":                "libc6:i386",
  "libdl.so.2":               "libc6:i386",
  "libc.so.6":                "libc6:i386",
  "libpthread.so.0":          "libc6:i386",
  "libz.so.1":                "zlib1g:i386",
  "libbz2.so.1.0":            "libbz2-1.0:i386"
}
```

- [ ] **Step 2: Write the failing test first**

Create `tests/test_gen_index.py`:

```python
import json
import os
import sys
import tempfile
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))
import gen_index

GAMES_YAML = """
games:
  - id: csgoserver
    steam_app_id: 740
    lgsm_script: csgoserver
    engine: source
    platform: linux/amd64
    login_required: false
    added: 2026-04-23
  - id: secretgame
    steam_app_id: 999
    lgsm_script: secretgame
    engine: unity
    platform: linux/amd64
    login_required: true
    added: 2026-04-23
"""

BASE_URL = "https://github.com/knoellix/Linux-Game-Server-Dependency-Hell"


def make_yaml_file(content):
    f = tempfile.NamedTemporaryFile(mode='w', suffix='.yml', delete=False)
    f.write(content)
    f.close()
    return f.name


def test_gen_index_includes_public_game():
    path = make_yaml_file(GAMES_YAML)
    games = gen_index.load_games(path)
    index = gen_index.build_index(games, BASE_URL)
    assert 'csgoserver' in index


def test_gen_index_excludes_login_required():
    path = make_yaml_file(GAMES_YAML)
    games = gen_index.load_games(path)
    index = gen_index.build_index(games, BASE_URL)
    assert 'secretgame' not in index


def test_gen_index_libs_url_format():
    path = make_yaml_file(GAMES_YAML)
    games = gen_index.load_games(path)
    index = gen_index.build_index(games, BASE_URL)
    entry = index['csgoserver']
    assert entry['libs_url'].endswith('/releases/download/csgoserver-latest/libs.tar.gz')
    assert entry['apt_hints_url'].endswith('/releases/download/csgoserver-latest/apt-hints.json')


def test_gen_index_metadata():
    path = make_yaml_file(GAMES_YAML)
    games = gen_index.load_games(path)
    index = gen_index.build_index(games, BASE_URL)
    entry = index['csgoserver']
    assert entry['engine'] == 'source'
    assert entry['steam_app_id'] == 740
```

- [ ] **Step 3: Run test to verify it fails**

```bash
pip install pyyaml pytest
python -m pytest tests/test_gen_index.py -v
```

Expected: `ModuleNotFoundError: No module named 'gen_index'`

- [ ] **Step 4: Create scripts/gen_index.py**

```python
#!/usr/bin/env python3
"""Generate index.json from games.yml."""
import json
import sys
import os
import yaml


def load_games(path: str) -> list:
    with open(path) as f:
        return yaml.safe_load(f)['games']


def build_index(games: list, base_url: str) -> dict:
    index = {}
    for game in games:
        if game.get('login_required'):
            continue
        game_id = game['id']
        tag = f"{game_id}-latest"
        index[game_id] = {
            'engine': game.get('engine', 'unknown'),
            'steam_app_id': game['steam_app_id'],
            'libs_url': f"{base_url}/releases/download/{tag}/libs.tar.gz",
            'apt_hints_url': f"{base_url}/releases/download/{tag}/apt-hints.json",
        }
    return index


def main():
    games_file = sys.argv[1] if len(sys.argv) > 1 else 'games.yml'
    base_url = os.environ.get(
        'REPO_URL',
        'https://github.com/knoellix/Linux-Game-Server-Dependency-Hell'
    )
    games = load_games(games_file)
    index = build_index(games, base_url)
    print(json.dumps(index, indent=2))


if __name__ == '__main__':
    main()
```

- [ ] **Step 5: Run tests**

```bash
python -m pytest tests/test_gen_index.py -v
```

Expected: all 4 tests pass.

- [ ] **Step 6: Verify gen_index.py output matches expected format**

```bash
python scripts/gen_index.py games.yml
```

Expected output:
```json
{
  "csgoserver": {
    "engine": "source",
    "steam_app_id": 740,
    "libs_url": "https://github.com/knoellix/Linux-Game-Server-Dependency-Hell/releases/download/csgoserver-latest/libs.tar.gz",
    "apt_hints_url": "https://github.com/knoellix/Linux-Game-Server-Dependency-Hell/releases/download/csgoserver-latest/apt-hints.json"
  }
}
```

- [ ] **Step 7: Generate initial index.json**

```bash
python scripts/gen_index.py games.yml > index.json
```

- [ ] **Step 8: Commit**

```bash
git add scripts/gen_index.py scripts/lib_package_map.json tests/test_gen_index.py index.json
git commit -m "feat: add gen_index.py + lib_package_map.json + tests"
git push
```

---

## Task 3: gen-index.yml — GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/gen-index.yml`

Triggers whenever `games.yml` is pushed to main → regenerates and commits `index.json`.

- [ ] **Step 1: Create .github/workflows/gen-index.yml**

```yaml
name: Regenerate index.json

on:
  push:
    branches: [main]
    paths: ['games.yml']
  workflow_dispatch:

jobs:
  gen-index:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - run: pip install pyyaml

      - name: Generate index.json
        run: python scripts/gen_index.py games.yml > index.json

      - name: Commit index.json
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add index.json
          git diff --staged --quiet && echo "No changes" || \
            git commit -m "chore: regenerate index.json" && git push
```

- [ ] **Step 2: YAML syntax check**

```bash
pip install yamllint
yamllint .github/workflows/gen-index.yml
```

Expected: no errors (or only style warnings).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/gen-index.yml
git commit -m "feat: add gen-index.yml workflow"
git push
```

---

## Task 4: Issue-Template

**Files:**
- Create: `.github/ISSUE_TEMPLATE/game-request.yml`

- [ ] **Step 1: Create .github/ISSUE_TEMPLATE/game-request.yml**

```yaml
name: Game Request
description: Request a new game server lib package
title: "[Game Request] "
labels: ["game-request"]
body:
  - type: markdown
    attributes:
      value: |
        Please provide the Steam App ID for the **dedicated server** (not the client game).
        Find it at https://store.steampowered.com/search/?category1=7 (filter: Dedicated Server).

  - type: input
    id: steam_app_id
    attributes:
      label: Steam App ID
      description: The Steam App ID of the dedicated server app (e.g. 740 for CS:GO DS)
      placeholder: "740"
    validations:
      required: true

  - type: dropdown
    id: engine
    attributes:
      label: Engine / Platform
      description: Leave blank if unknown — we'll try to auto-detect
      options:
        - "(auto-detect)"
        - source
        - goldsrc
        - unity
        - unreal
        - other
    validations:
      required: false

  - type: input
    id: lgsm_script
    attributes:
      label: LinuxGSM Script Name (optional)
      description: If you know it (e.g. csgoserver). Leave blank if unsure.
      placeholder: "csgoserver"
    validations:
      required: false
```

- [ ] **Step 2: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/ISSUE_TEMPLATE/game-request.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .github/ISSUE_TEMPLATE/game-request.yml
git commit -m "feat: add game-request issue template"
git push
```

---

## Task 5: detect_engine.sh

**Files:**
- Create: `scripts/detect_engine.sh`

Checks installed server files to determine engine. Falls back to Steam API store tags.

- [ ] **Step 1: Create scripts/detect_engine.sh**

```bash
#!/bin/bash
# detect_engine.sh — detect game engine from installed server files
# Usage: detect_engine.sh <serverfiles_dir> [steam_app_id]
# Output: one of: source | goldsrc | unity | unreal | other
set -euo pipefail

SERVERFILES="${1:?Usage: detect_engine.sh <serverfiles_dir> [steam_app_id]}"
STEAM_APP_ID="${2:-}"

# Check installed binaries for engine signatures
if find "$SERVERFILES" -name "srcds_linux" -o -name "srcds_run" 2>/dev/null | grep -q .; then
    echo "source"
    exit 0
fi

if find "$SERVERFILES" -name "hlds_linux" 2>/dev/null | grep -q .; then
    echo "goldsrc"
    exit 0
fi

if find "$SERVERFILES" -name "UnityPlayer.so" -o -name "libunity.so" 2>/dev/null | grep -q .; then
    echo "unity"
    exit 0
fi

if find "$SERVERFILES" \( -name "libUE4.so" -o -name "*-Linux-Shipping" \) 2>/dev/null | grep -q .; then
    echo "unreal"
    exit 0
fi

# Fallback: Steam API tag check
if [ -n "$STEAM_APP_ID" ]; then
    tags=$(curl -sf "https://store.steampowered.com/api/appdetails?appids=${STEAM_APP_ID}&l=english" 2>/dev/null | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
app=list(data.values())[0]
if not app.get('success'): sys.exit(1)
cats=' '.join(c.get('description','') for c in app['data'].get('categories',[]))
genres=' '.join(g.get('description','') for g in app['data'].get('genres',[]))
print((cats+' '+genres).lower())
" 2>/dev/null || echo "")

    if echo "$tags" | grep -qi "source engine\|source sdk"; then
        echo "source"; exit 0
    fi
    if echo "$tags" | grep -qi "unity"; then
        echo "unity"; exit 0
    fi
    if echo "$tags" | grep -qi "unreal"; then
        echo "unreal"; exit 0
    fi
fi

echo "other"
```

- [ ] **Step 2: Syntax check + make executable**

```bash
bash -n scripts/detect_engine.sh
chmod +x scripts/detect_engine.sh
```

Expected: no output from `bash -n`.

- [ ] **Step 3: Smoke test (no serverfiles → falls through to "other")**

```bash
bash scripts/detect_engine.sh /tmp/empty_dir_that_does_not_exist 2>/dev/null || true
# Create minimal test
mkdir -p /tmp/test_serverfiles
bash scripts/detect_engine.sh /tmp/test_serverfiles
```

Expected: `other`

- [ ] **Step 4: Test Source Engine detection**

```bash
mkdir -p /tmp/test_source/serverfiles
touch /tmp/test_source/serverfiles/srcds_linux
bash scripts/detect_engine.sh /tmp/test_source/serverfiles
rm -rf /tmp/test_source
```

Expected: `source`

- [ ] **Step 5: Commit**

```bash
git add scripts/detect_engine.sh
git commit -m "feat: add detect_engine.sh for engine auto-detection"
git push
```

---

## Task 6: build_game.sh

**Files:**
- Create: `scripts/build_game.sh`

Core build script: installs game via LGSM, runs ldd, collects libs from Scout Runtime, packages.

- [ ] **Step 1: Create scripts/build_game.sh**

```bash
#!/bin/bash
# build_game.sh — build lib package for a LinuxGSM game server
# Usage: build_game.sh <game_id> <output_dir>
# Runs as root inside debian:bookworm Docker container.
# Scout Runtime must already be set up at /opt/steam-runtime/
set -euo pipefail

GAME_ID="${1:?Usage: build_game.sh <game_id> <output_dir>}"
OUTPUT_DIR="${2:?Usage: build_game.sh <game_id> <output_dir>}"
SCOUT_INDEX="/opt/steam-runtime/lib_index.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_MAP="$SCRIPT_DIR/lib_package_map.json"

mkdir -p "$OUTPUT_DIR/libs"

echo "=== Setting up game user ==="
if ! id gameserver &>/dev/null; then
    useradd -m -s /usr/sbin/nologin gameserver
fi

echo "=== Installing LinuxGSM + $GAME_ID ==="
su -s /bin/bash -c "
    set -euo pipefail
    mkdir -p /home/gameserver/$GAME_ID
    cd /home/gameserver/$GAME_ID
    curl -Lo linuxgsm.sh https://linuxgsm.sh
    chmod +x linuxgsm.sh
    bash linuxgsm.sh '$GAME_ID'
    ./'$GAME_ID' auto-install
" gameserver

SERVERFILES="/home/gameserver/$GAME_ID"

echo "=== Detecting engine ==="
ENGINE=$(bash "$SCRIPT_DIR/detect_engine.sh" "$SERVERFILES/serverfiles" 2>/dev/null || echo "other")
echo "Engine: $ENGINE"

echo "=== Scanning binaries with ldd ==="
find "$SERVERFILES/serverfiles" -type f \( -executable -o -name "*.so*" \) 2>/dev/null | \
while read -r binary; do
    ldd "$binary" 2>/dev/null | grep "not found" | awk '{print $1}'
done | sort -u > /tmp/missing_libs.txt

echo "Missing libs ($(wc -l < /tmp/missing_libs.txt)):"
cat /tmp/missing_libs.txt

APT_HINTS=()

echo "=== Resolving libs from Scout Runtime ==="
while IFS= read -r libname; do
    [ -z "$libname" ] && continue

    # Try Scout Runtime index
    if [ -f "$SCOUT_INDEX" ]; then
        runtime_path=$(jq -r --arg lib "$libname" '.[$lib] // empty' "$SCOUT_INDEX" 2>/dev/null)
        if [ -n "$runtime_path" ] && [ -f "$runtime_path" ]; then
            # Path-traversal guard
            if [[ "$runtime_path" != /opt/steam-runtime/* ]]; then
                echo "  SKIP (suspicious path): $libname -> $runtime_path"
                continue
            fi
            echo "  [Scout] $libname"
            cp "$runtime_path" "$OUTPUT_DIR/libs/$libname"
            continue
        fi
    fi

    # Fallback: apt package map
    pkg=$(jq -r --arg lib "$libname" '.[$lib] // empty' "$LIB_MAP" 2>/dev/null)
    if [ -n "$pkg" ]; then
        echo "  [apt-hint] $libname -> $pkg"
        APT_HINTS+=("$pkg")
    else
        echo "  [not found] $libname"
    fi
done < /tmp/missing_libs.txt

echo "=== Writing apt-hints.json ==="
python3 -c "
import json, sys
hints = sys.argv[1:]
# Deduplicate preserving order
seen = set()
unique = [h for h in hints if not (h in seen or seen.add(h))]
print(json.dumps(unique, indent=2))
" "${APT_HINTS[@]:-}" > "$OUTPUT_DIR/apt-hints.json"

echo "=== Writing manifest.json ==="
lib_count=$(ls "$OUTPUT_DIR/libs/" 2>/dev/null | wc -l)
python3 -c "
import json, datetime
print(json.dumps({
    'game': '$GAME_ID',
    'engine': '$ENGINE',
    'built_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'lib_count': $lib_count,
}, indent=2))
" > "$OUTPUT_DIR/manifest.json"

echo "=== Packaging ==="
cd "$OUTPUT_DIR"
# --no-dereference: pack symlinks as symlinks, not contents
# --exclude-from: prevent path traversal
tar czf libs.tar.gz \
    --no-dereference \
    --exclude='*/..' \
    libs/ apt-hints.json manifest.json

echo "=== Build complete: $OUTPUT_DIR/libs.tar.gz ==="
echo "  Libs packaged: $lib_count"
echo "  apt-hints: $(jq length "$OUTPUT_DIR/apt-hints.json") packages"
```

- [ ] **Step 2: Syntax check + make executable**

```bash
bash -n scripts/build_game.sh
chmod +x scripts/build_game.sh
```

Expected: no output from `bash -n`.

- [ ] **Step 3: Smoke test (missing args → usage error)**

```bash
bash scripts/build_game.sh 2>&1 | head -3
```

Expected: `Usage: build_game.sh <game_id> <output_dir>` or similar.

- [ ] **Step 4: Commit**

```bash
git add scripts/build_game.sh
git commit -m "feat: add build_game.sh for ldd-based lib packaging"
git push
```

---

## Task 7: build-game.yml — Main Build Workflow

**Files:**
- Create: `.github/workflows/build-game.yml`

Runs in Docker `debian:bookworm`. Sets up Scout Runtime (cached weekly), installs LGSM + game, runs `build_game.sh`, publishes GitHub Release.

- [ ] **Step 1: Create .github/workflows/build-game.yml**

```yaml
name: Build Game Libs

on:
  workflow_dispatch:
    inputs:
      game_id:
        description: 'LinuxGSM script name (e.g. csgoserver)'
        required: true
        type: string

jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: debian:bookworm
      options: --privileged

    permissions:
      contents: write

    steps:
      - uses: actions/checkout@v4

      - name: Install system dependencies
        run: |
          dpkg --add-architecture i386
          apt-get update -qq
          apt-get install -y --no-install-recommends \
            curl wget tar jq python3 python3-yaml \
            lib32gcc-s1 steamcmd \
            ca-certificates gnupg lsb-release \
            gh git 2>/dev/null || true
          # steamcmd may need contrib/non-free
          sed -i 's/^deb \(.*\) bookworm main$/deb \1 bookworm main contrib non-free/' /etc/apt/sources.list || true
          apt-get update -qq
          apt-get install -y steamcmd 2>/dev/null || true

      - name: Cache Scout Runtime
        uses: actions/cache@v4
        id: scout-cache
        with:
          path: /opt/steam-runtime
          key: scout-runtime-${{ runner.os }}-${{ steps.date.outputs.week }}

      - name: Get week number for cache key
        id: date
        run: echo "week=$(date +%Y-W%V)" >> "$GITHUB_OUTPUT"

      - name: Setup Scout Runtime
        if: steps.scout-cache.outputs.cache-hit != 'true'
        run: |
          mkdir -p /opt/steam-runtime
          cd /opt/steam-runtime
          TARBALL="com.valvesoftware.SteamRuntime.Sdk-amd64,i386-scout-sysroot.tar.gz"
          URL="https://repo.steampowered.com/steamrt-images-scout/snapshots/latest-steam-client-general-availability/${TARBALL}"
          wget -q --show-progress -O "${TARBALL}.tmp" "$URL"
          mv "${TARBALL}.tmp" "$TARBALL"
          tar -xf "$TARBALL"
          rm -f "$TARBALL"
          # Build lib_index.json
          find /opt/steam-runtime -name "*.so*" -not -type d | python3 -c '
          import json, sys
          idx = {}
          for line in sys.stdin:
              line = line.strip()
              name = line.split("/")[-1]
              idx.setdefault(name, line)
          with open("/opt/steam-runtime/lib_index.json", "w") as f:
              json.dump(idx, f)
          print(f"Indexed {len(idx)} libraries.")
          '

      - name: Build lib package
        run: |
          mkdir -p /output
          bash scripts/build_game.sh "${{ inputs.game_id }}" /output

      - name: Publish GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG="${{ inputs.game_id }}-latest"
          GAME_NAME=$(jq -r '.game' /output/manifest.json)
          # Delete old release and tag (rolling release)
          gh release delete "$TAG" --yes 2>/dev/null || true
          git push origin --delete "$TAG" 2>/dev/null || true
          # Create new release
          gh release create "$TAG" \
            --title "Libs: ${GAME_NAME}" \
            --notes "Auto-built by CI. See manifest.json for details." \
            /output/libs.tar.gz \
            /output/apt-hints.json \
            /output/manifest.json

      - name: Regenerate index.json
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          python3 scripts/gen_index.py games.yml > index.json
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add index.json
          git diff --staged --quiet && echo "index.json unchanged" || \
            (git commit -m "chore: update index.json after ${{ inputs.game_id }} build" && git push)
```

- [ ] **Step 2: YAML syntax check**

```bash
yamllint .github/workflows/build-game.yml
```

Expected: no errors.

- [ ] **Step 3: Commit + trigger test run**

```bash
git add .github/workflows/build-game.yml
git commit -m "feat: add build-game.yml workflow (Docker debian:bookworm)"
git push
```

Then trigger manually:
```bash
gh workflow run build-game.yml --field game_id=csgoserver
```

Monitor:
```bash
gh run list --workflow=build-game.yml --limit 5
gh run watch  # watch the latest run
```

Expected: run completes with green status, release `csgoserver-latest` created on GitHub.

---

## Task 8: issue-handler.yml

**Files:**
- Create: `.github/workflows/issue-handler.yml`
- Create: `scripts/parse_issue.py`
- Create: `scripts/validate_game.py`

- [ ] **Step 1: Create scripts/parse_issue.py**

Parses GitHub issue body (from YAML issue template) to extract fields.

```python
#!/usr/bin/env python3
"""Parse GitHub issue body fields from YAML-format issue templates."""
import re
import sys
import json


def parse_issue_body(body: str) -> dict:
    result = {}

    patterns = {
        'steam_app_id': r'### Steam App ID\s*\n+(\d+)',
        'engine': r'### Engine / Platform\s*\n+([a-z\-]+)',
        'lgsm_script': r'### LinuxGSM Script Name.*\n+([a-zA-Z0-9_-]+)',
    }

    for key, pattern in patterns.items():
        m = re.search(pattern, body, re.IGNORECASE)
        if m:
            val = m.group(1).strip()
            if val and val not in ('(auto-detect)', '_No response_'):
                result[key] = val

    return result


if __name__ == '__main__':
    body = sys.stdin.read()
    parsed = parse_issue_body(body)
    print(json.dumps(parsed))
```

- [ ] **Step 2: Create scripts/validate_game.py**

```python
#!/usr/bin/env python3
"""Validate a game request: Steam API + LGSM script lookup."""
import sys
import json
import urllib.request
import urllib.error


def check_steam(app_id: int) -> dict:
    url = f"https://store.steampowered.com/api/appdetails?appids={app_id}&l=english"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read())
        app_data = list(data.values())[0]
        if not app_data.get('success'):
            return {'ok': False, 'reason': 'App ID not found on Steam'}
        info = app_data['data']
        platforms = info.get('platforms', {})
        if not platforms.get('linux'):
            return {'ok': False, 'reason': f"'{info.get('name')}' has no Linux support"}
        return {
            'ok': True,
            'name': info.get('name', ''),
            'categories': [c.get('description', '') for c in info.get('categories', [])],
            'genres': [g.get('description', '') for g in info.get('genres', [])],
        }
    except Exception as e:
        return {'ok': False, 'reason': f'Steam API error: {e}'}


def detect_engine_from_steam(steam_info: dict) -> str:
    text = ' '.join(steam_info.get('categories', []) + steam_info.get('genres', [])).lower()
    if 'source engine' in text or 'source sdk' in text:
        return 'source'
    if 'unity' in text:
        return 'unity'
    if 'unreal' in text:
        return 'unreal'
    return ''


def check_lgsm_script(lgsm_script: str) -> bool:
    """Check if script exists in LinuxGSM repo game list."""
    url = (
        "https://raw.githubusercontent.com/GameServerManagers/LinuxGSM/"
        "master/lgsm/data/serverlist.csv"
    )
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            content = r.read().decode()
        return any(
            line.split(',')[0].strip() == lgsm_script
            for line in content.splitlines()
        )
    except Exception:
        return False


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-id', type=int, required=True)
    parser.add_argument('--lgsm-script', default='')
    args = parser.parse_args()

    steam = check_steam(args.app_id)
    if not steam['ok']:
        print(json.dumps({'valid': False, 'reason': steam['reason']}))
        sys.exit(0)

    engine = detect_engine_from_steam(steam)

    lgsm_ok = check_lgsm_script(args.lgsm_script) if args.lgsm_script else None

    print(json.dumps({
        'valid': True,
        'name': steam['name'],
        'engine': engine,
        'lgsm_script_found': lgsm_ok,
    }))
```

- [ ] **Step 3: Create .github/workflows/issue-handler.yml**

```yaml
name: Issue Handler — Game Request

on:
  issues:
    types: [opened, labeled]

jobs:
  handle:
    if: contains(github.event.issue.labels.*.name, 'game-request')
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: write
      pull-requests: write

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Parse issue body
        id: parse
        env:
          ISSUE_BODY: ${{ github.event.issue.body }}
        run: |
          parsed=$(echo "$ISSUE_BODY" | python3 scripts/parse_issue.py)
          echo "parsed=$parsed" >> "$GITHUB_OUTPUT"
          app_id=$(echo "$parsed" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('steam_app_id',''))")
          echo "app_id=$app_id" >> "$GITHUB_OUTPUT"
          lgsm=$(echo "$parsed" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('lgsm_script',''))")
          echo "lgsm_script=$lgsm" >> "$GITHUB_OUTPUT"

      - name: Validate Steam App ID
        if: steps.parse.outputs.app_id != ''
        id: validate
        run: |
          result=$(python3 scripts/validate_game.py \
            --app-id "${{ steps.parse.outputs.app_id }}" \
            --lgsm-script "${{ steps.parse.outputs.lgsm_script }}")
          echo "result=$result" >> "$GITHUB_OUTPUT"
          echo "valid=$(echo $result | python3 -c "import json,sys; print(json.load(sys.stdin).get('valid','false'))")" >> "$GITHUB_OUTPUT"
          echo "name=$(echo $result | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")" >> "$GITHUB_OUTPUT"
          echo "engine=$(echo $result | python3 -c "import json,sys; print(json.load(sys.stdin).get('engine',''))")" >> "$GITHUB_OUTPUT"

      - name: Comment — invalid app id
        if: steps.parse.outputs.app_id == ''
        uses: peter-evans/create-or-update-comment@v4
        with:
          issue-number: ${{ github.event.issue.number }}
          body: |
            ❌ **Could not parse Steam App ID** from this issue.
            Please use the issue template and fill in the App ID field.

      - name: Comment — not valid / no Linux
        if: steps.parse.outputs.app_id != '' && steps.validate.outputs.valid == 'False'
        uses: peter-evans/create-or-update-comment@v4
        with:
          issue-number: ${{ github.event.issue.number }}
          body: |
            ❌ **Validation failed:**
            ${{ fromJson(steps.validate.outputs.result).reason }}

      - name: Create PR to add game
        if: steps.validate.outputs.valid == 'True'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          GAME_ID="${{ steps.parse.outputs.lgsm_script }}"
          APP_ID="${{ steps.parse.outputs.app_id }}"
          GAME_NAME="${{ steps.validate.outputs.name }}"
          ENGINE="${{ steps.validate.outputs.engine }}"
          TODAY=$(date +%Y-%m-%d)
          BRANCH="add-game/${GAME_ID:-app-$APP_ID}"

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git checkout -b "$BRANCH"

          # Add entry to games.yml
          python3 -c "
          import yaml, sys
          with open('games.yml') as f:
              data = yaml.safe_load(f)
          data['games'].append({
              'id': '$GAME_ID' or 'game-$APP_ID',
              'steam_app_id': int('$APP_ID'),
              'lgsm_script': '$GAME_ID' or '',
              'engine': '$ENGINE' or 'other',
              'platform': 'linux/amd64',
              'login_required': False,
              'added': '$TODAY',
          })
          with open('games.yml', 'w') as f:
              yaml.dump(data, f, allow_unicode=True, sort_keys=False)
          "

          git add games.yml
          git commit -m "feat: add $GAME_NAME ($APP_ID)"
          git push origin "$BRANCH"

          PR_URL=$(gh pr create \
            --title "Add game: $GAME_NAME ($APP_ID)" \
            --body "Closes #${{ github.event.issue.number }}

          Automatically generated from issue request.
          After merge, the build workflow will run automatically." \
            --base main \
            --head "$BRANCH")

          gh issue comment "${{ github.event.issue.number }}" \
            --body "✅ Validated! PR created: $PR_URL — build will start after merge."
```

- [ ] **Step 4: YAML syntax checks**

```bash
yamllint .github/workflows/issue-handler.yml
python3 -m py_compile scripts/parse_issue.py && echo "parse_issue.py OK"
python3 -m py_compile scripts/validate_game.py && echo "validate_game.py OK"
```

Expected: no errors.

- [ ] **Step 5: Test parse_issue.py locally**

```bash
echo '### Steam App ID

740

### Engine / Platform

source

### LinuxGSM Script Name (optional)

csgoserver' | python3 scripts/parse_issue.py
```

Expected:
```json
{"steam_app_id": "740", "engine": "source", "lgsm_script": "csgoserver"}
```

- [ ] **Step 6: Test validate_game.py locally (requires internet)**

```bash
python3 scripts/validate_game.py --app-id 740 --lgsm-script csgoserver
```

Expected: JSON with `"valid": true`, `"name"` contains "Counter-Strike".

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/issue-handler.yml scripts/parse_issue.py scripts/validate_game.py
git commit -m "feat: add issue-handler workflow + parse/validate scripts"
git push
```

---

## Task 9: build-all.yml — Weekly Rebuild

**Files:**
- Create: `.github/workflows/build-all.yml`

- [ ] **Step 1: Create .github/workflows/build-all.yml**

```yaml
name: Weekly Rebuild All Games

on:
  schedule:
    - cron: '0 3 * * 0'   # Every Sunday at 03:00 UTC
  workflow_dispatch:

jobs:
  collect-games:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.matrix.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - run: pip install pyyaml
      - name: Build matrix
        id: matrix
        run: |
          matrix=$(python3 -c "
          import yaml, json
          with open('games.yml') as f:
              games = yaml.safe_load(f)['games']
          ids = [g['id'] for g in games if not g.get('login_required')]
          print(json.dumps({'game_id': ids}))
          ")
          echo "matrix=$matrix" >> \"\$GITHUB_OUTPUT\"

  build:
    needs: collect-games
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.collect-games.outputs.matrix) }}
    uses: ./.github/workflows/build-game.yml
    with:
      game_id: ${{ matrix.game_id }}
    permissions:
      contents: write
```

- [ ] **Step 2: YAML syntax check**

```bash
yamllint .github/workflows/build-all.yml
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-all.yml
git commit -m "feat: add build-all.yml weekly rebuild cron"
git push
```

---

## Task 10: End-to-End Test

Verify the full pipeline works with `csgoserver`.

- [ ] **Step 1: Trigger build manually**

```bash
gh workflow run build-game.yml --field game_id=csgoserver
```

- [ ] **Step 2: Watch until completion**

```bash
gh run list --workflow=build-game.yml --limit 3
gh run watch
```

Expected: green ✅, runtime ~10-20 min (Scout Runtime cached after first run).

- [ ] **Step 3: Verify release was created**

```bash
gh release view csgoserver-latest
```

Expected: release with assets `libs.tar.gz`, `apt-hints.json`, `manifest.json`.

- [ ] **Step 4: Verify index.json was updated**

```bash
cat index.json | python3 -m json.tool
```

Expected: entry for `csgoserver` with correct URLs.

- [ ] **Step 5: Download and inspect package**

```bash
gh release download csgoserver-latest --pattern "*.tar.gz" -D /tmp/
tar tf /tmp/libs.tar.gz | head -20
cat /tmp/apt-hints.json
```

Expected: list of `.so` files in `libs/`, apt-hints with known packages.

---

## Self-Review

### Spec Coverage

| Spec Requirement | Task |
|-----------------|------|
| `games.yml` source-of-truth | Task 1 |
| `index.json` generated format | Task 2 |
| `gen_index.py` + tests | Task 2 |
| `gen-index.yml` on push | Task 3 |
| Issue template (Steam App ID + Engine) | Task 4 |
| `detect_engine.sh` (binary + Steam API) | Task 5 |
| `build_game.sh` (ldd + Scout + package) | Task 6 |
| `build-game.yml` Docker debian:bookworm | Task 7 |
| Scout Runtime cached | Task 7 (actions/cache) |
| `{game_id}-latest` rolling tag | Task 7 |
| `issue-handler.yml` (Steam API validation → PR) | Task 8 |
| `parse_issue.py` + `validate_game.py` | Task 8 |
| `build-all.yml` weekly cron | Task 9 |
| Path-traversal guard in build_game.sh | Task 6 |
| `lib_package_map.json` apt fallback | Tasks 2 + 6 |
| End-to-end test | Task 10 |

### No Placeholders ✅
### Type Consistency ✅
- `load_games(path)` → `build_index(games, base_url)` consistent Tasks 2+3
- `parse_issue_body(body)` → dict, used in Task 8 workflow consistently
