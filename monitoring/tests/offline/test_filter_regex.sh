#!/usr/bin/env bash
# Offline test: the Fail2ban Suricata filter matches ONLY high-severity (severity 1)
# alert events and captures the attacker src_ip — while ignoring medium-severity
# alerts, the ICMP smoke-test rule (sid 1000001) and non-alert events.
#
# Runs fail2ban-regex against hand-written eve.json fixtures. Uses the host
# fail2ban-regex if present, else a throwaway fail2ban container, else SKIPs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

FILTER="$MON_DIR/fail2ban/filter.d/suricata.conf"
FIX="$TESTS_DIR/fixtures/eve"

echo "== offline: fail2ban filter regex =="

# Pick a way to run fail2ban-regex. Return the command via the F2B_REGEX array.
F2B_REGEX=()
if command -v fail2ban-regex >/dev/null 2>&1; then
  F2B_REGEX=(fail2ban-regex)
elif command -v docker >/dev/null 2>&1; then
  # Best-effort container fallback; mount the monitoring tree read-only at /work.
  if docker run --rm --entrypoint fail2ban-regex crazymax/fail2ban:latest --version >/dev/null 2>&1; then
    F2B_REGEX=(docker run --rm -v "$MON_DIR":/work:ro --entrypoint fail2ban-regex crazymax/fail2ban:latest)
  fi
fi

if [ "${#F2B_REGEX[@]}" -eq 0 ]; then
  skip "fail2ban-regex unavailable (no host binary, no usable container image)"
  finish
  exit $?
fi

# run_regex <logfile> -> echoes fail2ban-regex output; translates paths for the
# container case so /work-relative paths resolve inside the mount.
run_regex() {
  local log="$1" flt="$FILTER"
  if [ "${F2B_REGEX[0]}" = "docker" ]; then
    log="/work/${log#"$MON_DIR"/}"
    flt="/work/${flt#"$MON_DIR"/}"
  fi
  "${F2B_REGEX[@]}" --print-all-matched "$log" "$flt" 2>&1 || true
}

# matched_count <output> -> number from the "Lines: ... N matched ..." summary.
matched_count() {
  printf '%s\n' "$1" | sed -n 's/.*,[[:space:]]*\([0-9][0-9]*\)[[:space:]]*matched.*/\1/p' | tail -n1
}

# --- severity 1: must match once and capture the src_ip -----------------------
out="$(run_regex "$FIX/alert_severity1.json")"
assert_eq "1" "$(matched_count "$out")" "severity-1 alert matches (1 hit)"
assert_contains "$out" "203.0.113.66" "severity-1 alert captures src_ip 203.0.113.66"
assert_not_contains "$out" "no date" "datepattern parses the ISO8601 timestamp"

# --- severity 2: must NOT match ----------------------------------------------
out="$(run_regex "$FIX/alert_severity2.json")"
assert_eq "0" "$(matched_count "$out")" "severity-2 alert is ignored (0 hits)"

# --- ICMP smoke test (sid 1000001, severity 3): must NOT match ----------------
out="$(run_regex "$FIX/alert_icmp_smoketest.json")"
assert_eq "0" "$(matched_count "$out")" "ICMP smoke-test alert is ignored (0 hits)"

# --- non-alert (dns) event: must NOT match ------------------------------------
out="$(run_regex "$FIX/event_dns.json")"
assert_eq "0" "$(matched_count "$out")" "non-alert dns event is ignored (0 hits)"

finish
