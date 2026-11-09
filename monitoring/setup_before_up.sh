# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

# ---------------------------------------------------------------------------
# Host security layer pre-flight
# ---------------------------------------------------------------------------
# Suricata and CrowdSec are native systemd services, not containers. They are
# provisioned once by scripts/install-host-security.sh. If neither is active,
# warn and continue — the monitoring stack itself is rootless and doesn't depend
# on them, but the security pipeline won't work until they're installed.
if ! systemctl is-active --quiet suricata 2>/dev/null; then
    echo "[setup] WARN: suricata.service is not running."
    echo "[setup]       Run: sudo bash scripts/install-host-security.sh"
fi
if ! systemctl is-active --quiet crowdsec 2>/dev/null; then
    echo "[setup] WARN: crowdsec.service is not running."
    echo "[setup]       Run: sudo bash scripts/install-host-security.sh"
fi

# ---------------------------------------------------------------------------
# Rootless stack provisioning
# ---------------------------------------------------------------------------
mkdir -p $JOHNCLOUD_ROOT/vector
