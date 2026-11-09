#!/usr/bin/env bash
# Offline test: validate eve.json fixture structure for the CrowdSec suricata parser.
#
# CrowdSec's crowdsecurity/suricata parser reads eve.json and fires on alert events
# with src_ip present. Checks the fixtures match the expected format so the live
# pipeline has reliable test inputs. Uses only jq (or python3 as fallback).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

FIX="$TESTS_DIR/fixtures/eve"

echo "== offline: eve.json fixture structure for CrowdSec suricata parser =="

# Pick a JSON tool
if command -v jq >/dev/null 2>&1; then
    jq_get() { jq -r "$1" "$2" 2>/dev/null; }
elif command -v python3 >/dev/null 2>&1; then
    jq_get() {
        local field="$1" file="$2"
        python3 -I -c "
import json,sys
expr='$field'.lstrip('.')
obj=json.load(open('$file'))
parts=expr.split('.')
v=obj
for p in parts:
    v=v.get(p,'')
print(v)
" 2>/dev/null
    }
else
    skip "jq and python3 both absent — cannot parse JSON fixtures"
    finish; exit $?
fi

# Severity-1 fixture: must be an alert event with src_ip and severity=1
SV1="$FIX/alert_severity1.json"
assert_eq "alert"      "$(jq_get '.event_type' "$SV1")"       "severity-1 fixture is an alert event"
assert_eq "1"          "$(jq_get '.alert.severity' "$SV1")"   "severity-1 fixture has severity=1"
assert_contains "$(jq_get '.src_ip' "$SV1")" "."              "severity-1 fixture has a src_ip"

# Severity-2 fixture: alert event but severity=2 (CrowdSec sev-1-only scenario should NOT fire)
SV2="$FIX/alert_severity2.json"
assert_eq "alert"      "$(jq_get '.event_type' "$SV2")"       "severity-2 fixture is an alert event"
assert_eq "2"          "$(jq_get '.alert.severity' "$SV2")"   "severity-2 fixture has severity=2"

# ICMP smoke-test fixture: alert but not severity-1 (should not fire ban scenario)
ICMP="$FIX/alert_icmp_smoketest.json"
assert_eq "alert"      "$(jq_get '.event_type' "$ICMP")"      "icmp smoke-test fixture is an alert event"
ne_sev="$(jq_get '.alert.severity' "$ICMP")"
if [ "$ne_sev" = "1" ]; then
    fail "icmp smoke-test fixture must NOT have severity=1 (would trigger CrowdSec ban)"
else
    pass "icmp smoke-test fixture has severity=$ne_sev (not 1 — won't trigger ban)"
fi

# DNS event: must be a non-alert event (CrowdSec parser must not match)
DNS="$FIX/event_dns.json"
dns_type="$(jq_get '.event_type' "$DNS")"
if [ "$dns_type" = "alert" ]; then
    fail "dns event fixture must have event_type != alert (got: $dns_type)"
else
    pass "dns event fixture has event_type=$dns_type (not alert — CrowdSec ignores it)"
fi

finish
