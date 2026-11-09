#!/usr/bin/env bash
# install-host-security.sh
#
# Provision the host security layer: Suricata IDS (native apt) + CrowdSec
# (agent + LAPI + nftables bouncer, native apt). Both run as systemd services.
#
# Usage (from the monitoring/ directory):
#   sudo bash scripts/install-host-security.sh
#
# Idempotent: re-run to update configs or add new capture interfaces.
# Required: JOHNCLOUD_ROOT, PUBLIC_IP_ADDRESS, SURICATA_UPLINK, TRAEFIK_LOG_DIR in .env
# Optional: SURICATA_BRIDGE_SUBNET (empty = uplink only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)"; exit 1; }
[ -f "$MON_DIR/.env" ] || {
    echo "ERROR: $MON_DIR/.env not found; copy sample.env and fill in values"
    exit 1
}

set -a; source "$MON_DIR/.env"; set +a
[ -f "$MON_DIR/secrets.env" ] && { set -a; source "$MON_DIR/secrets.env"; set +a; }

for var in JOHNCLOUD_ROOT PUBLIC_IP_ADDRESS SURICATA_UPLINK TRAEFIK_LOG_DIR; do
    [ -n "${!var:-}" ] || { echo "ERROR: $var is not set in .env"; exit 1; }
done
SURICATA_BRIDGE_SUBNET="${SURICATA_BRIDGE_SUBNET:-}"

# ---------------------------------------------------------------------------
# Suricata (native apt)
# ---------------------------------------------------------------------------
install_suricata() {
    echo ""
    echo "=== Suricata ==="

    # Install via OISF PPA for the latest stable release
    if ! command -v suricata >/dev/null 2>&1; then
        echo "[suricata] Adding OISF PPA and installing..."
        add-apt-repository -y ppa:oisf/suricata-stable
        apt-get update -q
        apt-get install -y suricata suricata-update
    else
        echo "[suricata] Already installed ($(suricata --version 2>&1 | head -1))"
    fi

    # Store env vars the configure script needs
    cat > /etc/default/suricata-johncloud <<ENV
SURICATA_UPLINK=${SURICATA_UPLINK}
SURICATA_BRIDGE_SUBNET=${SURICATA_BRIDGE_SUBNET}
PUBLIC_IP_ADDRESS=${PUBLIC_IP_ADDRESS}
ENV

    # Install the base template (configure script renders it at each service start)
    cp "$MON_DIR/suricata/suricata.template.yaml" /etc/suricata/suricata.template.yaml
    cp "$MON_DIR/suricata/local.rules"             /etc/suricata/local.rules
    cp "$MON_DIR/suricata/disable.conf"            /etc/suricata/disable.conf

    # Write the bridge-discovery + config render script
    cat > /usr/local/sbin/suricata-configure <<"CONFIGURE_EOF"
#!/bin/sh
# Rendered by install-host-security.sh. Re-run the installer to update.
# Called via systemd ExecStartPre before each Suricata start.
set -eu

. /etc/default/suricata-johncloud

IFACES="$SURICATA_UPLINK"
if [ -n "${SURICATA_BRIDGE_SUBNET:-}" ]; then
    for br in $(ip -4 -o addr 2>/dev/null \
            | awk -v p="${SURICATA_BRIDGE_SUBNET}." '$4 ~ "^"p {print $2}' \
            | grep -E '^(br-|docker0)' | sort -u); do
        state=$(cat "/sys/class/net/$br/operstate" 2>/dev/null || echo down)
        [ "$state" = "down" ] && continue
        IFACES="$IFACES $br"
    done
fi

# Render base config (PUBLIC_IP_ADDRESS substitution only; leave Suricata's
# own $HOME_NET etc. intact)
PUBLIC_IP_ADDRESS="$PUBLIC_IP_ADDRESS" \
    envsubst '$PUBLIC_IP_ADDRESS' \
    < /etc/suricata/suricata.template.yaml \
    > /etc/suricata/suricata.yaml

# Append per-interface af-packet stanzas with unique cluster-ids.
# Sharing a cluster-id across interfaces causes EINVAL on the second fanout socket.
stanzas=""
cid=99
for i in $IFACES; do
    stanzas="${stanzas}  - interface: ${i}
    cluster-id: ${cid}
"
    cid=$((cid + 1))
done

awk -v stanzas="$stanzas" '
    /^af-packet:/        { print; inblock=1; next }
    inblock && /^[^[:space:]]/ { printf "%s", stanzas; inblock=0 }
    { print }
' /etc/suricata/suricata.yaml > /tmp/suricata.runtime.yaml
mv /tmp/suricata.runtime.yaml /etc/suricata/suricata.yaml

echo "[suricata-configure] Capturing on:$(printf ' %s' $IFACES)"
CONFIGURE_EOF
    chmod +x /usr/local/sbin/suricata-configure

    # Systemd override: run configure before each start
    mkdir -p /etc/systemd/system/suricata.service.d
    cat > /etc/systemd/system/suricata.service.d/johncloud.conf <<"UNIT_EOF"
[Service]
ExecStartPre=/usr/local/sbin/suricata-configure
UNIT_EOF
    systemctl daemon-reload

    # Fetch ET Open ruleset (trimmed by disable.conf)
    RULES_DIR=/var/lib/suricata/rules
    APPLIED="$RULES_DIR/.disable.conf.applied"
    mkdir -p "$RULES_DIR"
    if [ ! -s "$RULES_DIR/suricata.rules" ] || ! cmp -s "$MON_DIR/suricata/disable.conf" "$APPLIED" 2>/dev/null; then
        echo "[suricata] Fetching ET Open ruleset..."
        suricata-update --disable-conf /etc/suricata/disable.conf -o "$RULES_DIR" \
            && cp "$MON_DIR/suricata/disable.conf" "$APPLIED" \
            || echo "[suricata] WARN: rule fetch failed; starting with existing rules"
    else
        echo "[suricata] ET Open rules up to date."
    fi

    # Run configure once now so the yaml is valid before the service starts
    /usr/local/sbin/suricata-configure

    systemctl enable --now suricata
    echo "[suricata] Service enabled and started."

    # NIC offload disablement (prevents coalesced segments that break af-packet)
    install_nic_offloads_unit

    # Log rotation (SIGHUP = lossless reopen; Suricata is PID 1 in its old
    # world but here it's the main process of the systemd unit)
    cat > /etc/logrotate.d/suricata <<'LOGROTATE_EOF'
/var/log/suricata/*.log /var/log/suricata/eve.json {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0640 suricata suricata
    sharedscripts
    postrotate
        systemctl kill -s HUP suricata.service 2>/dev/null || true
    endscript
}
LOGROTATE_EOF
    echo "[suricata] logrotate config installed."

    # Daily ET Open rule refresh
    cat > /etc/cron.daily/suricata-update <<CRON_EOF
#!/bin/sh
suricata-update --disable-conf /etc/suricata/disable.conf \\
    > /var/log/suricata-update.log 2>&1
# Hot-reload rules (no packet drops)
systemctl kill -s USR2 suricata.service 2>/dev/null \\
    || systemctl restart suricata.service
CRON_EOF
    chmod +x /etc/cron.daily/suricata-update
    echo "[suricata] Daily rule refresh cron installed."
}

install_nic_offloads_unit() {
    # Disable GRO/LRO/TSO/GSO on uplink + bridges. Coalesced segments break
    # Suricata af-packet stream reassembly.
    if ! command -v ethtool >/dev/null 2>&1; then
        apt-get install -y ethtool >/dev/null 2>&1 || true
    fi
    cat > /etc/systemd/system/suricata-offloads.service <<'OFFLOADS_EOF'
[Unit]
Description=Disable NIC offloads for Suricata capture
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(ls /sys/class/net | grep -E "^(eth|ens|enp|br-|docker)"); do ethtool -K "$i" gro off lro off tso off gso off 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
OFFLOADS_EOF
    systemctl daemon-reload
    systemctl enable --now suricata-offloads.service
    echo "[suricata] NIC offload disablement unit installed."
}

# ---------------------------------------------------------------------------
# CrowdSec (native apt)
# ---------------------------------------------------------------------------
install_crowdsec() {
    echo ""
    echo "=== CrowdSec ==="

    if ! command -v cscli >/dev/null 2>&1; then
        echo "[crowdsec] Adding APT repo and installing..."
        curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
        apt-get install -y crowdsec crowdsec-firewall-bouncer-nftables
    else
        echo "[crowdsec] Already installed ($(cscli version 2>/dev/null | head -1))"
    fi

    # Acquisitions: log sources CrowdSec reads
    mkdir -p /etc/crowdsec/acquis.d
    TRAEFIK_LOG_DIR="${TRAEFIK_LOG_DIR}" \
        envsubst '$TRAEFIK_LOG_DIR' \
        < "$MON_DIR/crowdsec/acquisitions.yaml" \
        > /etc/crowdsec/acquis.d/johncloud.yaml
    echo "[crowdsec] Acquisitions config written."

    # Local whitelist (never ban our own IPs)
    mkdir -p /etc/crowdsec/parsers/s02-enrich
    PUBLIC_IP_ADDRESS="${PUBLIC_IP_ADDRESS}" \
        envsubst '$PUBLIC_IP_ADDRESS' \
        < "$MON_DIR/crowdsec/whitelist.yaml" \
        > /etc/crowdsec/parsers/s02-enrich/99-local-whitelist.yaml
    echo "[crowdsec] Local whitelist written."

    # Install hub collections (parsers + scenarios for each log source)
    echo "[crowdsec] Installing hub collections..."
    cscli collections install \
        crowdsecurity/suricata \
        crowdsecurity/traefik \
        crowdsecurity/sshd 2>/dev/null || true

    # Ensure crowdsec is running before we register the bouncer
    systemctl enable --now crowdsec
    # Give it a moment to initialize the LAPI
    sleep 3

    # Register the nftables bouncer (idempotent: delete if exists, then add)
    echo "[crowdsec] Registering firewall bouncer..."
    cscli bouncers delete firewall-bouncer 2>/dev/null || true
    BOUNCER_KEY="$(cscli bouncers add firewall-bouncer -o raw)"

    # Write bouncer config with the generated API key
    cat > /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml <<BOUNCER_EOF
mode: nftables
pid_dir: /var/run/
update_frequency: 10s
daemonize: true
log_mode: file
log_dir: /var/log/crowdsec/
log_level: info
api_url: http://localhost:8080/
api_key: ${BOUNCER_KEY}
disable_ipv6: false
deny_action: DROP
deny_log: false
supported_decisions_types:
  - ban
BOUNCER_EOF
    mkdir -p /var/log/crowdsec
    echo "[crowdsec] Bouncer config written."

    systemctl enable --now crowdsec-firewall-bouncer
    echo "[crowdsec] Services enabled."
}

# ---------------------------------------------------------------------------
# Fail2ban cleanup
# ---------------------------------------------------------------------------
remove_fail2ban() {
    echo ""
    echo "=== Fail2ban ==="
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "[fail2ban] Stopping and disabling..."
        systemctl stop fail2ban || true
        systemctl disable fail2ban || true
    fi
    # Check for jails beyond suricata before warning
    if command -v fail2ban-client >/dev/null 2>&1; then
        OTHER_JAILS=$(fail2ban-client status 2>/dev/null \
            | grep 'Jail list' | sed 's/.*Jail list://;s/suricata//;s/,//g;s/ //g' || true)
        if [ -n "$OTHER_JAILS" ]; then
            echo "[fail2ban] WARN: other jails detected ($OTHER_JAILS)." \
                 "Remove fail2ban manually if they are not needed."
        fi
    fi
    echo "[fail2ban] Done (service stopped/disabled; apt package left in place)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_suricata
install_crowdsec
remove_fail2ban

echo ""
echo "=== Host security layer installed ==="
echo ""
echo "Suricata:  systemctl status suricata"
echo "           tail -f /var/log/suricata/eve.json | jq '.alert | {src,sev:.severity,sig:.signature}'"
echo "CrowdSec:  cscli alerts list"
echo "           cscli decisions list"
echo "Bouncer:   systemctl status crowdsec-firewall-bouncer"
echo "           nft list ruleset | grep CROWDSEC"
echo ""
echo "Manual ban:   cscli decisions add --ip 1.2.3.4 --duration 24h --reason '...'"
echo "Manual unban: cscli decisions delete --ip 1.2.3.4"
echo ""
echo "Re-run this script after:"
echo "  - Editing suricata/suricata.template.yaml or suricata/disable.conf"
echo "  - Adding a new Docker network (new bridge to capture)"
echo "  - Changing TRAEFIK_LOG_DIR or PUBLIC_IP_ADDRESS in .env"
