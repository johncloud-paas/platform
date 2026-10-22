#!/bin/sh
set -eu
# Capture on the uplink + ONLY the bridges named in $SURICATA_CAPTURE_BRIDGES.
# Capturing every active bridge inspects the same traffic twice (pre-NAT on the
# uplink, again post-NAT on the bridge) and adds capture threads per bridge, so
# we restrict to the Traefik bridge the operator cares about. Its hash-based name
# (br-<id>) churns, so setup_before_up.sh resolves it by subnet on the host and
# passes the current name(s) in here. Restart Suricata after recreating that
# network to pick up the new bridge name.

UPLINK="${SURICATA_UPLINK:-eth0}"
IFACES="$UPLINK"

for dev in ${SURICATA_CAPTURE_BRIDGES:-}; do
    path="/sys/class/net/$dev"
    [ -e "$path" ] || continue
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
