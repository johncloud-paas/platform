# Suricata (af-packet / IDS mode) — Install & Docker-Aware Capture

Hands-on tutorial implementing the **Suricata sensor** from [`Monitoring.md`](./Monitoring.md):
passive IDS on `af-packet`, ET Open + `local.rules`, writing alerts to `eve.json`
for Fail2ban / EveBox to consume later.

This guide is tailored to **this host**: single-node Ubuntu, Docker Compose,
Pangolin + Gerbil + Traefik. It is written so Suricata sees **both** the external
edge **and** traffic to/between Docker containers.

> **Already implemented in this repo.** The config files below live in
> [`suricata/`](./suricata/) and deploy like every other stack:
> `./startstack.sh ./suricata`. `setup_before_up.sh` copies the config to
> `$JOHNCLOUD_ROOT/suricata/` and fetches ET Open on first run. The sections
> below explain each file and how to verify/tune it — host-side paths therefore
> point at `$JOHNCLOUD_ROOT/suricata/…`, not the repo tree.

---

## 0. What Suricata can and cannot see (read this first)

Docker traffic lives on two different wires, and they show you different things:

| Where you capture | What you see | Why it matters |
|---|---|---|
| **`eth0` (uplink)** | Every packet in/out of the box, **pre-NAT**. For traffic to published container ports you get the **real external client IP** → `80.241.220.240:443`. All ports/protocols, port scans, TLS SNI/JA3. | This is the primary IDS + Fail2ban signal. af-packet taps the NIC *before* netfilter DNAT, so the attacker's real IP is preserved. |
| **Docker bridges (`br-*`, `docker0`)** | The **post-DNAT** copy of that flow (`…→172.x.y.z:port`), plus **east-west** container↔container traffic, and **plaintext** HTTP between Traefik and backends after TLS termination. | This is "packets targeting Docker." Without it you miss internal lateral movement and the decrypted HTTP layer. |

Two honest limitations on this stack:

1. **TLS is terminated at Traefik.** On `eth0`, HTTPS to your services is
   encrypted — Suricata sees the TLS handshake (SNI, JA3, cert), not the HTTP
   body. The **plaintext** HTTP only exists on the Docker bridge between Traefik
   and the backend container. That's a second reason to capture the bridges.
2. **Gerbil/Newt tunnels are WireGuard** (`51820/udp`, `21820/udp`). On `eth0`
   that traffic is ciphertext. The decrypted resource traffic appears on the
   Docker side after Gerbil handles it — again, caught by bridge capture.

**Design decision for this host:** capture on `eth0` **and auto-discover every
active `br-*` / `docker0` bridge**. Bridge names here are hash-based
(`br-2cb477635178`) and change when a network is recreated, and new app stacks
add new bridges — so we discover them at container start rather than hard-coding.

> We capture **bridges**, not the individual `veth*` legs. A bridge already
> aggregates all its members' traffic; capturing veths too would only create
> duplicates.

---

## 1. Confirm the interfaces

```bash
ip -br link                 # list links
ip -br addr                 # with addresses
```

On this host today:

```
eth0              UP    80.241.220.240/24  (uplink)
br-2cb477635178   UP    192.168.203.1/24   (active Traefik/Pangolin bridge)
docker0           DOWN  172.17.0.1/16
br-b847576fc99b   DOWN  172.18.0.1/16      (revika_default)
br-36efebd6c58f   DOWN  172.19.0.1/16      (revika-ipfs_default)
…plus webprogress_default (172.20), thyrea-engine_default (172.21)
```

`eth0` is the uplink. The discovery script below handles all the bridges, so you
only need to confirm the **uplink name** here (`eth0`). If yours differs
(`ens3`, `enp1s0`…), set `SURICATA_UPLINK` in the compose file in step 6.

---

## 2. Directory layout

Tracked config lives in the repo under `suricata/`; runtime config + data are
provisioned to `$JOHNCLOUD_ROOT/suricata/` by `setup_before_up.sh` (same pattern
as the `monitoring/` stack), so logs/rules never land in the git tree.

```
suricata/                       # in the repo (tracked)
├── docker-compose.yml          # the Suricata service (step 6)
├── setup_before_up.sh          # copies config to $JOHNCLOUD_ROOT + fetches ET Open
├── entrypoint.sh               # multi-interface discovery wrapper (step 5)
└── etc/
    ├── suricata.yaml           # main config (step 3)
    └── local.rules             # your own rules (step 4)

$JOHNCLOUD_ROOT/suricata/       # on the host (runtime, not in git)
├── suricata.yaml  local.rules  entrypoint.sh   # copies, bind-mounted read-only
├── rules/                      # suricata-update writes suricata.rules here
└── logs/                       # eve.json, stats.log, fast.log → Fail2ban/EveBox
```

---

## 3. `suricata/etc/suricata.yaml`

A minimal, IDS-focused config. Interfaces are passed on the command line by the
entrypoint, so the `af-packet` block here only needs the **`default`** stanza
that supplies tuning for every `-i` interface.

```yaml
%YAML 1.1
---
# ---- Address groups --------------------------------------------------------
vars:
  address-groups:
    # Everything we consider "ours": the public IP, all RFC1918 Docker ranges,
    # the Pangolin bridge, and our IPv6 /64.
    HOME_NET: "[80.241.220.240/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,2a02:c207:2337:7562::/64]"
    EXTERNAL_NET: "!$HOME_NET"
    HTTP_SERVERS: "$HOME_NET"
    DNS_SERVERS: "$HOME_NET"
  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"

# ---- Capture defaults (applied to every -i interface) ----------------------
af-packet:
  - interface: default
    cluster-type: cluster_flow   # keep both directions of a flow on one thread
    cluster-id: 99
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes
    ring-size: 100000            # raise if you see capture.kernel_drops in stats
    block-size: 1048576

# ---- Logging / outputs -----------------------------------------------------
default-log-dir: /var/log/suricata/

outputs:
  - fast:                        # human-readable one-liners
      enabled: yes
      filename: fast.log
  - eve-log:                     # THE file Fail2ban + EveBox consume
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert:
            metadata: yes
            tagged-packets: yes
        - http:
            extended: yes
        - dns
        - tls:
            extended: yes
        - flow                   # includes in_iface — proves which wire a flow came from
        - anomaly
  - stats:
      enabled: yes
      filename: stats.log
      interval: 30               # watch capture.kernel_drops here

# ---- Rules -----------------------------------------------------------------
default-rule-path: /var/lib/suricata/rules
rule-files:
  - suricata.rules               # ET Open, written by suricata-update
  - /etc/suricata/local.rules    # your own rules

# ---- Housekeeping ----------------------------------------------------------
stats:
  enabled: yes
  interval: 30

logging:
  default-log-level: notice
  outputs:
    - console:
        enabled: yes

app-layer:
  protocols:
    tls:
      enabled: yes
    http:
      enabled: yes
```

> `HOME_NET` includes the Docker RFC1918 ranges on purpose — so rules that care
> about traffic direction treat container subnets as "internal."

---

## 4. `suricata/etc/local.rules`

Start with two **test** rules so you can prove capture works on both wires
(`sid:1000001` fires on the edge, `sid:1000002` on the bridge). Keep or remove
them later.

```
# Fires on any ICMP echo request — easy end-to-end smoke test.
alert icmp any any -> any any (msg:"LOCAL ICMP echo request seen"; itype:8; sid:1000001; rev:1;)

# Fires on inbound SSH connection attempts (example of a real, useful local rule).
alert tcp $EXTERNAL_NET any -> $HOME_NET 22 (msg:"LOCAL inbound SSH attempt"; flow:to_server; flags:S; sid:1000002; rev:1;)
```

ET Open (~50k rules) is added in step 8 via `suricata-update`; it writes to
`suricata/rules/suricata.rules`.

---

## 5. `suricata/entrypoint.sh` — capture uplink + every active bridge

This is the piece that makes Suricata **Docker-aware**. It builds a `-i` flag for
`eth0` and for each **UP** `br-*` / `docker0` bridge at startup.

```sh
#!/bin/sh
set -eu

UPLINK="${SURICATA_UPLINK:-eth0}"
IFACES="$UPLINK"

# Discover active Docker bridges (hash-named br-* plus the default docker0).
for path in /sys/class/net/br-* /sys/class/net/docker0; do
    [ -e "$path" ] || continue
    dev=${path##*/}
    state=$(cat "$path/operstate" 2>/dev/null || echo down)
    [ "$state" = "down" ] && continue          # skip bridges with no attached containers
    IFACES="$IFACES $dev"
done

# Assemble the -i arguments.
set --
for i in $IFACES; do set -- "$@" -i "$i"; done

echo "[entrypoint] Suricata capturing on:$(printf ' %s' $IFACES)"
exec suricata -c /etc/suricata/suricata.yaml "$@" -v
```

```bash
chmod +x suricata/entrypoint.sh
```

> **New app stack later?** Its bridge only gets picked up on the next Suricata
> start. After bringing up a new network run `docker compose restart suricata`.
> (If you want it fully automatic, add a cron that diffs `ip -br link` and
> restarts Suricata on change — optional; left out to keep this simple.)

---

## 6. `suricata/docker-compose.yml`

`network_mode: host` so the container shares the host's network namespace and can
therefore see `eth0` **and** every `br-*`. `NET_ADMIN`/`NET_RAW` are required for
af-packet.

```yaml
name: suricata

services:
  suricata:
    image: jasonish/suricata:latest      # OISF community image, ships suricata-update
    container_name: suricata
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_NICE
    environment:
      - SURICATA_UPLINK=eth0             # change if your uplink isn't eth0
    entrypoint: ["/entrypoint.sh"]
    volumes:
      - ./entrypoint.sh:/entrypoint.sh:ro
      - ./etc/suricata.yaml:/etc/suricata/suricata.yaml:ro
      - ./etc/local.rules:/etc/suricata/local.rules:ro
      - ./rules:/var/lib/suricata/rules
      - ./logs:/var/log/suricata
    healthcheck:
      test: ["CMD", "pgrep", "-x", "suricata"]
      interval: 30s
      timeout: 5s
      retries: 3
```

---

## 7. Disable NIC offloads on the host (important)

With GRO/LRO/TSO/GSO enabled, the kernel hands Suricata **coalesced** segments
larger than the real wire packets, which breaks stream reassembly and causes
false "invalid packet" anomalies. Turn them off on the uplink **and** the
bridges. This is a host-level setting, so do it on the host (not in the
container).

One-off:

```bash
for i in eth0 docker0 $(ls /sys/class/net | grep '^br-'); do
    sudo ethtool -K "$i" gro off lro off tso off gso off 2>/dev/null || true
done
```

Make it persist across reboots with a tiny systemd unit:

```bash
sudo tee /etc/systemd/system/suricata-offloads.service >/dev/null <<'EOF'
[Unit]
Description=Disable NIC offloads for Suricata capture
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in eth0 docker0 $(ls /sys/class/net | grep "^br-"); do ethtool -K "$i" gro off lro off tso off gso off 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now suricata-offloads.service
```

> New bridges created after boot won't be covered until this re-runs. Re-run it
> (`sudo systemctl start suricata-offloads.service`) after adding a stack, or
> accept minor reassembly noise on brand-new bridges.

---

## 8. First start + fetch ET Open rules

```bash
# From the repo root. startstack.sh runs setup_before_up.sh (copies config to
# $JOHNCLOUD_ROOT/suricata, fetches ET Open), then compose up, then tails logs.
./startstack.sh ./suricata suricata
```

That's it — `setup_before_up.sh` already pulls the ET Open ruleset on first run.
Watch for the entrypoint line `Suricata capturing on: eth0 br-2cb477635178 …` and
`<Notice> - all N packet processing threads … initialized`.

Manual equivalents if you prefer:

```bash
cd suricata
sudo bash ./setup_before_up.sh "$(readlink -f .)"   # provision + fetch rules
docker compose up -d
docker compose logs -f suricata
```

Healthy startup shows the interface list from the entrypoint and
`<Notice> - all 3 packet processing threads, 4 management threads initialized`
(thread count varies with interface/CPU count).

---

## 9. Verify — edge capture AND Docker capture

The `eve.json` `flow` / `alert` events carry an **`in_iface`** field. That's your
proof of *which wire* a packet was seen on.

**9a. Edge (`eth0`) — trigger the ICMP test rule from another machine:**

```bash
ping -c 2 80.241.220.240          # from your laptop / another host
```

On the server:

```bash
docker compose exec suricata sh -c \
  "grep 'LOCAL ICMP' /var/log/suricata/eve.json | tail -1" | jq '{iface:.in_iface, src:.src_ip, sig:.alert.signature}'
# expect in_iface: "eth0"
```

**9b. Docker bridge — generate container-side traffic and confirm `in_iface` is a `br-*`:**

```bash
# Ping a container's gateway / another container to create bridge traffic,
# or just hit a published service which produces the post-DNAT copy on the bridge.
curl -k https://dockhand.$HOST/ -o /dev/null -s

# Show which interfaces have produced flows — you should see eth0 AND br-...
docker compose exec suricata sh -c \
  "tail -2000 /var/log/suricata/eve.json" | jq -r 'select(.event_type=="flow") | .in_iface' | sort | uniq -c
```

Expected output is something like:

```
    842 eth0
    310 br-2cb477635178
```

Two different `in_iface` values = Suricata is watching the edge **and** Docker. ✅

**9c. Real-signature smoke test (ET Open):**

```bash
curl http://testmynids.org/uid/index.html      # harmless; trips an ET policy rule
docker compose exec suricata sh -c \
  "grep -i 'id check returned root' /var/log/suricata/eve.json | tail -1" | jq '.alert.signature'
```

---

## 10. Keep ET Open fresh (auto-update)

`suricata-update` should run on a schedule, followed by a rule reload (no
restart / no dropped packets needed — Suricata reloads rules on `SIGUSR2`).

```bash
sudo tee /etc/cron.daily/suricata-update >/dev/null <<'EOF'
#!/bin/sh
cd /home/yann/repos/johncloud/platform/suricata || exit 0
docker compose run --rm --entrypoint suricata-update suricata >/var/log/suricata-update.log 2>&1
# hot-reload rules without dropping capture:
docker compose kill -s USR2 suricata 2>/dev/null || docker compose restart suricata
EOF
sudo chmod +x /etc/cron.daily/suricata-update
```

---

## 11. Performance notes (single node, ~50k rules, several interfaces)

- **Watch drops.** `grep kernel_drops $JOHNCLOUD_ROOT/suricata/logs/stats.log` — if non-zero and
  climbing, raise `ring-size` in `suricata.yaml` (×2 until it stops) and/or trim
  rules with `suricata-update --disable-conf`.
- **CPU scales with interfaces × rules.** Each UP bridge adds capture threads. If
  idle app bridges cost too much, narrow the discovery in `entrypoint.sh` to just
  `eth0` + the Traefik bridge (`br-2cb477635178`) and the bridges you actually
  care to inspect.
- **Disk.** `eve.json` grows fast. Add logrotate for `$JOHNCLOUD_ROOT/suricata/logs/*.json`
  / `*.log`, or switch `eve-log` rotation on. EveBox/Fail2ban tail the live file,
  so rotate with `copytruncate` or Suricata's own rotation.
- **Duplicate-ish alerts** for a flow seen on `eth0` (pre-NAT) and again on a
  bridge (post-NAT) are expected — different dst IPs, so different flows. Tune
  with rule thresholds if noisy.

---

## 12. Next steps (per Monitoring.md)

- **Fail2ban**: point a jail's `logpath` at `suricata/logs/eve.json` (there's a
  community `eve.json` filter) plus your Traefik logs under `pangolin/logs/`.
  Start jails in **detection-only** mode as the doc specifies.
- **EveBox** (optional web UI): run `jasonish/evebox` against
  `suricata/logs/eve.json` and put it behind Pangolin/Traefik — see the Web UI
  discussion for EveBox vs Grafana.

---

### Quick reference

```bash
# status / logs
docker compose -f suricata/docker-compose.yml ps
docker compose -f suricata/docker-compose.yml logs -f suricata

# which interfaces are being captured right now
docker compose -f suricata/docker-compose.yml logs suricata | grep 'capturing on'

# live alerts
docker compose -f suricata/docker-compose.yml exec suricata \
  tail -f /var/log/suricata/fast.log

# capture health (drops should stay ~0)
grep -E 'kernel_(packets|drops)' $JOHNCLOUD_ROOT/suricata/logs/stats.log | tail
```
```
