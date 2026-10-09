# setup_before_up.sh
#! /bin/bash

cd $1

set -a; source .env; set +a

SURICATA_DATA="$JOHNCLOUD_ROOT/suricata"

(
    envsubst '$PUBLIC_IP_ADDRESS $JOHNCLOUD_ROOT' < fail2ban/jail.d/suricata.template.conf > fail2ban/jail.d/suricata.conf &&    
    envsubst '$PUBLIC_IP_ADDRESS' < suricata/suricata.template.yaml > suricata/suricata.yaml &&        
    mkdir -p $JOHNCLOUD_ROOT/victoriametrics/data $JOHNCLOUD_ROOT/victorialogs/data $JOHNCLOUD_ROOT/victoriatraces/data $JOHNCLOUD_ROOT/fluent-bit &&
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
        cp ./fail2ban/filter.d/suricata.conf   /etc/fail2ban/filter.d/ &&
        cp ./fail2ban/action.d/suricata-raw.conf /etc/fail2ban/action.d/ &&
        cp ./fail2ban/jail.d/suricata.conf     /etc/fail2ban/jail.d/ &&
        fail2ban-client reload &&
        echo "[fail2ban] suricata jail installed & reloaded"
    else
        echo "[fail2ban] WARN: need root to install jail; run setup as root or copy ./fail2ban/* into /etc/fail2ban/ manually"
    fi
else
    echo "[fail2ban] WARN: fail2ban-client not found; skipping jail install"
fi

# First-time rule fetch (ET Open ~50k rules). Refreshed daily by cron afterwards;
# see Monitoring.md "Suricata Setup" §10.
if [ ! -s "$SURICATA_DATA/rules/suricata.rules" ]; then
    echo "[suricata] fetching ET Open ruleset (first run)..."
    docker run --rm -v "$SURICATA_DATA/rules:/var/lib/suricata/rules" \
        jasonish/suricata:latest suricata-update --no-test -o /var/lib/suricata/rules \
        || echo "[suricata] WARN: rule fetch failed; starting with local.rules only"
fi
