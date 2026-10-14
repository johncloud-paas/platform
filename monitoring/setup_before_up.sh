# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

SURICATA_DATA="$JOHNCLOUD_ROOT/suricata"

(
    envsubst '$PUBLIC_IP_ADDRESS $JOHNCLOUD_ROOT' < fail2ban/jail.d/suricata.template.conf > fail2ban/jail.d/suricata.conf &&    
    envsubst '$PUBLIC_IP_ADDRESS' < suricata/suricata.template.yaml > suricata/suricata.yaml &&        
    mkdir -p $JOHNCLOUD_ROOT/victoriametrics/data $JOHNCLOUD_ROOT/victorialogs/data $JOHNCLOUD_ROOT/victoriatraces/data $JOHNCLOUD_ROOT/fluent-bit $JOHNCLOUD_ROOT/fail2ban-ui &&
    cp ./victoriametrics/* $JOHNCLOUD_ROOT/victoriametrics &&
    cp ./fluent-bit/* $JOHNCLOUD_ROOT/fluent-bit &&
    mkdir -p "$SURICATA_DATA/rules" "$SURICATA_DATA/logs" &&
    cp ./suricata/entrypoint.sh "$SURICATA_DATA/" &&
    cp ./suricata/suricata.yaml ./suricata/local.rules "$SURICATA_DATA/" &&
    chmod +x "$SURICATA_DATA/entrypoint.sh"
)

# Install Fail2ban glue (host-side: filter + raw/PREROUTING action + jail that
# tails eve.json). Needs root; skipped with a warning if not available.
if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -w /etc/fail2ban/jail.d ] || [ "$(id -u)" = "0" ]; then
        sudo cp ./fail2ban/filter.d/suricata.conf   /etc/fail2ban/filter.d/ &&
        sudo cp ./fail2ban/action.d/suricata-raw.conf /etc/fail2ban/action.d/ &&
        sudo cp ./fail2ban/jail.d/suricata.conf     /etc/fail2ban/jail.d/ &&
        sudo fail2ban-client reload &&
        echo "[fail2ban] suricata jail installed & reloaded"
    else
        echo "[fail2ban] WARN: need root to install jail; run setup as root or copy ./fail2ban/* into /etc/fail2ban/ manually"
    fi
else
    echo "[fail2ban] WARN: fail2ban-client not found; skipping jail install"
fi

# fail2ban-ui (rootless container) drives the host's ROOTFUL Fail2ban over SSH — a
# rootless container can't reach the root-owned control socket, so instead it logs in
# as a dedicated host user with narrow sudo. Provision that login here: sudoers (only
# fail2ban-client + restart) + an ACL so the UI can edit /etc/fail2ban. The UI's SSH
# *public* key (generated in its /config/.ssh on first start, shown in the UI) is
# authorized via FAIL2BAN_UI_SSH_PUBKEY. Gated on FAIL2BAN_UI_SSH_USER being set.
if [ -n "${FAIL2BAN_UI_SSH_USER:-}" ] && command -v sudo >/dev/null 2>&1; then
    id -u "$FAIL2BAN_UI_SSH_USER" >/dev/null 2>&1 ||
        sudo useradd --system --create-home --shell /bin/bash "$FAIL2BAN_UI_SSH_USER"

    printf '%s ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client *, /usr/bin/systemctl restart fail2ban\n' \
        "$FAIL2BAN_UI_SSH_USER" | sudo tee /etc/sudoers.d/fail2ban-ui >/dev/null
    sudo chmod 0440 /etc/sudoers.d/fail2ban-ui

    if command -v setfacl >/dev/null 2>&1; then
        sudo setfacl -R    -m "u:$FAIL2BAN_UI_SSH_USER:rwX" /etc/fail2ban &&
        sudo setfacl -R -d -m "u:$FAIL2BAN_UI_SSH_USER:rwX" /etc/fail2ban
    else
        echo "[fail2ban-ui] WARN: setfacl not found; UI can ban/unban but not edit /etc/fail2ban"
    fi

    if [ -n "${FAIL2BAN_UI_SSH_PUBKEY:-}" ]; then
        ssh_home="$(getent passwd "$FAIL2BAN_UI_SSH_USER" | cut -d: -f6)"
        sudo install -d -m 700 -o "$FAIL2BAN_UI_SSH_USER" -g "$FAIL2BAN_UI_SSH_USER" "$ssh_home/.ssh"
        printf '%s\n' "$FAIL2BAN_UI_SSH_PUBKEY" | sudo tee "$ssh_home/.ssh/authorized_keys" >/dev/null
        sudo chown "$FAIL2BAN_UI_SSH_USER:$FAIL2BAN_UI_SSH_USER" "$ssh_home/.ssh/authorized_keys"
        sudo chmod 600 "$ssh_home/.ssh/authorized_keys"
        echo "[fail2ban-ui] SSH login '$FAIL2BAN_UI_SSH_USER' ready (sudo + ACL + authorized key)"
    else
        echo "[fail2ban-ui] SSH login '$FAIL2BAN_UI_SSH_USER' ready (sudo + ACL); set FAIL2BAN_UI_SSH_PUBKEY to authorize the UI key, then re-run"
    fi
fi

# First-time rule fetch (ET Open ~50k rules). Refreshed daily by cron afterwards;
# see Monitoring.md "Suricata Setup" §10. suricata-update only downloads rules, so
# the rootless daemon is fine here — no raw-socket access needed.
if [ ! -s "$SURICATA_DATA/rules/suricata.rules" ]; then
    echo "[suricata] fetching ET Open ruleset (first run)..."
    docker run --rm -v "$SURICATA_DATA/rules:/var/lib/suricata/rules" \
        jasonish/suricata:latest suricata-update --no-test -o /var/lib/suricata/rules \
        || echo "[suricata] WARN: rule fetch failed; starting with local.rules only"
fi

# Suricata runs ROOTFUL (own compose) because sniffing the physical uplink needs
# CAP_NET_RAW in the init user namespace, which rootless Docker can't grant. See
# suricata/docker-compose.yml for the full explanation. Everything else in this
# stack stays rootless; only this one container uses the system daemon.
if systemctl list-unit-files docker.service >/dev/null 2>&1; then
    sudo systemctl enable --now docker &&
    sudo docker compose --env-file .env -f suricata/docker-compose.yml \
        up -d --force-recreate --remove-orphans ||
        echo "[suricata] WARN: rootful sensor failed to start; check 'sudo docker logs suricata'"
else
    echo "[suricata] WARN: no system docker.service; cannot start the rootful sensor"
fi
