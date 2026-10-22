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
    cp ./suricata/suricata.yaml ./suricata/local.rules ./suricata/disable.conf "$SURICATA_DATA/" &&
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

# fail2ban-ui (rootless container) drives the host's ROOTFUL Fail2ban over the SSH
# connector — a rootless container can't reach the root-owned control socket, so it
# logs in as a dedicated service account instead. Provision that login end-to-end:
# account, a generated key the UI authenticates with, narrow sudo, an /etc/fail2ban
# ACL, and the host prerequisites for the reverse-tunnel callback path. The only
# manual step left is adding the server once in the UI (see the echo at the end).
SA="${FAIL2BAN_UI_SSH_USER:-sa_fail2ban}"
SSH_DIR="$JOHNCLOUD_ROOT/fail2ban-ui/.ssh"          # == /config/.ssh inside the container
KEY="$SSH_DIR/${SA}_ed25519"
if command -v sudo >/dev/null 2>&1; then
    # 1) Service account (system user, shell for SSH, key-only — no password).
    id -u "$SA" >/dev/null 2>&1 ||
        sudo useradd --system --create-home --shell /bin/bash "$SA"

    # 2) Generate the key the UI logs in with (once; lives in the /config/.ssh bind mount).
    mkdir -p "$SSH_DIR"
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -C "fail2ban-ui@$HOST" -f "$KEY"
    chmod 700 "$SSH_DIR"; chmod 600 "$KEY"; chmod 644 "$KEY.pub"

    # 3) Authorize that public key for the service account.
    sa_home="$(getent passwd "$SA" | cut -d: -f6)"
    sudo install -d -m 700 -o "$SA" -g "$SA" "$sa_home/.ssh"
    sudo tee "$sa_home/.ssh/authorized_keys" >/dev/null < "$KEY.pub"
    sudo chown "$SA:$SA" "$sa_home/.ssh/authorized_keys"
    sudo chmod 600 "$sa_home/.ssh/authorized_keys"

    # 4) Minimal sudo: exactly what the SSH connector runs (validated before it sticks).
    printf '%s ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client *, /usr/bin/systemctl restart fail2ban\n' \
        "$SA" | sudo tee /etc/sudoers.d/fail2ban-ui >/dev/null
    sudo chmod 0440 /etc/sudoers.d/fail2ban-ui
    sudo visudo -cf /etc/sudoers.d/fail2ban-ui >/dev/null ||
        echo "[fail2ban-ui] WARN: sudoers validation failed; review /etc/sudoers.d/fail2ban-ui"

    # 5) Let the UI read/write jail & filter config over SSH. The connector also writes a
    #    recovery dir (/etc/fail2ban/.fail2ban-ui-operations) as this account, so it needs write
    #    on the /etc/fail2ban directory itself — grant it by ACL. Install `acl` if setfacl is
    #    missing: without it the grant silently fails and "Apply shared configuration" errors with
    #    PermissionError on /etc/fail2ban/.fail2ban-ui-operations.
    command -v setfacl >/dev/null 2>&1 || sudo apt-get install -y acl >/dev/null 2>&1 || true
    if command -v setfacl >/dev/null 2>&1; then
        sudo setfacl -R    -m "u:$SA:rwX" /etc/fail2ban &&
        sudo setfacl -R -d -m "u:$SA:rwX" /etc/fail2ban
    else
        echo "[fail2ban-ui] WARN: setfacl unavailable (install the 'acl' package); UI can ban/unban but not save config"
    fi

    # 6) Reverse-tunnel prerequisites: the UI opens `ssh -R <tunnel>:localhost:<ui>` and the
    #    host posts callbacks to localhost:<tunnel>, so sshd must allow TCP forwarding and the
    #    connector's callback action needs jq+curl on the host.
    sshd -T 2>/dev/null | grep -qi '^allowtcpforwarding yes' ||
        echo "[fail2ban-ui] NOTE: enable sshd AllowTcpForwarding for the reverse-tunnel callbacks"
    for t in jq curl; do
        command -v "$t" >/dev/null 2>&1 ||
            echo "[fail2ban-ui] WARN: host '$t' missing; the ban/unban callback action needs it"
    done

    echo "[fail2ban-ui] SSH connector ready: user '$SA', key authorized."
    echo "[fail2ban-ui] UI → Manage Servers → add host=host.docker.internal port=22 user=$SA" \
         "key=/config/.ssh/$(basename "$KEY"); enable 'reverse tunnel for events'" \
         "(port ${FAIL2BAN_UI_TUNNEL_PORT:-= server port})."
fi

# Build the ET Open ruleset, trimmed by suricata/disable.conf (see Monitoring.md
# §12.1). suricata-update only downloads rules, so the rootless daemon is fine
# here — no raw-socket access needed. Rebuild when the ruleset is missing OR the
# disable list changed (so an edit to disable.conf takes effect on the next
# deploy); otherwise skip to keep deploys fast. The daily cron (§10) refreshes it
# afterwards and honours the same disable.conf.
NEWDIS=./suricata/disable.conf
APPLIED="$SURICATA_DATA/rules/.disable.conf.applied"
if [ ! -s "$SURICATA_DATA/rules/suricata.rules" ] || ! cmp -s "$NEWDIS" "$APPLIED"; then
    echo "[suricata] (re)building ET Open ruleset with disable list..."
    docker run --rm \
        -v "$SURICATA_DATA/rules:/var/lib/suricata/rules" \
        -v "$SURICATA_DATA/disable.conf:/etc/suricata/disable.conf:ro" \
        jasonish/suricata:latest suricata-update --no-test \
        --disable-conf /etc/suricata/disable.conf -o /var/lib/suricata/rules \
        && cp "$NEWDIS" "$APPLIED" \
        || echo "[suricata] WARN: rule build failed; starting with the previous rules (or local.rules only)"
fi

# Suricata runs ROOTFUL (own compose) because sniffing the physical uplink needs
# CAP_NET_RAW in the init user namespace, which rootless Docker can't grant. See
# suricata/docker-compose.yml for the full explanation. Everything else in this
# stack stays rootless; only this one container uses the system daemon.
# Capture the uplink + the Traefik bridge only (not every idle app bridge).
# Match the bridge by its stable subnet so hash-based br-* name churn is a
# non-issue. The host side always has `ip`; the suricata image may not, so we
# resolve the name here and pass it into the container via SURICATA_CAPTURE_BRIDGES.
# Empty (core stack down / no match) => uplink-only capture, a safe default.
SURICATA_CAPTURE_BRIDGES=""
if [ -n "${SURICATA_BRIDGE_SUBNET:-}" ]; then
    SURICATA_CAPTURE_BRIDGES=$(ip -4 -o addr show 2>/dev/null \
        | awk -v p="${SURICATA_BRIDGE_SUBNET}." '$4 ~ "^"p {print $2}' \
        | grep -E '^(br-|docker0)' | sort -u | tr '\n' ' ')
fi

if systemctl list-unit-files docker.service >/dev/null 2>&1; then
    sudo systemctl enable --now docker &&
    sudo env SURICATA_CAPTURE_BRIDGES="$SURICATA_CAPTURE_BRIDGES" \
        docker compose --env-file .env -f suricata/docker-compose.yml \
        up -d --force-recreate --remove-orphans ||
        echo "[suricata] WARN: rootful sensor failed to start; check 'sudo docker logs suricata'"
else
    echo "[suricata] WARN: no system docker.service; cannot start the rootful sensor"
fi
