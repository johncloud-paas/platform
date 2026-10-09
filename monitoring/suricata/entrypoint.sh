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

# Give each interface its OWN cluster-id.
# A kernel PACKET_FANOUT group is bound to the device of its first member
# socket, so every interface must use a distinct cluster-id -- otherwise the
# 2nd+ interface fails to join group 99 with "failed to set fanout mode:
# Invalid argument".
#
# We inject a per-interface af-packet stanza (interface + cluster-id; every
# other setting is inherited from the `default` stanza) into the config. We do
# this by rendering a runtime copy of suricata.yaml rather than via the
# `--set af-packet.N.*` CLI, because that command-line form SEGFAULTS Suricata
# 8.0.7 while it builds the synthetic sequence entries (exit 139). The mounted
# config is read-only, so the merged copy is written to a writable path.
BASE=/etc/suricata/suricata.yaml
RUNTIME=/tmp/suricata.runtime.yaml

stanzas=""
cid=99
for i in $IFACES; do
    stanzas="${stanzas}  - interface: ${i}
    cluster-id: ${cid}
"
    cid=$((cid + 1))
done

# Append the per-interface stanzas to the existing af-packet sequence: inject
# them just before the first top-level key/comment that follows `af-packet:`,
# so the template's `default` stanza (the inherited tuning) is preserved.
awk -v stanzas="$stanzas" '
    /^af-packet:/        { print; inblock=1; next }
    inblock && /^[^[:space:]]/ { printf "%s", stanzas; inblock=0 }
    { print }
' "$BASE" > "$RUNTIME"

# One -i flag per interface (the capture runmode); per-interface tuning comes
# from the matching af-packet stanza in $RUNTIME.
set --
for i in $IFACES; do
    set -- "$@" -i "$i"
done

echo "[entrypoint] Suricata capturing on:$(printf ' %s' $IFACES)"
exec suricata -c "$RUNTIME" "$@" -v
