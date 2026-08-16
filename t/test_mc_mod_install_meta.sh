#!/bin/bash
# Regression: mc_mod_install_user.sh read_meta must emit one field per line.
# Perl `print (EXPR), "\n"` drops the newline and glued prefer_disabled (0) onto SHA1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SHA1='725b5cd66eb8a23325b74200bcb45c683bbe872c'
cat >"$TMP/mod_meta.json" <<EOF
{
  "title": "Patchouli",
  "filename": "patchouli-neoforge-26.1-94.jar",
  "download_url": "https://example.invalid/patchouli.jar",
  "mod_dir": "mods",
  "source": "modrinth",
  "hashes": { "sha1": "$SHA1" },
  "prefer_disabled": 0,
  "replace_basename": "",
  "force_replace": 0
}
EOF

META_FILE="$TMP/mod_meta.json"
# Same field extraction as src/scripts/mc_mod_install_user.sh (keep in sync).
mapfile -t _META < <(perl -MJSON::PP=decode_json -e '
    open my $f, "<", shift or exit 1;
    local $/; my $m = decode_json(<$f>);
    my $sha1 = $m->{hashes}{sha1} // "";
    $sha1 = "" unless $sha1 =~ /^[0-9a-fA-F]{40}$/;
    print $m->{title} // "", "\n";
    print $m->{filename} // "", "\n";
    print $m->{download_url} // "", "\n";
    print $m->{mod_dir} // "mods", "\n";
    print $m->{source} // "", "\n";
    print $sha1, "\n";
    print(($m->{prefer_disabled} // 0) ? 1 : 0, "\n");
    print $m->{replace_basename} // "", "\n";
    print(($m->{force_replace} // 0) ? 1 : 0, "\n");
' "$META_FILE")

test "${#_META[@]}" -eq 9
test "${_META[5]}" = "$SHA1"
test "${_META[6]}" = "0"
test "${#_META[5]}" -eq 40

# Guard: worker must not use the print-(EXPR),-"\n" form that drops newlines.
if grep -nE '^[[:space:]]*print.*\),[[:space:]]*"\\n"' \
    "$ROOT/src/scripts/mc_mod_install_user.sh"; then
    echo "FAIL: print (EXPR), \"\\n\" gotcha still present" >&2
    exit 1
fi

echo "ok - mod install meta fields split correctly"
