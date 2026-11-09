#!/usr/bin/env bash
# Live end-to-end test: real traffic -> Suricata detection -> CrowdSec ban.
#
# Sends ONE spoofed-source TCP SYN (src 203.0.113.66, RFC 5737 TEST-NET-3) across
# the monitored uplink. A temporary priority:1 rule (sid 1000099) makes Suricata
# emit a severity-1 alert, which CrowdSec's suricata parser picks up and the
# crowdsec-firewall-bouncer enforces via nftables. Asserts detection + ban, then
# always cleans up (remove decision, restore rule, reload sensor).
#
# Invasive: needs root, running suricata.service + crowdsec.service +
# crowdsec-firewall-bouncer.service, and mutates the host firewall.
# Run via `sudo ./tests/run.sh --live`. The ban target is always the inert TEST-NET IP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

BAN_IP="203.0.113.66"
TEST_SID="1000099"
E2E_RULE="$SCRIPT_DIR/suricata-e2e.rules"

# --- config from monitoring/.env -------------------------------------------
SURICATA_UPLINK="eth0"
if [ -f "$MON_DIR/.env" ]; then
  set -a; . "$MON_DIR/.env"; set +a
fi
EVE="/var/log/suricata/eve.json"
RUNTIME_RULES="/etc/suricata/local.rules"
RULES_BACKUP=""

echo "== live: suricata detection -> crowdsec ban =="
echo "   uplink=$SURICATA_UPLINK target=$BAN_IP"

cleanup() {
  set +e
  echo "-- cleanup --"
  cscli decisions delete --ip "$BAN_IP" >/dev/null 2>&1 || true
  if [ -n "$RULES_BACKUP" ] && [ -f "$RULES_BACKUP" ]; then
    cp -f "$RULES_BACKUP" "$RUNTIME_RULES" && rm -f "$RULES_BACKUP"
    systemctl kill -s USR2 suricata.service >/dev/null 2>&1 || true
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

# --- pre-flight: TEST-NET must not already be whitelisted in CrowdSec --------
if cscli decisions list --ip "$BAN_IP" 2>/dev/null | grep -q "whitelist"; then
  fail "203.0.113.66 is whitelisted in CrowdSec — refusing to run"
  finish; exit $?
fi

# Start from a clean slate for the target IP.
cscli decisions delete --ip "$BAN_IP" >/dev/null 2>&1 || true

# --- arm detection: install temp rule into the running sensor ----------------
if [ ! -f "$RUNTIME_RULES" ]; then
  fail "runtime rules not found at $RUNTIME_RULES (is suricata.service deployed?)"
  finish; exit $?
fi
RULES_BACKUP="$(mktemp)"
cp -f "$RUNTIME_RULES" "$RULES_BACKUP"
if ! grep -q "sid:$TEST_SID" "$RUNTIME_RULES"; then
  { echo ""; echo "# --- temporary e2e test rule (tests/live) ---"; cat "$E2E_RULE"; } >> "$RUNTIME_RULES"
fi
systemctl kill -s USR2 suricata.service >/dev/null 2>&1 || true
sleep 3  # let the rule reload settle

# Remember where eve.json currently ends so we only inspect new alerts.
eve_start=0
[ -f "$EVE" ] && eve_start="$(wc -l < "$EVE" 2>/dev/null || echo 0)"

# --- generate real traffic across the monitored uplink -----------------------
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

# --- assert: Suricata wrote a severity-1 alert for the target ----------------
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

# --- assert: CrowdSec created a ban decision ---------------------------------
crowdsec_banned() { cscli decisions list --ip "$BAN_IP" 2>/dev/null | grep -q "ban"; }
if poll_for 30 crowdsec_banned; then
  pass "CrowdSec banned $BAN_IP (decision present in cscli decisions list)"
else
  fail "CrowdSec did not create a ban decision for $BAN_IP within 30s"
fi

# --- assert: nftables DROP in the CROWDSEC chain -----------------------------
nft_banned() { nft list ruleset 2>/dev/null | grep -qF "$BAN_IP"; }
if poll_for 15 nft_banned; then
  pass "nftables DROP present for $BAN_IP (crowdsec-firewall-bouncer applied)"
else
  fail "no nftables rule found for $BAN_IP (is crowdsec-firewall-bouncer running?)"
fi

finish
