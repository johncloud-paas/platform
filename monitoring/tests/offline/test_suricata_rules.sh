#!/usr/bin/env bash
# Offline test: the Suricata rule files load cleanly. Runs `suricata -T` (config
# + rules self-test) inside a throwaway jasonish/suricata container against the
# production local.rules and the live e2e test rule. SKIPs if docker is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

IMAGE="jasonish/suricata:latest"

echo "== offline: suricata rule syntax =="

if ! command -v docker >/dev/null 2>&1; then
  skip "docker unavailable — cannot run 'suricata -T'"
  finish
  exit $?
fi

# test_rules <label> <container-relative-rule-path>
test_rules() {
  local label="$1" rel="$2" out rc
  out="$(docker run --rm -v "$MON_DIR":/work:ro --entrypoint suricata "$IMAGE" \
          -T -S "/work/$rel" -l /tmp 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$label loads ($rel)"
  else
    fail "$label failed 'suricata -T' ($rel)"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

test_rules "local.rules"       "suricata/local.rules"
test_rules "fail2ban-e2e.rules" "tests/live/fail2ban-e2e.rules"

finish
