#!/usr/bin/env bash
# Offline test: the committed Fail2ban glue files wire the pipeline the way the
# jail expects — filter scoped to severity 1, raw/PREROUTING ban action, polling
# backend. Pure text assertions on the source-of-truth files; optionally runs
# `fail2ban-client -t` when the daemon/binary is present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

F2B="$MON_DIR/fail2ban"
FILTER="$F2B/filter.d/suricata.conf"
ACTION="$F2B/action.d/suricata-raw.conf"
JAIL="$F2B/jail.d/suricata.template.conf"

echo "== offline: fail2ban config sanity =="

assert_contains "$(cat "$FILTER")" '"severity":1' "filter scopes to severity 1"
assert_contains "$(cat "$FILTER")" 'event_type":"alert' "filter targets alert events"
assert_contains "$(cat "$FILTER")" '<HOST>' "filter captures the source host"

assert_contains "$(cat "$ACTION")" '-t raw -I PREROUTING' "action bans in raw/PREROUTING"
assert_contains "$(cat "$ACTION")" '-t raw -D PREROUTING' "action unbans in raw/PREROUTING"

assert_contains "$(cat "$JAIL")" 'banaction = suricata-raw' "jail uses the suricata-raw action"
assert_contains "$(cat "$JAIL")" 'filter   = suricata' "jail uses the suricata filter"
assert_contains "$(cat "$JAIL")" 'backend  = polling' "jail polls the bind-mounted eve.json"

# Global config validity, only when fail2ban is installed as a daemon here.
if command -v fail2ban-client >/dev/null 2>&1; then
  if fail2ban-client -t >/dev/null 2>&1; then
    pass "fail2ban-client -t: installed config is valid"
  else
    fail "fail2ban-client -t reported invalid config"
  fi
else
  skip "fail2ban-client absent — skipping global 'fail2ban-client -t' check"
fi

finish
