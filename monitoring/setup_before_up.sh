# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

# ---------------------------------------------------------------------------
# Host security layer pre-flight
# ---------------------------------------------------------------------------
# Fail2ban is a native systemd service, not a container. It is provisioned once
# by scripts/install-host-security.sh. If it is not active, warn and continue —
# the monitoring stack itself is rootless and doesn't depend on it, but the
# security pipeline won't block anything until Fail2ban is installed.
if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "[setup] WARN: fail2ban.service is not running."
    echo "[setup]       Run: sudo bash scripts/install-host-security.sh"
fi

# ---------------------------------------------------------------------------
# Rootless stack provisioning
# ---------------------------------------------------------------------------
mkdir -p $JOHNCLOUD_ROOT/vector
