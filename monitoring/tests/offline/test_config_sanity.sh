#!/usr/bin/env bash
# Offline test: validate the committed Fail2ban config (jail template, filters),
# the host-security installer, and sample.env. Structure-only — touches no running
# system. Reads the committed files, never a rendered /etc/fail2ban copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$TESTS_DIR/lib/assert.sh"

echo "== offline: Fail2ban config sanity =="

# --- jail template ----------------------------------------------------------
JAIL="$MON_DIR/fail2ban/jail.template.local"
jail="$(cat "$JAIL")"

for j in sshd traefik-4xx traefik-botsearch docker-apps recidive; do
    assert_contains "$jail" "[$j]" "jail template defines [$j]"
done

# The enforcement jails must be explicitly enabled.
assert_match "$JAIL" '^\[sshd\]'          "sshd jail present"
assert_contains "$jail" "enabled = true"  "jail template enables jails"

# Bans go into nftables (not iptables / CrowdSec bouncer).
assert_contains "$jail" "banaction" "jail template sets a banaction"
assert_match "$JAIL" 'banaction[[:space:]]*=[[:space:]]*nftables' \
    "banaction uses nftables"

# ignoreip must cover loopback, RFC1918, and the public IP placeholder.
assert_contains "$jail" "127.0.0.1/8"          "ignoreip covers loopback"
assert_contains "$jail" "10.0.0.0/8"           "ignoreip covers RFC1918 10/8"
assert_contains "$jail" "172.16.0.0/12"        "ignoreip covers RFC1918 172.16/12"
assert_contains "$jail" "192.168.0.0/16"       "ignoreip covers RFC1918 192.168/16"
assert_contains "$jail" '${PUBLIC_IP_ADDRESS}' "ignoreip has PUBLIC_IP_ADDRESS placeholder"

# envsubst placeholders the installer substitutes.
for v in '${F2B_BANTIME}' '${F2B_FINDTIME}' '${F2B_MAXRETRY}' '${TRAEFIK_LOG_DIR}'; do
    assert_contains "$jail" "$v" "jail template has $v placeholder"
done

# --- filters ----------------------------------------------------------------
TRAEFIK_FILTER="$MON_DIR/fail2ban/filter.d/traefik-access.conf"
DOCKER_FILTER="$MON_DIR/fail2ban/filter.d/docker-apps.conf"
assert_contains "$(cat "$TRAEFIK_FILTER")" "<HOST>"    "traefik filter captures <HOST>"
assert_contains "$(cat "$TRAEFIK_FILTER")" "mdre-4xx"  "traefik filter has 4xx mode regex"
assert_contains "$(cat "$TRAEFIK_FILTER")" "mdre-bot"  "traefik filter has bot mode regex"
assert_contains "$(cat "$DOCKER_FILTER")"  "failregex" "docker-apps filter declares failregex"
assert_contains "$(cat "$DOCKER_FILTER")"  "<HOST>"    "docker-apps filter captures <HOST>"

# --- installer --------------------------------------------------------------
INSTALL="$MON_DIR/scripts/install-host-security.sh"
install="$(cat "$INSTALL")"
assert_contains "$install" "fail2ban"                "installer installs fail2ban"
assert_contains "$install" "envsubst"                "installer renders jail.local with envsubst"
assert_contains "$install" "jail.local"              "installer writes /etc/fail2ban/jail.local"
assert_contains "$install" "filter.d"                "installer copies custom filters"
assert_contains "$install" "systemctl enable --now fail2ban" "installer enables the service"
assert_contains "$install" "remove_legacy_ids"       "installer purges legacy Suricata/CrowdSec/Snort"

# --- sample.env -------------------------------------------------------------
ENVSAMPLE="$MON_DIR/sample.env"
envsample="$(cat "$ENVSAMPLE")"
for v in F2B_BANTIME F2B_FINDTIME F2B_MAXRETRY PUBLIC_IP_ADDRESS TRAEFIK_LOG_DIR; do
    assert_contains "$envsample" "$v" "sample.env documents $v"
done

# --- runtime sanity (only if fail2ban is installed here) --------------------
if command -v fail2ban-client >/dev/null 2>&1; then
    pass "fail2ban-client present ($(fail2ban-client version 2>/dev/null | head -n1))"
else
    skip "fail2ban-client absent — skipping runtime checks"
fi

finish
