#!/usr/bin/env bash
# install-host-security.sh
#
# Provision the host security layer: Fail2ban (native apt, systemd service) that
# reads the systemd journal (host + all containers), the Traefik access log, and
# /var/log/auth.log, and bans offenders in the host firewall (nftables by default).
#
# Usage (from the monitoring/ directory):
#   sudo bash scripts/install-host-security.sh
#
# Idempotent: re-run to update jails/filters after editing the templates or .env.
# Required: JOHNCLOUD_ROOT, PUBLIC_IP_ADDRESS, TRAEFIK_LOG_DIR in .env
# Optional: F2B_BANTIME, F2B_FINDTIME, F2B_MAXRETRY, F2B_IGNOREIP

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

for var in JOHNCLOUD_ROOT PUBLIC_IP_ADDRESS TRAEFIK_LOG_DIR; do
    [ -n "${!var:-}" ] || { echo "ERROR: $var is not set in .env"; exit 1; }
done

# Fail2ban tunables (defaults if unset in .env)
export F2B_BANTIME="${F2B_BANTIME:-1h}"
export F2B_FINDTIME="${F2B_FINDTIME:-10m}"
export F2B_MAXRETRY="${F2B_MAXRETRY:-5}"
export F2B_IGNOREIP="${F2B_IGNOREIP:-}"
export PUBLIC_IP_ADDRESS TRAEFIK_LOG_DIR JOHNCLOUD_ROOT

# ---------------------------------------------------------------------------
# Fail2ban (native apt)
# ---------------------------------------------------------------------------
install_fail2ban() {
    echo ""
    echo "=== Fail2ban ==="

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "[fail2ban] Installing fail2ban + nftables..."
        apt-get update -q
        apt-get install -y fail2ban nftables gettext-base
    else
        echo "[fail2ban] Already installed ($(fail2ban-client version 2>/dev/null))"
        command -v envsubst >/dev/null 2>&1 || apt-get install -y gettext-base
        command -v nft >/dev/null 2>&1       || apt-get install -y nftables
    fi

    # Render the jail config (substitute only our own ${...} vars; leave
    # Fail2ban's %(...)s interpolation untouched).
    echo "[fail2ban] Rendering /etc/fail2ban/jail.local ..."
    envsubst '$F2B_BANTIME $F2B_FINDTIME $F2B_MAXRETRY $PUBLIC_IP_ADDRESS $F2B_IGNOREIP $TRAEFIK_LOG_DIR' \
        < "$MON_DIR/fail2ban/jail.template.local" \
        > /etc/fail2ban/jail.local

    # Install the custom filters (stock sshd/recidive filters ship with the package)
    echo "[fail2ban] Installing custom filters ..."
    install -d /etc/fail2ban/filter.d
    cp "$MON_DIR"/fail2ban/filter.d/*.conf /etc/fail2ban/filter.d/

    # Render the log-only `jsonlog` action (feeds security_events via Vector).
    echo "[fail2ban] Rendering /etc/fail2ban/action.d/jsonlog.conf ..."
    install -d /etc/fail2ban/action.d
    envsubst '$JOHNCLOUD_ROOT' \
        < "$MON_DIR/fail2ban/action.d/jsonlog.template.conf" \
        > /etc/fail2ban/action.d/jsonlog.conf

    # Event file lives under $JOHNCLOUD_ROOT: written by this root service, read
    # (read-only) by the rootless Vector container. World-readable (0644) so the
    # container can read it regardless of the userns ownership remap.
    echo "[fail2ban] Ensuring security event log exists ..."
    install -d -m 0755 "$JOHNCLOUD_ROOT/security"
    touch "$JOHNCLOUD_ROOT/security/fail2ban-events.jsonl"
    chmod 0644 "$JOHNCLOUD_ROOT/security/fail2ban-events.jsonl"

    systemctl enable --now fail2ban
    # Reload picks up config changes on re-runs without dropping existing bans
    fail2ban-client reload >/dev/null 2>&1 || systemctl restart fail2ban
    echo "[fail2ban] Service enabled and configuration loaded."
}

# ---------------------------------------------------------------------------
# Legacy host IDS cleanup (Suricata / CrowdSec / Snort)
# ---------------------------------------------------------------------------
remove_legacy_ids() {
    echo ""
    echo "=== Legacy IDS cleanup (Suricata / CrowdSec / Snort) ==="

    for svc in suricata suricata-offloads crowdsec crowdsec-firewall-bouncer snort; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            echo "[cleanup] Disabling ${svc}.service ..."
            systemctl disable --now "${svc}.service" 2>/dev/null || true
        fi
    done

    echo "[cleanup] Purging packages (if present) ..."
    apt-get purge -y suricata suricata-update crowdsec \
        crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables \
        snort 2>/dev/null || true

    echo "[cleanup] Removing leftover config / units / cron ..."
    rm -rf /etc/suricata /etc/crowdsec \
           /etc/cron.daily/suricata-update \
           /etc/logrotate.d/suricata \
           /etc/default/suricata-johncloud \
           /usr/local/sbin/suricata-configure \
           /etc/systemd/system/suricata.service.d \
           /etc/systemd/system/suricata-offloads.service

    # Remove a stray nftables chain the CrowdSec bouncer may have left behind
    if command -v nft >/dev/null 2>&1; then
        nft list chain ip filter CROWDSEC >/dev/null 2>&1 && \
            nft delete chain ip filter CROWDSEC 2>/dev/null || true
        nft list table ip crowdsec >/dev/null 2>&1 && \
            nft delete table ip crowdsec 2>/dev/null || true
        nft list table ip6 crowdsec >/dev/null 2>&1 && \
            nft delete table ip6 crowdsec 2>/dev/null || true
    fi

    systemctl daemon-reload
    echo "[cleanup] Done."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_fail2ban
remove_legacy_ids

echo ""
echo "=== Host security layer installed ==="
echo ""
echo "Fail2ban:  systemctl status fail2ban"
echo "           fail2ban-client status"
echo "           fail2ban-client status sshd"
echo ""
echo "Manual ban:   fail2ban-client set <jail> banip 1.2.3.4"
echo "Manual unban: fail2ban-client set <jail> unbanip 1.2.3.4"
echo ""
echo "Re-run this script after editing:"
echo "  - fail2ban/jail.template.local"
echo "  - fail2ban/filter.d/*.conf"
echo "  - PUBLIC_IP_ADDRESS, TRAEFIK_LOG_DIR, or any F2B_* var in .env"
