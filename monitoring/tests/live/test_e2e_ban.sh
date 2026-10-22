#!/usr/bin/env bash
# Live end-to-end test: real traffic -> Suricata detection -> Fail2ban ban.
#
# Sends ONE spoofed-source TCP SYN (src 203.0.113.66, RFC 5737 TEST-NET-3) across
# the monitored uplink. A temporary priority:1 rule (sid 1000099) makes Suricata
# emit a severity-1 alert, which the host Fail2ban daemon bans via the suricata-raw
# action (iptables raw/PREROUTING DROP). Asserts detection + ban, then always
# cleans up (unban, remove temp rule, reload the sensor).
#
# Invasive: needs root, a running stack, and mutates the host firewall. Run via
# `sudo ./tests/run.sh --live`. The ban target is always the inert TEST-NET IP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

BAN_IP="203.0.113.66"
TEST_SID="1000099"
E2E_RULE="$SCRIPT_DIR/fail2ban-e2e.rules"
JAIL="suricata"

# --- config from monitoring/.env ---------------------------------------------
JOHNCLOUD_ROOT="/var/hippias"
SURICATA_UPLINK="eth0"
if [ -f "$MON_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$MON_DIR/.env"; set +a
fi
EVE="$JOHNCLOUD_ROOT/suricata/logs/eve.json"
RUNTIME_RULES="$JOHNCLOUD_ROOT/suricata/local.rules"
RULES_BACKUP=""

echo "== live: suricata detection -> fail2ban ban =="
echo "   root=$JOHNCLOUD_ROOT uplink=$SURICATA_UPLINK target=$BAN_IP"

# iptables tool for the raw-table assertion/cleanup (v4 is enough for TEST-NET).
IPT="iptables"
command -v ip46tables >/dev/null 2>&1 && IPT="ip46tables"

cleanup() {
  set +e
  echo "-- cleanup --"
  fail2ban-client set "$JAIL" unbanip "$BAN_IP" >/dev/null 2>&1
  # Belt-and-braces: drop any leftover raw DROP for the test IP.
  while $IPT -w -t raw -S PREROUTING 2>/dev/null | grep -q -- "-s $BAN_IP/32 -j DROP"; do
    $IPT -w -t raw -D PREROUTING -s "$BAN_IP" -j DROP >/dev/null 2>&1 || break
  done
  if [ -n "$RULES_BACKUP" ] && [ -f "$RULES_BACKUP" ]; then
    cp -f "$RULES_BACKUP" "$RUNTIME_RULES" && rm -f "$RULES_BACKUP"
    docker kill --signal=USR2 suricata >/dev/null 2>&1
  fi
}
trap cleanup EXIT

# poll_for <timeout-s> <cmd...> : returns 0 as soon as cmd succeeds, else 1.
poll_for() {
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# --- pre-flight: never run if the target is somehow allow-listed --------------
if fail2ban-client get "$JAIL" ignoreip 2>/dev/null | grep -q "203.0.113"; then
  fail "203.0.113.0/24 is in the jail ignoreip — refusing to run (would never ban)"
  finish; exit $?
fi

# Start from a clean slate for the target IP.
fail2ban-client set "$JAIL" unbanip "$BAN_IP" >/dev/null 2>&1 || true

# --- arm detection: install temp rule into the running sensor -----------------
if [ ! -f "$RUNTIME_RULES" ]; then
  fail "runtime rules not found at $RUNTIME_RULES (is the suricata stack deployed?)"
  finish; exit $?
fi
RULES_BACKUP="$(mktemp)"
cp -f "$RUNTIME_RULES" "$RULES_BACKUP"
if ! grep -q "sid:$TEST_SID" "$RUNTIME_RULES"; then
  { echo ""; echo "# --- temporary e2e test rule (tests/live) ---"; cat "$E2E_RULE"; } >> "$RUNTIME_RULES"
fi
docker kill --signal=USR2 suricata >/dev/null 2>&1 || true
sleep 3  # let the rule reload settle

# Remember where eve.json currently ends so we only inspect new alerts.
eve_start=0
[ -f "$EVE" ] && eve_start="$(wc -l < "$EVE" 2>/dev/null || echo 0)"

# --- generate real traffic across the monitored uplink ------------------------
DST="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
[ -n "$DST" ] || DST="203.0.113.1"
sent=0
if command -v hping3 >/dev/null 2>&1; then
  hping3 -a "$BAN_IP" -S -p 80 -c 1 -I "$SURICATA_UPLINK" "$DST" >/dev/null 2>&1 && sent=1
fi
if [ "$sent" -eq 0 ]; then
  python3 -I "$SCRIPT_DIR/inject_packet.py" "$SURICATA_UPLINK" "$DST" >/dev/null 2>&1 && sent=1
fi
if [ "$sent" -eq 0 ]; then
  fail "could not send test packet (need hping3 or python3+scapy, as root)"
  finish; exit $?
fi
pass "sent spoofed SYN src=$BAN_IP dst=$DST via $SURICATA_UPLINK"

# --- assert: Suricata wrote a severity-1 alert for the target -----------------
seen_alert() {
  [ -f "$EVE" ] || return 1
  tail -n +"$((eve_start + 1))" "$EVE" \
    | grep -E '"event_type":"alert"' \
    | grep -F "\"src_ip\":\"$BAN_IP\"" \
    | grep -q '"severity":1'
}
if poll_for 20 seen_alert; then
  pass "Suricata detected the packet (severity-1 alert for $BAN_IP in eve.json)"
else
  fail "no severity-1 alert for $BAN_IP appeared in eve.json within 20s"
fi

# --- assert: Fail2ban banned the target --------------------------------------
banned_in_jail() { fail2ban-client status "$JAIL" | grep -q "$BAN_IP"; }
if poll_for 20 banned_in_jail; then
  pass "Fail2ban banned $BAN_IP (listed in jail status)"
else
  fail "Fail2ban did not ban $BAN_IP within 20s"
fi

# --- assert: the suricata-raw action installed the raw/PREROUTING DROP --------
if $IPT -w -t raw -S PREROUTING 2>/dev/null | grep -q -- "-s $BAN_IP/32 -j DROP"; then
  pass "raw/PREROUTING DROP present for $BAN_IP (suricata-raw action ran)"
else
  fail "no raw/PREROUTING DROP found for $BAN_IP"
fi

finish
