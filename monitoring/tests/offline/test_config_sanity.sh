#!/usr/bin/env bash
# Offline test: validate CrowdSec and Suricata config templates in the repo.
# Checks structure and required fields without touching a running system.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

echo "== offline: config sanity =="

# --- Suricata template -------------------------------------------------------
TEMPLATE="$MON_DIR/suricata/suricata.template.yaml"
assert_contains "$(cat "$TEMPLATE")" 'PUBLIC_IP_ADDRESS'   "suricata template has PUBLIC_IP_ADDRESS placeholder"
assert_contains "$(cat "$TEMPLATE")" 'af-packet'           "suricata template has af-packet capture block"
assert_contains "$(cat "$TEMPLATE")" 'eve-log'             "suricata template enables eve-log output"
assert_contains "$(cat "$TEMPLATE")" 'cluster-id'          "suricata template has default cluster-id stanza"

# suricata.template.yaml must NOT have hard-coded interface names (the configure
# script injects them at runtime)
if grep -qE '^  - interface: (eth|ens|enp|br-)' "$TEMPLATE"; then
    fail "suricata template must not contain hard-coded interface names (configure script injects them)"
else
    pass "suricata template has no hard-coded capture interfaces"
fi

# --- CrowdSec acquisitions template ------------------------------------------
ACQUIS="$MON_DIR/crowdsec/acquisitions.yaml"
assert_contains "$(cat "$ACQUIS")" 'type: suricata'  "acquisitions template has suricata source"
assert_contains "$(cat "$ACQUIS")" 'type: traefik'   "acquisitions template has traefik source"
assert_contains "$(cat "$ACQUIS")" 'type: syslog'    "acquisitions template has sshd/syslog source"
assert_contains "$(cat "$ACQUIS")" 'TRAEFIK_LOG_DIR' "acquisitions template has TRAEFIK_LOG_DIR placeholder"
assert_contains "$(cat "$ACQUIS")" 'eve.json'        "acquisitions template points at Suricata eve.json"

# --- CrowdSec whitelist template ---------------------------------------------
WHITELIST="$MON_DIR/crowdsec/whitelist.yaml"
assert_contains "$(cat "$WHITELIST")" 'PUBLIC_IP_ADDRESS'  "whitelist template has PUBLIC_IP_ADDRESS placeholder"
assert_contains "$(cat "$WHITELIST")" '10.0.0.0/8'         "whitelist template covers RFC1918 10/8"
assert_contains "$(cat "$WHITELIST")" '172.16.0.0/12'      "whitelist template covers RFC1918 172.16/12"
assert_contains "$(cat "$WHITELIST")" '192.168.0.0/16'     "whitelist template covers RFC1918 192.168/16"

# --- Install script ----------------------------------------------------------
INSTALL="$MON_DIR/scripts/install-host-security.sh"
assert_contains "$(cat "$INSTALL")" 'suricata-configure'              "install script writes suricata-configure"
assert_contains "$(cat "$INSTALL")" 'cscli collections install'       "install script installs CrowdSec collections"
assert_contains "$(cat "$INSTALL")" 'crowdsecurity/suricata'          "install script installs suricata collection"
assert_contains "$(cat "$INSTALL")" 'crowdsec-firewall-bouncer'       "install script configures the firewall bouncer"
assert_contains "$(cat "$INSTALL")" 'crowdsec-firewall-bouncer.yaml'  "install script writes bouncer config"
assert_contains "$(cat "$INSTALL")" 'suricata-update'                 "install script fetches ET Open rules"

# --- cscli sanity (only if CrowdSec is installed on this machine) -----------
if command -v cscli >/dev/null 2>&1; then
    if cscli hub update >/dev/null 2>&1 || cscli collections list >/dev/null 2>&1; then
        pass "cscli: CrowdSec installed and responding"
    else
        skip "cscli: installed but hub unreachable (CI/offline environment)"
    fi
else
    skip "cscli absent — skipping CrowdSec runtime checks"
fi

finish
