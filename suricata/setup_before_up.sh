# setup_before_up.sh
#! /bin/bash
# Provision Suricata config under $JOHNCLOUD_ROOT and fetch the ET Open ruleset.

cd $1

set -a; source .env; set +a

SURICATA_DATA="$JOHNCLOUD_ROOT/suricata"

(
    mkdir -p "$SURICATA_DATA/rules" "$SURICATA_DATA/logs" &&
    cp ./entrypoint.sh "$SURICATA_DATA/" &&
    cp ./etc/suricata.yaml ./etc/local.rules "$SURICATA_DATA/" &&
    chmod +x "$SURICATA_DATA/entrypoint.sh"
)

# First-time rule fetch (ET Open ~50k rules). Refreshed daily by cron afterwards;
# see Suricata-Setup.md §10.
if [ ! -s "$SURICATA_DATA/rules/suricata.rules" ]; then
    echo "[suricata] fetching ET Open ruleset (first run)..."
    docker run --rm -v "$SURICATA_DATA/rules:/var/lib/suricata/rules" \
        jasonish/suricata:latest suricata-update --no-test -o /var/lib/suricata/rules \
        || echo "[suricata] WARN: rule fetch failed; starting with local.rules only"
fi
