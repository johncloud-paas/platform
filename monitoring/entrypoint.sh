#!/bin/sh
set -eu
# Capture on the uplink + every ACTIVE Docker bridge (br-* / docker0).
# Bridge names are hash-based and churn as stacks come and go, so we discover
# them at start instead of hard-coding. Restart Suricata after bringing up a new
# Docker network to pick up its bridge.

UPLINK="${SURICATA_UPLINK:-eth0}"
IFACES="$UPLINK"

for path in /sys/class/net/br-* /sys/class/net/docker0; do
    [ -e "$path" ] || continue
    dev=${path##*/}
    state=$(cat "$path/operstate" 2>/dev/null || echo down)
    [ "$state" = "down" ] && continue        # skip bridges with no attached containers
    IFACES="$IFACES $dev"
done

# Assemble repeated -i flags.
set --
for i in $IFACES; do set -- "$@" -i "$i"; done

echo "[entrypoint] Suricata capturing on:$(printf ' %s' $IFACES)"
exec suricata -c /etc/suricata/suricata.yaml "$@" -v
