#!/usr/bin/env bash
# Compare src/lang/de vs src/lang/en keys. Exit 1 if mismatch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
DE="$ROOT/src/lang/de"
EN="$ROOT/src/lang/en"

extract_keys() {
  local f="$1"
  awk -F= '/^[a-zA-Z0-9_]+=/ { print $1 }' "$f" | sort -u
}

if [[ ! -f "$DE" || ! -f "$EN" ]]; then
  echo "lang-parity: missing src/lang/de or src/lang/en" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
extract_keys "$DE" >"$TMP/de.keys"
extract_keys "$EN" >"$TMP/en.keys"

only_de="$(comm -23 "$TMP/de.keys" "$TMP/en.keys" || true)"
only_en="$(comm -13 "$TMP/de.keys" "$TMP/en.keys" || true)"

echo "=== Lang parity: de vs en ==="
echo "de keys: $(wc -l <"$TMP/de.keys") | en keys: $(wc -l <"$TMP/en.keys")"
echo

if [[ -n "$only_de" ]]; then
  echo "--- only in de (missing in en) ---"
  echo "$only_de"
  echo
fi

if [[ -n "$only_en" ]]; then
  echo "--- only in en (missing in de) ---"
  echo "$only_en"
  echo
fi

# Webmin placeholder style
bad_de="$(rg -n '%s' "$DE" 2>/dev/null || true)"
bad_en="$(rg -n '%s' "$EN" 2>/dev/null || true)"
if [[ -n "$bad_de" || -n "$bad_en" ]]; then
  echo "--- %s placeholders (use \$1 for text()) ---"
  [[ -n "$bad_de" ]] && echo "de:" && echo "$bad_de"
  [[ -n "$bad_en" ]] && echo "en:" && echo "$bad_en"
  echo
fi

if [[ -n "$only_de" || -n "$only_en" ]]; then
  echo "lang-parity: FAIL"
  exit 1
fi

if [[ -n "$bad_de" || -n "$bad_en" ]]; then
  echo "lang-parity: WARN (%s placeholders)"
  exit 0
fi

echo "lang-parity: OK"
exit 0
