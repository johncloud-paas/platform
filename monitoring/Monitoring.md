# Monitoring, Intrusion Detection & Blocking

Design notes and reference for host traffic monitoring, malicious-activity detection
via customizable policies, and automatic/manual blocking on this node.

## Context & Requirements

- **Environment:** single-node Ubuntu, Docker Compose (not Swarm, not Kubernetes).
- **Existing stack:** Pangolin (`fosrl/pangolin`) + Gerbil + Newt tunneling,
  Traefik reverse proxy, GeoIP (MaxMind GeoLite2), docker-socket-proxy, Dockhand.
  Traefik access logs land in `./pangolin/logs/`.
- **Goals:**
  1. Monitor **all** traffic on the host (every port/protocol, not just HTTP).
  2. Detect malicious activity through **customizable policies**.
  3. **Block** offenders, **manually or automatically**.
- **Hard constraint:** fully **free and open source**. No commercial tier that
  gates the interesting functionality.

---

## Decision Summary

| Decision | Choice | Date |
|---|---|---|
| Detection sensor | **Suricata** (native apt, `af-packet` IDS mode) | 2026-10-08 |
| Rule source | **ET Open** ruleset + custom `local.rules` | 2026-10-08 |
| Block engine | **CrowdSec** (agent + LAPI + nftables bouncer, native apt) | 2026-11-09 |
| Blocking posture | **Automatic** — severity-1 alerts → ban; manual via `cscli` | 2026-11-09 |
| Alert UI (optional) | **EveBox** (GPLv2) | 2026-10-08 |
| Telemetry store | **Vector → PostgreSQL** (logs + metrics, no TimescaleDB) | 2026-11-04 |
| Rejected | **Fail2ban** — superseded by CrowdSec | 2026-11-09 |

---

## Architecture

```
┌────────────────────── HOST LEVEL (systemd services) ────────────────────┐
│                                                                         │
│  suricata.service ─── sniffs eth0 + Traefik br ──► /var/log/suricata/  │
│  (native apt, af-packet IDS mode, ET Open + local.rules)    eve.json   │
│                                                                │        │
│  Traefik access log (core stack vol) ──────────► TRAEFIK_LOG_DIR/      │
│                                                   access.log  │        │
│  sshd ─────────────────────────────────────────► /var/log/auth.log │   │
│                                                                │        │
│                        [crowdsec/acquisitions.yaml]            │        │
│                                   │  file tailing              │        │
│                                   ▼                            │        │
│  crowdsec.service ── parsers + scenarios ──────────────────────┘        │
│  (native apt — agent + LAPI, localhost:8080)                            │
│    crowdsecurity/suricata  → severity-1 alert → ban                    │
│    crowdsecurity/traefik   → 4xx probing → ban                         │
│    crowdsecurity/sshd      → brute force → ban                         │
│                   │                                                     │
│    ┌──────────────┴──────────────────────────────────┐                  │
│    ▼                                                 ▼                  │
│  crowdsec-firewall-bouncer.service      (optional) traefik-bouncer      │
│  nftables DROP at PREROUTING           forwardAuth → HTTP 403           │
│                                                                         │
│  Vector (rootless monitoring stack)                                     │
│    prometheus_scrape → localhost:6060/metrics → PostgreSQL metrics      │
│    docker_logs       → container stdout/stderr  → PostgreSQL logs       │
└─────────────────────────────────────────────────────────────────────────┘
```

**Division of labour:**
- **Suricata** — the *sensor*. Sees every packet on the uplink and Docker bridges, writes
  `alert` events to `eve.json`.
- **CrowdSec agent** — the *brain*. Parses `eve.json` (and Traefik + sshd logs) through
  community parsers, fires scenarios, pushes ban decisions to the LAPI.
- **CrowdSec LAPI** — the *hub*. Stores decisions; bouncers poll it.
- **cs-firewall-bouncer** — the *enforcer*. Reads LAPI decisions and writes nftables rules
  that DROP traffic from banned IPs at PREROUTING (before NAT, before Docker routing).

**Manual operations** (replace the old `fail2ban-client` commands):
```bash
cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual"
cscli decisions delete --ip 1.2.3.4
cscli decisions list
cscli alerts list
```

---

## Host Setup: Step-by-Step

This tutorial installs the complete host security layer on a fresh Ubuntu node.
The monitoring Docker stack (Vector, cadvisor, etc.) is a separate step afterwards.

### Prerequisites

- Ubuntu 22.04+ (or Debian 12+) with root access.
- The `monitoring/` repo directory present on the host.
- Rootless Docker already set up (for the monitoring stack later). Rootful Docker
  is **not** required — Suricata no longer needs it.
- `add-apt-repository` available (`apt-get install -y software-properties-common`).

### Step 0 — Set required .env variables

Copy `monitoring/sample.env` → `monitoring/.env` and fill in at minimum:

```bash
JOHNCLOUD_ROOT=/path/to/paas/data   # writable directory for persistent state
HOST=yourdomain.tld
PUBLIC_IP_ADDRESS=1.2.3.4           # your server's public IPv4
SURICATA_UPLINK=eth0                # uplink interface name (ip -br link)
SURICATA_BRIDGE_SUBNET=192.168.203  # first 3 octets of the Traefik bridge subnet
TRAEFIK_LOG_DIR=/path/to/core/pangolin/traefik/logs   # for CrowdSec Traefik parser
TRAEFIK_NETWORK=traefik-proxy
```

Confirm the uplink name and Traefik bridge subnet:
```bash
ip -br addr           # find eth0 address and br-* with 192.168.203.x
```

### Step 1 — Run the installer

```bash
cd /path/to/platform/monitoring
sudo bash scripts/install-host-security.sh
```

The script is **idempotent** — safe to re-run after changing `.env`, editing config
templates, or adding new Docker networks. It performs:

1. **Suricata** (§ Suricata Reference below for details):
   - Adds OISF PPA, installs `suricata` + `suricata-update`
   - Renders `suricata/suricata.template.yaml` → `/etc/suricata/suricata.yaml`
   - Installs `/usr/local/sbin/suricata-configure` (bridge discovery + config render,
     called by systemd `ExecStartPre` before each service start)
   - Fetches ET Open ruleset via `suricata-update --disable-conf /etc/suricata/disable.conf`
   - Enables and starts `suricata.service`
   - Installs `suricata-offloads.service` (NIC GRO/LRO/TSO disable)
   - Writes `/etc/logrotate.d/suricata` and `/etc/cron.daily/suricata-update`

2. **CrowdSec** (§ CrowdSec Reference below for details):
   - Adds packagecloud APT repo, installs `crowdsec` + `crowdsec-firewall-bouncer-nftables`
   - Renders `crowdsec/acquisitions.yaml` → `/etc/crowdsec/acquis.d/johncloud.yaml`
   - Renders `crowdsec/whitelist.yaml` → `/etc/crowdsec/parsers/s02-enrich/99-local-whitelist.yaml`
   - Installs hub collections: `crowdsecurity/suricata`, `crowdsecurity/traefik`, `crowdsecurity/sshd`
   - Registers the nftables bouncer with LAPI, writes `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`
   - Enables and starts `crowdsec.service` + `crowdsec-firewall-bouncer.service`

3. **Fail2ban cleanup** (if present): stops and disables the service.

### Step 2 — Verify Suricata

```bash
# Service is running
systemctl status suricata

# See which interfaces were bound at startup
journalctl -u suricata --since "5 min ago" | grep 'Capturing on\|capturing on'
# expect: [suricata-configure] Capturing on: eth0 br-2cb477635178

# Live alerts (alert-only logging, so every line is an alert)
tail -f /var/log/suricata/eve.json | jq '{iface:.in_iface, src:.src_ip, sig:.alert.signature}'

# Smoke test: trigger the ICMP rule (from another machine)
ping -c 2 <your-server-ip>
# then on the server:
grep 'LOCAL ICMP' /var/log/suricata/eve.json | tail -1 | jq '{src:.src_ip, iface:.in_iface}'
# expect: in_iface: "eth0"

# ET Open smoke test (harmless URL that trips an ET policy rule)
curl http://testmynids.org/uid/index.html
grep -i 'id check returned root' /var/log/suricata/eve.json | tail -1 | jq '.alert.signature'

# Capture health (kernel_drops should stay near zero)
grep -E 'kernel_(packets|drops)' /var/log/suricata/stats.log | tail -5
```

### Step 3 — Verify CrowdSec

```bash
# Services running
systemctl status crowdsec crowdsec-firewall-bouncer

# CrowdSec sees the suricata log source
cscli metrics                   # shows acquisition counts per source
cscli alerts list               # recent alerts from all parsers

# Manual ban flows all the way to nftables
cscli decisions add --ip 203.0.113.1 --duration 5m --reason "test"
nft list ruleset | grep 203.0.113.1    # should appear in CROWDSEC chain
cscli decisions list --ip 203.0.113.1  # confirmed as 'ban'
cscli decisions delete --ip 203.0.113.1

# Check collections are installed
cscli collections list | grep -E 'suricata|traefik|sshd'
```

### Step 4 — Start the monitoring stack

The monitoring stack (Vector, cadvisor, PDC agent, etc.) is rootless Docker and
completely independent of the host security layer above. Start it the usual way:

```bash
./startstack.sh ./monitoring
```

`setup_before_up.sh` checks that `suricata.service` and `crowdsec.service` are
active and warns if not, but does not fail — the monitoring stack itself does not
depend on them.

After the stack is up, verify CrowdSec metrics reach PostgreSQL:

```bash
# Give Vector ~60s to scrape localhost:6060/metrics
psql -h <core-db-host> -U monitoring monitoring \
  -c "SELECT name, value FROM metric_samples WHERE name LIKE 'cs_%' ORDER BY timestamp DESC LIMIT 10;"
```

### Step 5 — Post-install checklist

- [ ] `TRAEFIK_LOG_DIR` set in `.env`; CrowdSec tailing Traefik `access.log`  
      (`cscli metrics` → `traefik` source shows non-zero `Lines read`)
- [ ] Run `./tests/run.sh` (offline suite) — all three suites pass
- [ ] Run first `curl testmynids.org` smoke test; alert appears in `eve.json`
- [ ] Confirm `cscli alerts list` shows Suricata-sourced alerts after test
- [ ] (Optional) Add EveBox for alert review UI
- [ ] (Optional) Add WireGuard transport metrics (`wg-exporter` in Gerbil's netns → PostgreSQL)
- [ ] (Optional) Cron free threat-intel blocklists (abuse.ch / FireHOL / Spamhaus DROP)
      into a dedicated nftables set as an additional layer

### Re-running after changes

```bash
# After editing suricata/suricata.template.yaml, suricata/disable.conf, or any .env var
sudo bash monitoring/scripts/install-host-security.sh

# After adding a new Docker stack (new bridge to capture)
sudo bash monitoring/scripts/install-host-security.sh
# or just restart Suricata (the configure script re-discovers bridges):
sudo systemctl restart suricata

# After editing crowdsec/acquisitions.yaml or crowdsec/whitelist.yaml
sudo bash monitoring/scripts/install-host-security.sh
# or manually: re-render + reload
sudo PUBLIC_IP_ADDRESS=... TRAEFIK_LOG_DIR=... \
    envsubst '$TRAEFIK_LOG_DIR' < monitoring/crowdsec/acquisitions.yaml \
    > /etc/crowdsec/acquis.d/johncloud.yaml
sudo systemctl reload crowdsec
```

---

## Suricata Reference

### What Suricata can and cannot see

Docker traffic lives on two different wires:

| Where you capture | What you see | Why it matters |
|---|---|---|
| **`eth0` (uplink)** | Every packet in/out pre-NAT. Real external client IP. All ports/protocols, port scans, TLS SNI/JA3. | Primary IDS signal — af-packet taps before DNAT. |
| **Docker bridges (`br-*`)** | Post-DNAT copy of that flow + east-west container traffic + plaintext HTTP between Traefik and backends after TLS termination. | Without this you miss internal lateral movement and the decrypted HTTP layer. |

Two honest limitations:

1. **TLS is terminated at Traefik.** On `eth0`, HTTPS is ciphertext — Suricata sees
   the TLS handshake (SNI, JA3, cert), not the HTTP body. The plaintext only exists
   on the Docker bridge. That's a second reason to capture the bridges.
2. **Gerbil/Newt tunnels are WireGuard** (`51820/udp`). On `eth0` that traffic is
   ciphertext. The decrypted resource traffic appears on the Docker side.

**Design decision:** capture `eth0` + the Traefik bridge only (not every idle bridge).
Bridge names are hash-based (`br-2cb477635178`) and change when the network is
recreated. `suricata-configure` resolves the bridge by its stable subnet
(`SURICATA_BRIDGE_SUBNET`, default `192.168.203`) at each service start.

### Directory layout

```
monitoring/suricata/            (in the repo — tracked)
├── suricata.template.yaml      # config template; $PUBLIC_IP_ADDRESS substituted at start
├── local.rules                 # your own Suricata rules (SID range 1000000-1999999)
└── disable.conf                # ET Open categories to suppress (~-29% CPU)

/etc/suricata/                  (deployed by install-host-security.sh)
├── suricata.template.yaml      # copy of the repo template
├── suricata.yaml               # rendered at each service start by suricata-configure
├── local.rules
└── disable.conf

/var/lib/suricata/rules/        (written by suricata-update)
└── suricata.rules              # ET Open merged ruleset

/var/log/suricata/              (written by the service)
├── eve.json                    # alert events → CrowdSec
└── stats.log                   # capture thread health
```

### `suricata/suricata.template.yaml`

One substitution variable: `$PUBLIC_IP_ADDRESS` → injected into `HOME_NET` via
`envsubst '$PUBLIC_IP_ADDRESS'` by `/usr/local/sbin/suricata-configure` at service
start. Everything else (`$HOME_NET`, `$EXTERNAL_NET`, etc.) is Suricata's own
variable syntax — not shell variables, left untouched by envsubst.

Key settings (abridged — see the file for the full address/port-group list):

```yaml
vars:
  address-groups:
    HOME_NET: "[$PUBLIC_IP_ADDRESS/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,...]"
    EXTERNAL_NET: "!$HOME_NET"

af-packet:
  - interface: default         # suricata-configure appends per-interface stanzas
    cluster-type: cluster_flow
    cluster-id: 99             # overridden per-interface; shared id causes EINVAL fanout
    use-mmap: yes
    tpacket-v3: yes
    ring-size: 100000          # raise if kernel_drops appear in stats.log

outputs:
  - eve-log:
      enabled: yes
      filename: eve.json
      types:
        - alert:               # alert-only; CrowdSec needs src_ip + alert.severity
            metadata: yes
  - stats:
      interval: 30

default-rule-path: /var/lib/suricata/rules
rule-files:
  - suricata.rules             # ET Open (suricata-update)
  - /etc/suricata/local.rules  # custom rules
```

### `/usr/local/sbin/suricata-configure`

Installed by `install-host-security.sh`. Called by systemd `ExecStartPre` before each
Suricata start. It:

1. Sources `/etc/default/suricata-johncloud` (env vars baked in by the install script:
   `SURICATA_UPLINK`, `SURICATA_BRIDGE_SUBNET`, `PUBLIC_IP_ADDRESS`).
2. Discovers UP bridges whose subnet matches `SURICATA_BRIDGE_SUBNET`.
3. Renders `/etc/suricata/suricata.template.yaml` → `/etc/suricata/suricata.yaml`
   (envsubst `$PUBLIC_IP_ADDRESS`).
4. Appends per-interface af-packet stanzas with **unique cluster-ids** (99, 100, …)
   using the same awk logic as the former `entrypoint.sh`.

> **Why unique cluster-ids?** `cluster_flow` uses Linux `PACKET_FANOUT`. A fanout group
> is keyed by `cluster-id` and bound to the first device that opens it. If interfaces
> share `cluster-id: 99`, the second interface fails with
> `failed to set fanout mode: Invalid argument`. The configure script assigns
> `eth0`=99, next bridge=100, and so on.

> **New app stack added?** Re-run `install-host-security.sh` or just
> `sudo systemctl restart suricata` — the configure script re-discovers all bridges.

### `suricata/local.rules`

Local rules use the reserved SID range `1000000-1999999`:

```
# Smoke test: fires on any ICMP echo request (verify capture on both wires)
alert icmp any any -> any any (msg:"LOCAL ICMP echo request seen"; itype:8; sid:1000001; rev:1;)

# Inbound SSH connection attempts
alert tcp $EXTERNAL_NET any -> $HOME_NET 22 (msg:"LOCAL inbound SSH attempt"; flow:to_server; flags:S; sid:1000002; rev:1;)

# Legacy TLS (correlate with Traefik logs)
alert tls $EXTERNAL_NET any -> $HOME_NET any (msg:"LOCAL legacy TLS 1.0 handshake"; ssl_version:tls1.0; sid:1000010; rev:1;)
alert tls $EXTERNAL_NET any -> $HOME_NET any (msg:"LOCAL legacy TLS 1.1 handshake"; ssl_version:tls1.1; sid:1000011; rev:1;)
```

### NIC offloads

With GRO/LRO/TSO/GSO enabled, the kernel hands Suricata **coalesced** segments larger
than real wire packets — this breaks stream reassembly and causes false anomalies.

The installer writes `suricata-offloads.service` which runs at boot and disables
offloads on all interfaces (`eth*`, `ens*`, `enp*`, `br-*`, `docker*`). After adding
a new Docker stack, restart the unit:

```bash
sudo systemctl start suricata-offloads.service
```

### ET Open ruleset

ET Open is fetched on first install and refreshed daily by `/etc/cron.daily/suricata-update`:

```bash
suricata-update --disable-conf /etc/suricata/disable.conf
systemctl kill -s USR2 suricata.service   # hot-reload, no dropped packets
```

`suricata/disable.conf` suppresses ~15,700 irrelevant rules (SCADA, GAMES, CHAT, mobile
malware, Windows-desktop targets) → **~37,600 rules remain (−29%)** from the full 53k.
See the file for the full category list and tuning instructions.

### Log rotation

`/etc/logrotate.d/suricata` rotates `eve.json` and `stats.log` daily with 7-day
retention. `postrotate` sends `SIGHUP` to `suricata.service`, which reopens log files
losslessly. `delaycompress` avoids compressing a file Suricata may still be writing to
in the brief window between rotation and signal delivery.

### Performance notes

- **Watch drops:** `grep kernel_drops /var/log/suricata/stats.log` — if non-zero and
  climbing, raise `ring-size` in `suricata.template.yaml` (double until it stops) or
  trim more rules in `suricata/disable.conf`, then re-run the installer.
- **CPU scales with interfaces × rules.** Each captured bridge adds capture threads.
  We capture only `eth0` + the Traefik bridge; set `SURICATA_BRIDGE_SUBNET=` empty
  for uplink-only (lowest CPU).
- **Duplicate-ish alerts** for a flow seen on `eth0` (pre-NAT) and again on a bridge
  (post-NAT) are expected — different dst IPs, different flows. Use rule thresholds
  if noisy.

### Quick reference

```bash
# Status
systemctl status suricata

# Which interfaces are captured
journalctl -u suricata -n 20 | grep 'capturing on'

# Live alerts
tail -f /var/log/suricata/eve.json | \
  jq -c 'select(.event_type=="alert") | {src:.src_ip, sig:.alert.signature, sev:.alert.severity}'

# Capture health
grep -E 'kernel_(packets|drops)' /var/log/suricata/stats.log | tail -5

# Hot-reload rules (after editing local.rules or running suricata-update)
sudo systemctl kill -s USR2 suricata.service
```

---

## CrowdSec Reference

### Components

**CrowdSec agent + LAPI** (`crowdsec.service`) — a single process that:
- Tails log files via acquisition config
- Runs community parsers (normalize lines into events)
- Fires scenarios (stateful machines that detect attack patterns)
- Writes ban decisions into the LAPI (Local API, `localhost:8080`)

**cs-firewall-bouncer** (`crowdsec-firewall-bouncer.service`) — polls LAPI every 10s,
writes `nft` rules into the `CROWDSEC` nftables chain (at PREROUTING, before DNAT, so
it covers both host-destined and container-forwarded traffic).

**LAPI** is embedded in `crowdsec.service` on this single-node setup. It listens on
`localhost:8080` only — not exposed externally.

### `monitoring/crowdsec/acquisitions.yaml`

Template rendered by `install-host-security.sh` into `/etc/crowdsec/acquis.d/johncloud.yaml`
via `envsubst '$TRAEFIK_LOG_DIR'`.

```yaml
# Suricata alerts (severity-1 → ban via crowdsecurity/suricata scenarios)
- filename: /var/log/suricata/eve.json
  labels:
    type: suricata

# Traefik access log (HTTP abuse signals: 4xx probing, bad user-agents)
- filename: ${TRAEFIK_LOG_DIR}/access.log
  labels:
    type: traefik

# Host sshd (brute force → crowdsecurity/sshd scenarios)
- filenames:
  - /var/log/auth.log
  labels:
    type: syslog
```

Each `type` maps to a CrowdSec parser set. The `crowdsecurity/suricata` parser reads
`event_type`, `src_ip`, and `alert.severity` from `eve.json`; its bundled scenario fires
a ban decision on severity-1 events.

### `monitoring/crowdsec/whitelist.yaml`

Template rendered into `/etc/crowdsec/parsers/s02-enrich/99-local-whitelist.yaml`
via `envsubst '$PUBLIC_IP_ADDRESS'`. Mirrors the Suricata `HOME_NET` — these IPs are
never banned regardless of alert content:

```yaml
name: crowdsecurity/whitelists
description: "JohnCloud local network whitelist"
whitelist:
  reason: "home network"
  ip:
    - "127.0.0.1"
    - "::1"
    - "${PUBLIC_IP_ADDRESS}"
  cidr:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
    - "173.16.238.0/24"    # Tailscale/WireGuard ranges
    - "11.16.238.0/24"
    - "2a02:c207:2337:7562::/64"
```

### Hub collections

Three collections installed by the installer. Each collection bundles a parser +
one or more scenarios:

| Collection | Parses | Scenario example |
|---|---|---|
| `crowdsecurity/suricata` | `eve.json` alerts | severity-1 → ban |
| `crowdsecurity/traefik` | Traefik JSON access log | HTTP scanning → ban |
| `crowdsecurity/sshd` | `/var/log/auth.log` | SSH brute force → ban |

```bash
cscli collections list            # verify installed collections
cscli hub update                  # refresh hub index
cscli hub upgrade                 # upgrade installed collections/parsers
```

### Bouncer config

`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` (written by installer):

```yaml
mode: nftables
update_frequency: 10s
api_url: http://localhost:8080/
api_key: <generated by installer via cscli bouncers add>
deny_action: DROP
supported_decisions_types:
  - ban
```

The bouncer creates a `CROWDSEC` nftables chain and an nftables set for banned IPs.
To verify after a ban:

```bash
nft list ruleset | grep -A5 CROWDSEC
```

### CrowdSec metrics in PostgreSQL

Vector scrapes `http://host.docker.internal:6060/metrics` (the CrowdSec Prometheus
endpoint, reachable via the `extra_hosts` entry added to the vector container) every
60s and writes the results into the `metrics` PostgreSQL table alongside node-exporter
and cadvisor data.

Useful queries:

```sql
-- Active ban count
SELECT value FROM metric_samples
WHERE name = 'cs_active_decisions' ORDER BY timestamp DESC LIMIT 1;

-- Parser hit rates
SELECT name, value FROM metric_samples
WHERE name LIKE 'cs_parser_%' ORDER BY timestamp DESC LIMIT 20;
```

### Manual operations

```bash
# View alerts (what triggered, from where)
cscli alerts list
cscli alerts inspect <id>

# View current bans
cscli decisions list

# Manual ban (bypass scenarios — instant)
cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual: port scan"

# Manual unban
cscli decisions delete --ip 1.2.3.4

# Check if a specific IP has a decision
cscli decisions list --ip 1.2.3.4

# Hub maintenance
cscli hub update && cscli hub upgrade

# Reload acquisitions config (after editing /etc/crowdsec/acquis.d/)
sudo systemctl reload crowdsec
```

---

## Telemetry: Vector → PostgreSQL

> This section is authoritative for how logs and metrics are stored.

For a single node with fewer than ~50 containers, telemetry is kept in plain PostgreSQL.
**Vector** is the single collector (`monitoring/vector/vector.yaml`, mounted read-only):

- **Container logs** — `docker_logs` source reads every container's stdout/stderr,
  attaching `container_name`, `image`, `stream`, `message`, `timestamp`. A `remap`
  transform derives `severity` from the message (`JSON level/severity`, then `logfmt
  level=`), defaulting to `unknown`.
- **Host + container metrics** — `prometheus_scrape` scrapes:
  - `node-exporter:9100` (host metrics)
  - `cadvisor:8080` (container metrics)
  - `speedtest:9798` (network speed)
  - `host.docker.internal:6060` (CrowdSec metrics — requires `extra_hosts` on the
    vector service, already added in `docker-compose.yml`)

Both are written by Vector's native **`postgres` sink** into the `monitoring` database
on the shared `core` Postgres server (`core-db-1:5432`).

**Vector 0.57+ note:** `${VAR}` interpolation is opt-in; the `vector` service sets
`VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` so the sink endpoint reads
`MONITORING_DB_PASSWORD` from the environment.

### Schema (`monitoring/scripts/schema.sql`)

Applied by the `initial-config` service (provisions `monitoring` DB/role, then runs
the schema so Vector can INSERT):

- **`logs`** — `timestamp timestamptz`, `container text`, `severity text`, `message text`
  (all `NOT NULL`), plus nullable `stream`, `image`, `labels jsonb`. Indexed on
  `timestamp`, `(container, timestamp)`, and `severity`.
- **`metrics`** — columns mirror Vector's metric-event JSON: `timestamp`, `name`,
  `namespace`, `tags jsonb`, `kind`, `interval_ms`, and one of
  `counter`/`gauge`/`set`/`distribution`/`aggregated_histogram`/`aggregated_summary`/`sketch`
  as `jsonb`. Indexed on `(name, timestamp)`, `timestamp`, and GIN on `tags`. The
  `metric_samples` view flattens counter/gauge to a numeric value.

### Retention

Plain tables grow unbounded — prune on a schedule (host cron or systemd timer):

```sql
DELETE FROM logs    WHERE timestamp < now() - interval '14 days';
DELETE FROM metrics WHERE timestamp < now() - interval '14 days';
```

If cadvisor volume is too high, raise `scrape_interval_secs`, trim with
`--disable_metrics`, or add a Vector `filter` before `pg_metrics`.

### Querying

```sql
SELECT container, severity, left(message, 80)
FROM logs WHERE severity IN ('error','critical','fatal')
ORDER BY timestamp DESC LIMIT 20;

SELECT name, value FROM metric_samples
WHERE name LIKE 'node_%' ORDER BY timestamp DESC LIMIT 20;

-- CrowdSec ban count
SELECT value FROM metric_samples
WHERE name = 'cs_active_decisions' ORDER BY timestamp DESC LIMIT 1;
```

---

## Alternatives Considered

| Option | Verdict | Reason |
|---|---|---|
| **Fail2ban** | Rejected | Superseded by CrowdSec — no structured log parsing, no LAPI, no community scenarios; expiry + persistence work but CrowdSec covers those and more |
| **Suricata inline IPS (NFQUEUE)** | Deferred | Suricata blocks itself, but fiddlier kernel plumbing; revisit if sub-second inline drops are needed |
| **Zeek** | Not needed | Excellent network analysis but heavier and detection-focused; overkill for block-oriented goal |
| **OPNsense / pfSense** | Out of scope | Gateway appliance, not a service on this single node |
| **CrowdSec console** | Skipped | Free tier exists but not required; `cscli` covers all operations locally |

---

# Analysing TLS & WireGuard-delivered traffic via Traefik logs

Companion to the Suricata and CrowdSec sections above.

Suricata goes blind in exactly two places on this stack:

1. **TLS** is terminated at **Traefik** — on `eth0` the HTTPS body is ciphertext.
2. **WireGuard** (Gerbil/Newt tunnels, `51820`/`21820` udp) — on `eth0` the
   tunnelled traffic is ciphertext.

**Traefik is the point where both become plaintext.** Its JSON access log is therefore
the sensor for the application layer that Suricata can't read. CrowdSec's
`crowdsecurity/traefik` collection parses this log automatically (see acquisitions above).
This section shows additional manual analysis you can run on the same file.

---

## T1. What Traefik logs can and cannot tell you

| Question | Answered by Traefik logs? | Field(s) |
|---|---|---|
| What **TLS version / cipher** did each client negotiate? | ✅ yes | `TLSVersion`, `TLSCipher` |
| Which **SNI / host** was requested? | ✅ yes | `RequestHost` |
| **Real external client IP** (for correlation with Suricata `eth0`) | ✅ yes | `ClientHost` |
| Which **tunnelled resource** (behind Newt/WireGuard) was hit, with status & latency? | ✅ yes | `ServiceName`, `ServiceURL`, `DownstreamStatus`, `Duration` |
| HTTP method / path / UA / status | ✅ yes | `RequestMethod`, `RequestPath`, `request_User-Agent`, `DownstreamStatus` |
| WireGuard **protocol** metrics (handshakes, per-peer bytes) | ❌ no | → use `wg show` on Gerbil (§T5) |

`ClientHost` (Traefik) ↔ `src_ip` (Suricata) is the join key that lets CrowdSec or a
Grafana panel correlate the same offender seen at two layers.

---

## T2. Immediate analysis with `jq` (no extra infra)

```bash
LOG=<path-to-core>/pangolin/traefik/logs/access.log

# TLS version distribution
jq -r 'select(.TLSVersion!=null) | .TLSVersion' "$LOG" | sort | uniq -c | sort -rn

# Weak TLS offenders (< TLS 1.2)
jq -r 'select(.TLSVersion!=null and (.TLSVersion < "1.2"))
       | [.StartUTC,.ClientHost,.RequestHost,.TLSVersion,.TLSCipher] | @tsv' "$LOG"

# Which backends/resources used, how often, average latency (ms)
jq -r 'select(.ServiceName!=null)
       | [.ServiceName,.DownstreamStatus,(.Duration/1000000|floor)] | @tsv' "$LOG" \
  | awk '{c[$1]++; s[$1]+=$3} END{for(k in c) printf "%-30s req=%-6d avg_ms=%d\n",k,c[k],s[k]/c[k]}' \
  | sort -k2 -t= -rn

# 4xx/5xx by client IP — probing / brute force (correlate with CrowdSec alerts)
jq -r 'select(.DownstreamStatus>=400)
       | [.ClientHost,.DownstreamStatus,.RequestHost,.RequestPath] | @tsv' "$LOG" \
  | sort | uniq -c | sort -rn | head -30
```

---

## T3. How this fits the three sensors

| Layer | Sensor | Sees |
|---|---|---|
| L3/L4 edge, all ports, pre-NAT | **Suricata on `eth0`** | real client IP, scans, TLS handshake metadata (JA3/SNI), WireGuard *packets* |
| L7 after TLS termination & tunnel delivery | **Traefik JSON access log** | TLS version/cipher, host/path/UA/status, per-resource tunnel traffic |
| WireGuard transport | **Gerbil `wg show` / exporter** | handshakes, per-peer bytes, endpoints |

All three feed the same destination: **Vector → PostgreSQL** for analysis, and
**CrowdSec** for banning (`eve.json` via suricata collection + `access.log` via traefik
collection). `ClientHost` ↔ `src_ip` is the join key.

---

## T4. WireGuard transport metrics — from Gerbil

For handshakes, per-peer transfer, and endpoints, read the WireGuard interface on Gerbil:

```bash
# live peer table: endpoints, last handshake, rx/tx bytes
docker compose -f core/docker-compose.yml exec gerbil wg show
```

To bring this into PostgreSQL dashboards, run a WireGuard exporter in Gerbil's network
namespace:

```yaml
# add to core/docker-compose.yml
  wg-exporter:
    image: mindflavor/prometheus-wireguard-exporter:latest
    restart: unless-stopped
    network_mode: service:gerbil     # share Gerbil's netns → sees wg0
    cap_add: [NET_ADMIN]
    command: ["-n", "/etc/wireguard/wg0.conf", "-r"]
```

Then add a scrape entry in `monitoring/vector/vector.yaml` alongside the other exporters.
Alert on stale handshakes (> 300s) to catch dead tunnels.
