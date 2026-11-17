#!/usr/bin/env bash
# Live end-to-end test: Fail2ban detection -> ban -> nftables enforcement.
#
# Two parts, both targeting the inert RFC 5737 TEST-NET IP 203.0.113.66 (never a
# real client) and cleaned up via a trap:
#
#   1. Firewall path: manually ban the IP in the sshd jail and assert it lands in
#      the jail status AND in the nftables ruleset, then unban.
#   2. Organic trigger: spin up a throwaway jail that reuses the committed
#      traefik-access filter (4xx mode) tailing a temp logfile, feed it
#      maxretry+1 crafted 4xx lines for the target, and assert Fail2ban detects
#      and bans it on its own — exercising the real filter -> findtime/maxretry
#      -> ban -> nftables path with no risk of self-ban.
#
# Invasive: needs root and a running fail2ban.service; mutates the host firewall.
# Run via `sudo ./tests/run.sh --live`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

BAN_IP="203.0.113.66"
TEST_JAIL="f2b-e2e-test"
TEST_FILTER="f2b-e2e-test"
JAIL_DROPIN="/etc/fail2ban/jail.d/${TEST_JAIL}.local"
FILTER_DST="/etc/fail2ban/filter.d/${TEST_FILTER}.conf"
SRC_FILTER="$MON_DIR/fail2ban/filter.d/traefik-access.conf"
TMPLOG=""
MAXRETRY=3

echo "== live: Fail2ban detection -> ban -> nftables =="
echo "   target=$BAN_IP (inert TEST-NET)"

cleanup() {
    set +e
    echo "-- cleanup --"
    fail2ban-client set sshd unbanip "$BAN_IP"           >/dev/null 2>&1
    fail2ban-client set "$TEST_JAIL" unbanip "$BAN_IP"   >/dev/null 2>&1
    rm -f "$JAIL_DROPIN" "$FILTER_DST"
    [ -n "$TMPLOG" ] && rm -f "$TMPLOG"
    fail2ban-client reload                               >/dev/null 2>&1
}
trap cleanup EXIT

# poll_for <timeout-s> <cmd...> : return 0 as soon as cmd succeeds, else 1.
poll_for() {
    local timeout="$1"; shift
    local deadline=$(( SECONDS + timeout ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

jail_has_ip() { fail2ban-client status "$1" 2>/dev/null | grep -qF "$BAN_IP"; }
nft_has_ip()  { nft list ruleset 2>/dev/null | grep -qF "$BAN_IP"; }

# Refuse to run if the target is somehow whitelisted (would mask a real failure).
if fail2ban-client get sshd ignoreip 2>/dev/null | grep -qF "$BAN_IP"; then
    fail "$BAN_IP is in the sshd ignoreip list — refusing to run"
    finish; exit $?
fi

# ===========================================================================
# Part 1 — firewall path (manual ban)
# ===========================================================================
echo "-- part 1: manual ban reaches nftables --"
fail2ban-client set sshd unbanip "$BAN_IP" >/dev/null 2>&1 || true
fail2ban-client set sshd banip "$BAN_IP"    >/dev/null 2>&1

if poll_for 10 jail_has_ip sshd; then
    pass "manual ban: $BAN_IP present in sshd jail status"
else
    fail "manual ban: $BAN_IP never appeared in sshd jail status"
fi
if poll_for 10 nft_has_ip; then
    pass "manual ban: nftables DROP present for $BAN_IP"
else
    fail "manual ban: no nftables rule for $BAN_IP (is banaction nftables-*?)"
fi
fail2ban-client set sshd unbanip "$BAN_IP" >/dev/null 2>&1

# ===========================================================================
# Part 2 — organic trigger (real detection through the committed filter)
# ===========================================================================
echo "-- part 2: organic detection bans the attacker --"

if [ ! -f "$SRC_FILTER" ]; then
    fail "committed filter not found at $SRC_FILTER"
    finish; exit $?
fi

TMPLOG="$(mktemp /tmp/f2b-e2e-traefik.XXXXXX.log)"
cp -f "$SRC_FILTER" "$FILTER_DST"

cat > "$JAIL_DROPIN" <<EOF
[${TEST_JAIL}]
enabled   = true
backend   = auto
logpath   = ${TMPLOG}
filter    = ${TEST_FILTER}[mode=4xx]
maxretry  = ${MAXRETRY}
findtime  = 1h
bantime   = 10m
banaction = nftables-multiport
EOF

fail2ban-client reload >/dev/null 2>&1 || true
if ! poll_for 10 fail2ban-client status "$TEST_JAIL"; then
    fail "throwaway jail $TEST_JAIL did not come up after reload"
    finish; exit $?
fi
pass "throwaway jail $TEST_JAIL is active (reuses committed traefik-access filter)"

# Feed maxretry+1 fresh 4xx lines for the attacker IP (StartUTC = now).
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for _ in $(seq 1 $((MAXRETRY + 1))); do
    printf '{"ClientHost":"%s","DownstreamStatus":404,"request_User-Agent":"Mozilla/5.0","StartUTC":"%s"}\n' \
        "$BAN_IP" "$now" >> "$TMPLOG"
done
pass "injected $((MAXRETRY + 1)) malicious 4xx lines for $BAN_IP"

if poll_for 30 jail_has_ip "$TEST_JAIL"; then
    pass "Fail2ban detected and banned $BAN_IP in $TEST_JAIL"
else
    fail "Fail2ban did not ban $BAN_IP within 30s"
fi
if poll_for 15 nft_has_ip; then
    pass "organic ban: nftables DROP present for $BAN_IP"
else
    fail "organic ban: no nftables rule for $BAN_IP"
fi

finish
