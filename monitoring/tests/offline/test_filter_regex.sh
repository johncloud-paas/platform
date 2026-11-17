#!/usr/bin/env bash
# Offline test: exercise the committed Fail2ban filters with `fail2ban-regex`
# against sample log fixtures — the deterministic "does detection fire?" check
# (the equivalent of a rules dry-run). Malicious fixtures must match; benign
# fixtures must not. SKIPs green if fail2ban-regex is not installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

FIX="$TESTS_DIR/fixtures"
FILTERS="$MON_DIR/fail2ban/filter.d"

echo "== offline: Fail2ban filter detection (fail2ban-regex) =="

if ! command -v fail2ban-regex >/dev/null 2>&1; then
    skip "fail2ban-regex absent — cannot test filter matching"
    finish
    exit $?
fi

# matched_count <logfile> <filter[options]> : echo the number of matched lines.
matched_count() {
    fail2ban-regex "$1" "$2" 2>/dev/null \
        | grep -oE '[0-9]+ matched' | grep -oE '^[0-9]+' | head -n1
}

# assert_matches_at_least <n> <logfile> <filter> <message>
assert_matches_at_least() {
    local want="$1" log="$2" filt="$3" msg="$4" got
    got="$(matched_count "$log" "$filt")"; got="${got:-0}"
    if [ "$got" -ge "$want" ]; then
        pass "$msg ($got matched)"
    else
        fail "$msg (expected >= $want, got $got)"
    fi
}

# assert_no_match <logfile> <filter> <message>
assert_no_match() {
    local log="$1" filt="$2" msg="$3" got
    got="$(matched_count "$log" "$filt")"; got="${got:-0}"
    if [ "$got" -eq 0 ]; then
        pass "$msg (0 matched)"
    else
        fail "$msg (expected 0, got $got)"
    fi
}

# --- Traefik access filter --------------------------------------------------
assert_matches_at_least 4 "$FIX/traefik-access.log" \
    "$FILTERS/traefik-access.conf[mode=4xx]" \
    "traefik 4xx mode detects repeated client errors"

assert_matches_at_least 1 "$FIX/traefik-access.log" \
    "$FILTERS/traefik-access.conf[mode=bot]" \
    "traefik bot mode detects scanner User-Agents (sqlmap/nikto)"

assert_no_match "$FIX/traefik-benign.log" \
    "$FILTERS/traefik-access.conf[mode=4xx]" \
    "traefik 4xx mode ignores benign 2xx/3xx traffic"

assert_no_match "$FIX/traefik-benign.log" \
    "$FILTERS/traefik-access.conf[mode=bot]" \
    "traefik bot mode ignores normal User-Agents"

# --- Docker apps filter -----------------------------------------------------
assert_matches_at_least 4 "$FIX/docker-apps.log" \
    "$FILTERS/docker-apps.conf" \
    "docker-apps filter detects auth failures"

assert_no_match "$FIX/docker-benign.log" \
    "$FILTERS/docker-apps.conf" \
    "docker-apps filter ignores normal app logs"

finish
