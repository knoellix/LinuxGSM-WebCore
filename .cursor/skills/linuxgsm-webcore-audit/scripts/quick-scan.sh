#!/usr/bin/env bash
# Quick heuristic scan for LinuxGSM-WebCore audits.
# Exit 0 always — findings need human/subagent review.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT"
export ROOT

echo "=== LinuxGSM-WebCore quick-scan ==="
echo "Repo: $ROOT"
echo

section() {
  echo "--- $1 ---"
}

section "Lang parity (de/en + \$1 placeholders)"
bash "$ROOT/.cursor/skills/linuxgsm-webcore-audit/scripts/lang-parity.sh" || true
echo

section "Runtime apt outside provision_deps.sh"
if rg -q 'apt-get|apt install' src/scripts --glob '!provision_deps.sh' 2>/dev/null; then
  rg -n 'apt-get|apt install' src/scripts --glob '!provision_deps.sh'
else
  echo "(none)"
fi
echo

section "setsid nohup bash (review: use user_worker_launch_cmd?)"
if rg -q 'setsid nohup bash' src/ 2>/dev/null; then
  rg -n 'setsid nohup bash' src/
else
  echo "(none)"
fi
echo

section "su usage (classify per allowed-patterns.md)"
rg -n '\bsu\b' src/ 2>/dev/null || echo "(none)"
echo

section "Success URL params (verify flash/read-back on GET)"
rg -n '\?saved=1|\?ok=1|\?msg=' src/*.cgi 2>/dev/null || echo "(none)"
echo

section "redirect lines missing exit on following line (heuristic)"
python3 - <<'PY' 2>/dev/null || echo "(python3 check skipped)"
import re, glob, os
root = os.environ.get("ROOT", ".")
for path in sorted(glob.glob(os.path.join(root, "src", "*.cgi"))):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    for i, line in enumerate(lines):
        if re.search(r"&redirect\s*\(", line):
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
            if nxt != "exit;" and not re.match(r"exit\s*;", nxt):
                print(f"{path}:{i+1}: redirect without immediate exit")
PY
echo

echo "=== End quick-scan (interpret with allowed-patterns.md) ==="
