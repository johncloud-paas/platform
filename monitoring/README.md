# Monitoring, Intrusion Detection & Blocking

Design notes and a step-by-step tutorial for **host log monitoring**, **malicious-activity
detection via customizable policies**, and **automatic IP blocking** on this node — built
entirely around **Fail2ban** running on the host (no Docker involved for the security layer).

## Context & Requirements

- **Environment:** single-node Ubuntu, **rootless** Docker Compose (not Swarm, not Kubernetes).
- **Existing stack:** Pangolin (`fosrl/pangolin`) + Gerbil + Newt tunneling, Traefik reverse
  proxy, GeoIP (MaxMind GeoLite2), docker-socket-proxy, Dockhand. Traefik access logs land in
  the core stack's log directory (`$TRAEFIK_LOG_DIR/access.log`, JSON).
- **Goals:**
  1. **Monitor all logs** on the host — system logs, SSH, the Traefik access log, **and every
     Docker container's stdout/stderr**.
  2. **Detect malicious activity** through **customizable policies** (Fail2ban jails + filters).
  3. **Block offenders automatically** (and manually), at the host firewall.
- **Hard constraint:** fully **free and open source**. No commercial tier.

> **Why Fail2ban only?** This node is log-rich (SSH, Traefik, and every container writes
> structured logs) and all ingress lands on **host ports** published by Gerbil (80/443/51820).
> A log-driven banner is therefore sufficient and far lighter than a packet IDS. Suricata,
> Snort, and CrowdSec have all been **removed** — see [Alternatives Considered](#alternatives-considered).

---

## Decision Summary

| Decision | Choice | Date |
|---|---|---|
| Blocker | **Fail2ban** (native apt, systemd service) | 2026-11-16 |
| Container-log intake | **journald** (rootless Docker `log-driver: journald`) | 2026-11-16 |
| Other log sources | Traefik `access.log` (JSON) + `/var/log/auth.log` (sshd) | 2026-11-16 |
| Firewall backend | **nftables** (`banaction = nftables-multiport`); ufw / firewalld supported | 2026-11-16 |
| Blocking posture | **Automatic** — jails ban on threshold; manual via `fail2ban-client` | 2026-11-16 |
| Telemetry store | **Vector → PostgreSQL** (logs + metrics, no TimescaleDB) | 2026-11-04 |
| Removed | **Suricata**, **Snort**, **CrowdSec** — replaced by Fail2ban | 2026-11-16 |

---

## Architecture

```
┌────────────────────── HOST LEVEL (systemd, as root) ─────────────────────┐
│                                                                          │
│  LOG SOURCES                                                             │
│   sshd ─────────────────► /var/log/auth.log  +  journald                │
│   rootless dockerd ─────► journald   (log-driver: journald)             │
│     every container's stdout/stderr, tagged CONTAINER_NAME / _TAG       │
│   Traefik (core stack) ─► $TRAEFIK_LOG_DIR/access.log   (JSON)          │
│                                   │                                      │
│                                   ▼                                      │
│  fail2ban.service                                                       │
│   reads:  backend=systemd (journald)  +  logpath (access.log)          │
│   filters (/etc/fail2ban/filter.d/*.conf)  = detection regex           │
│   jails   (/etc/fail2ban/jail.local)       = findtime / maxretry       │
│     [sshd]            SSH brute force        → ban                      │
│     [traefik-4xx]     4xx probing / scans    → ban                      │
│     [traefik-botsearch] bad bots / exploits  → ban                     │
│     [docker-apps]     app auth failures      → ban                      │
│     [recidive]        repeat offenders       → long ban                 │
│                                   │                                      │
│                                   ▼  banaction (+ jsonlog action)        │
│  FIREWALL  (nftables | ufw | firewalld)                                 │
│   adds/removes a DROP rule for the offending source IP                  │
│   jsonlog action → $JOHNCLOUD_ROOT/security/fail2ban-events.jsonl       │
│                                   │                                      │
│  Vector (rootless monitoring stack) — observability, NOT blocking       │
│   docker_logs + traefik access.log → PostgreSQL logs                    │
│   prometheus_scrape    → PostgreSQL metrics                             │
│   file (events.jsonl)  → PostgreSQL security_events  ◄──────────────────┤
│        trigger: security_events.id → logs.linked_event (ban ↔ lines)    │
└──────────────────────────────────────────────────────────────────────────┘
```

**Division of labour:**
- **Log sources** — journald (sshd + every container), the Traefik `access.log`, and
  `/var/log/auth.log`. Nothing sniffs packets; everything is read from logs.
- **Filters** — regular expressions that recognise a single failure/abuse line and extract the
  source IP (`<HOST>`).
- **Jails** — stateful counters: *N* matches from one IP within `findtime` → ban for `bantime`.
- **Action (`banaction`)** — writes a DROP rule into the host firewall (nftables by default).
- **`recidive`** — watches Fail2ban's own log and applies long bans to IPs that keep coming back.

**Manual operations:**
```bash
fail2ban-client set <jail> banip 1.2.3.4      # ban now
fail2ban-client set <jail> unbanip 1.2.3.4    # lift a ban
fail2ban-client status                        # list active jails
fail2ban-client status sshd                   # counters + banned IPs for one jail
```

---

## Host Setup: Step-by-Step

This installs the complete host security layer (Fail2ban) on a fresh — or previously
Suricata/CrowdSec — Ubuntu node. The monitoring Docker stack (Vector, cadvisor, …) is a
separate step afterwards and does **not** depend on it.

### Prerequisites

- Ubuntu 22.04+ (or Debian 12+) with root access (`sudo`).
- The `monitoring/` repo directory present on the host.
- Rootless Docker already set up (the containers whose logs we want to read).
- `gettext-base` for `envsubst` (`sudo apt-get install -y gettext-base`).

### Step 0 — Set required `.env` variables

Copy `monitoring/sample.env` → `monitoring/.env` and fill in at minimum:

```bash
JOHNCLOUD_ROOT=/path/to/paas/data   # writable directory for persistent state
HOST=yourdomain.tld
PUBLIC_IP_ADDRESS=1.2.3.4           # your server's public IPv4 (never banned)
TRAEFIK_NETWORK=traefik-proxy
TRAEFIK_LOG_DIR=/path/to/core/pangolin/traefik/logs   # holds access.log

# Fail2ban tunables (optional — sensible defaults shown)
F2B_BANTIME=1h                      # how long a ban lasts
F2B_FINDTIME=10m                    # window in which maxretry failures must occur
F2B_MAXRETRY=5                      # failures before a ban
F2B_IGNOREIP=127.0.0.1/8 ::1        # extra never-ban space (RFC1918 added automatically)
```

> The old `SURICATA_UPLINK` / `SURICATA_BRIDGE_SUBNET` variables are **gone** — there is no
> packet sensor any more.

### Step 1 — Route rootless Docker container logs to journald

Run this **as the rootless Docker user** (not root), so Fail2ban can read every container's
output from a single, field-tagged stream instead of per-container JSON files.

```bash
# As the rootless user that owns the Docker daemon:
mkdir -p ~/.config/docker
# Merge into any existing daemon.json — do not clobber other keys.
cat > ~/.config/docker/daemon.json <<'JSON'
{
  "log-driver": "journald"
}
JSON

systemctl --user restart docker
```

Recreate the running containers so they adopt the new driver (the driver is fixed at container
create time):

```bash
./startstack.sh ./core <dev|prod>         # and any other stacks whose logs you want banned on
./startstack.sh ./monitoring <dev|prod>
```

Verify a container's logs now reach the journal, and — importantly — that **root** can see them:

```bash
# As the rootless user:
docker inspect -f '{{.HostConfig.LogConfig.Type}}' <container>   # expect: journald

# As root — Fail2ban runs as root and reads the system journal:
sudo journalctl CONTAINER_NAME=<container> -n 5
```

> **Rootless caveat.** The rootless `dockerd` runs as a *user* systemd unit, so its journal
> entries are attributed to that UID. On a default systemd they are merged into the **system
> journal** that root reads, so `sudo journalctl CONTAINER_NAME=…` shows them. If your host
> splits user journals and the command above returns nothing, use the **json-file fallback**
> in the [Fail2ban Reference](#reading-docker-logs) instead of journald.

### Step 2 — Run the installer

```bash
cd /path/to/platform/monitoring
sudo bash scripts/install-host-security.sh
```

The script is **idempotent** — safe to re-run after changing `.env` or editing the templates.
It performs:

1. **Fail2ban:**
   - `apt-get install -y fail2ban nftables`
   - Renders `fail2ban/jail.template.local` → `/etc/fail2ban/jail.local`
     (`envsubst` substitutes `$PUBLIC_IP_ADDRESS`, `$TRAEFIK_LOG_DIR`, and the `F2B_*` tunables)
   - Installs the custom filters `fail2ban/filter.d/*.conf` → `/etc/fail2ban/filter.d/`
   - `systemctl enable --now fail2ban` and `fail2ban-client reload`
2. **Legacy IDS cleanup:** stops, disables, and purges `suricata`, `suricata-update`,
   `crowdsec`, `crowdsec-firewall-bouncer*`, and any `snort`; removes their configs, systemd
   drop-ins, cron jobs, logrotate files, and any leftover nftables `CROWDSEC` chain.

### Step 3 — Confirm the firewall backend

Fail2ban needs a firewall to install bans into. The default here is **nftables**
(`banaction = nftables-multiport`). If you run **ufw** or **firewalld** instead, change
`banaction` in `.env`/`jail.local` to match — see
[Firewall advice](#firewall-advice-keep-nftables--ufw--firewalld) below. **Do not run more than
one firewall manager at once.**

### Step 4 — Remove a legacy host IDS (upgrades only)

Step 2 does this automatically. If you are cleaning up a node by hand, the equivalent is:

```bash
sudo systemctl disable --now suricata suricata-offloads crowdsec crowdsec-firewall-bouncer 2>/dev/null || true
sudo apt-get purge -y suricata suricata-update crowdsec crowdsec-firewall-bouncer-nftables snort 2>/dev/null || true
sudo rm -rf /etc/suricata /etc/crowdsec /etc/cron.daily/suricata-update \
            /etc/systemd/system/suricata.service.d /etc/systemd/system/suricata-offloads.service
sudo nft delete chain ip filter CROWDSEC 2>/dev/null || true   # if the bouncer left one
sudo systemctl daemon-reload
```

### Step 5 — Verify Fail2ban

```bash
# Service running and jails loaded
systemctl status fail2ban
sudo fail2ban-client status
# expect: Jail list: sshd, traefik-4xx, traefik-botsearch, docker-apps, recidive

# Counters + currently banned IPs for one jail
sudo fail2ban-client status sshd

# Dry-run a filter against the live journal/log (no ban applied)
sudo fail2ban-regex systemd-journal /etc/fail2ban/filter.d/sshd.conf

# Manual ban → confirm it lands in the firewall → unban
sudo fail2ban-client set sshd banip 203.0.113.1
sudo nft list ruleset | grep -E 'f2b|203.0.113.1'     # nftables backend
# (ufw: `sudo ufw status | grep 203.0.113.1`;  firewalld: `sudo firewall-cmd --list-rich-rules`)
sudo fail2ban-client set sshd unbanip 203.0.113.1
```

### Step 6 — Start the monitoring stack

Unchanged by the security layer. Vector keeps shipping logs + metrics to PostgreSQL via the
Docker socket:

```bash
./startstack.sh ./monitoring
```

`setup_before_up.sh` checks that `fail2ban.service` is active and warns if not, but does not
fail — the monitoring stack does not depend on it.

### Step 7 — Post-install checklist

- [ ] `~/.config/docker/daemon.json` has `"log-driver": "journald"`; `sudo journalctl
      CONTAINER_NAME=<any> -n 5` shows lines
- [ ] `sudo fail2ban-client status` lists all expected jails
- [ ] `TRAEFIK_LOG_DIR/access.log` exists and the `traefik-*` jails show a non-zero file list
      (`sudo fail2ban-client status traefik-4xx`)
- [ ] Manual ban → appears in the firewall → unban (Step 5)
- [ ] A baseline firewall policy (default-deny ingress) is in place — see below
- [ ] (Optional) Tune `F2B_*` thresholds and add app-specific jails

### Re-running after changes

```bash
# After editing fail2ban/jail.template.local, any fail2ban/filter.d/*.conf, or an F2B_* / IP var
sudo bash monitoring/scripts/install-host-security.sh
# or, if you only edited the deployed files directly:
sudo fail2ban-client reload
```

---

## Fail2ban Reference

### Directory layout

```
monitoring/fail2ban/                 (in the repo — tracked)
├── jail.template.local              # jail config template; $VARS substituted at install
└── filter.d/
    ├── traefik-access.conf          # JSON access-log abuse (4xx probing, bad bots)
    └── docker-apps.conf             # generic container auth-failure filter

/etc/fail2ban/                       (deployed by install-host-security.sh)
├── jail.local                       # rendered from jail.template.local
├── filter.d/traefik-access.conf
├── filter.d/docker-apps.conf
└── filter.d/*.conf                  # stock filters shipped by the fail2ban package (sshd, recidive, …)

/var/log/fail2ban.log                # Fail2ban's own log (watched by the recidive jail)
```

### `jail.local` structure

`[DEFAULT]` sets the shared policy; each `[jail]` enables a filter against a log source.

```ini
[DEFAULT]
bantime  = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}
maxretry = ${F2B_MAXRETRY}
# Never ban ourselves or local networks (mirrors the former HOME_NET):
ignoreip = 127.0.0.1/8 ::1 ${PUBLIC_IP_ADDRESS} 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ${F2B_IGNOREIP}
backend  = systemd                 # read the journal by default
banaction        = nftables-multiport
banaction_allports = nftables-allports

# --- Host SSH -------------------------------------------------------------
[sshd]
enabled = true
backend = systemd                  # journald; set backend=auto + logpath=/var/log/auth.log to tail the file

# --- Traefik access log (HTTP abuse) -------------------------------------
[traefik-4xx]
enabled  = true
backend  = auto
logpath  = ${TRAEFIK_LOG_DIR}/access.log
filter   = traefik-access[mode=4xx]
findtime = 2m
maxretry = 20                      # 20 x 4xx in 2 min = probing

[traefik-botsearch]
enabled  = true
backend  = auto
logpath  = ${TRAEFIK_LOG_DIR}/access.log
filter   = traefik-access[mode=bot]
maxretry = 2

# --- All Docker containers (via journald) --------------------------------
[docker-apps]
enabled      = true
backend      = systemd
journalmatch = _SYSTEMD_UNIT=docker.service + CONTAINER_NAME
filter       = docker-apps

# --- Repeat offenders ----------------------------------------------------
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 5
```

### Filters

A filter extracts the source IP with the `<HOST>` token. Fail2ban ships `sshd` and `recidive`;
this repo adds two.

**`filter.d/traefik-access.conf`** — Traefik writes one JSON object per request. The jail
selects behaviour with `filter = traefik-access[mode=4xx|bot]`; the filter uses the stock
Fail2ban `<mdre-<mode>>` nested-tag pattern (same mechanism as `sshd.conf`) so each mode maps
to its own regex:

```ini
[Definition]
# {"ClientHost":"1.2.3.4", ... ,"DownstreamStatus":404, ... ,"request_User-Agent":"...","StartUTC":"..."}
mode = 4xx
mdre-4xx = ^.*"ClientHost":"<HOST>".*"DownstreamStatus":4\d\d.*$
mdre-bot = ^.*"ClientHost":"<HOST>".*"request_User-Agent":"[^"]*(?:sqlmap|nikto|nmap|masscan|zgrab|nuclei)[^"]*".*$
failregex = <mdre-<mode>>
datepattern = "StartUTC":"%%Y-%%m-%%dT%%H:%%M:%%S
```

> `fail2ban-regex` is the way to iterate on these (quote the `[mode=...]` suffix so your shell
> doesn't treat it as a glob):
> `sudo fail2ban-regex $TRAEFIK_LOG_DIR/access.log '/etc/fail2ban/filter.d/traefik-access.conf[mode=4xx]'`.

**`filter.d/docker-apps.conf`** — a generic auth-failure catch for container logs read from
journald (the message is the plain application line, no envelope):

```ini
[Definition]
failregex = (authentication failure|invalid (login|credentials)|failed login|403 Forbidden).*(from|ip[=:])\s*<HOST>
            <HOST>.*(authentication failure|invalid (login|credentials)|failed login)
```

### Reading Docker logs

**Primary — journald (recommended).** With the rootless daemon set to `log-driver: journald`
(Step 1), every container's stdout/stderr is one tagged stream. The `[docker-apps]` jail reads
it with `backend = systemd` and a `journalmatch` on `CONTAINER_NAME`, so **one jail covers all
containers**. Tighten to specific apps with e.g. `journalmatch = CONTAINER_NAME=authentik-server`.

**Fallback — tail the json-file logs.** If journald entries from the rootless daemon are not
visible to root, keep the default `json-file` driver and point a jail at the per-container files.
Under rootless Docker they live at:

```
${XDG_DATA_HOME:-$HOME/.local/share}/docker/containers/*/*-json.log
```

Each line is wrapped in Docker's JSON envelope
(`{"log":"<message>\n","stream":"stdout","time":"…"}`), so the filter must unwrap it first with
`prefregex` before applying the real pattern:

```ini
[Definition]
prefregex = ^\s*\{"log":"<F-CONTENT>.+</F-CONTENT>","stream":"std(out|err)".*\}$
failregex = (authentication failure|invalid (login|credentials)|failed login).*<HOST>
```

Jail (fallback form):

```ini
[docker-apps]
enabled  = true
backend  = auto
logpath  = /home/<rootless-user>/.local/share/docker/containers/*/*-json.log
filter   = docker-apps
```

> Note these files are owned by the unprivileged rootless user; Fail2ban (root) can read them,
> but the json-file driver rotates per container — journald is cleaner for a whole-host view.

### ignoreip / whitelist

`ignoreip` in `[DEFAULT]` is the single whitelist and mirrors the old `HOME_NET`: `127.0.0.1/8`,
`::1`, your `${PUBLIC_IP_ADDRESS}`, the RFC1918 ranges, plus anything you add in `${F2B_IGNOREIP}`
(e.g. Tailscale/WireGuard CIDRs). IPs here are **never** banned, regardless of what they trip.

### Manual operations

```bash
sudo fail2ban-client status                      # all jails
sudo fail2ban-client status <jail>               # counters + banned IPs
sudo fail2ban-client set <jail> banip 1.2.3.4    # ban now (bypass thresholds)
sudo fail2ban-client set <jail> unbanip 1.2.3.4  # unban
sudo fail2ban-client reload                       # re-read config after edits
sudo fail2ban-client unban --all                  # clear every ban
```

---

## Firewall advice: keep nftables / ufw / firewalld?

**Yes — keep a real firewall even with Fail2ban well configured.** The two do different jobs:

- **Fail2ban is a *reactive* layer.** It bans an IP *after* it has already shown up in the logs
  as abusive. It is **not** a baseline ingress policy and does nothing about traffic to ports
  you never meant to expose.
- **A stateful firewall is your *baseline*.** It enforces default-deny: only 22 (from your admin
  networks), 80/443, and 51820/udp (WireGuard) should be reachable from the Internet; everything
  else is dropped before Fail2ban is ever consulted.

Run them together, with Fail2ban installing its dynamic bans *into* that firewall.

**Pick exactly one firewall manager.** Running raw nftables **and** ufw **and** firewalld at
once produces conflicting, hard-to-debug rule sets. Match Fail2ban's `banaction` to whichever
you keep:

| Firewall | Recommended for this stack? | Fail2ban `banaction` |
|---|---|---|
| **nftables** (direct) | **Yes** — Docker/Gerbil already manipulate nftables, so staying native avoids a translation layer | `nftables-multiport` / `nftables-allports` |
| **ufw** (frontend over nftables) | Fine if you prefer a simple CLI | `ufw` |
| **firewalld** | Fine on RHEL-family or if already standardised on it | `firewallcmd-rich-rules` or `firewallcmd-ipset` |

**Docker interaction caveat.** Docker normally inserts its own DNAT/FORWARD rules that can
**bypass INPUT-based firewalls** for *published container ports*. On this stack that mostly does
not bite you: Gerbil publishes the ingress ports (80/443/51820) on the **host**, so banning a
source IP at INPUT blocks it. **Rootless** Docker is also less prone to the classic "ufw bypass"
because it publishes ports through rootlesskit rather than punching raw DNAT holes. If you ever
expose a container port directly and need bans to apply to *forwarded* traffic, ban in the
`DOCKER-USER` chain (iptables) or an early prerouting drop set (nftables).

**Bottom line:** keep **nftables** enabled with a default-deny ingress policy (allow 22 from
admin nets; 80/443/51820 from anywhere), and let Fail2ban add/remove dynamic drops via
`banaction = nftables-multiport`. Don't layer multiple firewall managers.

---

## Telemetry: Vector → PostgreSQL

> This section is authoritative for how logs and metrics are stored. It is independent of the
> Fail2ban security layer above — Vector is for **observability**, not blocking.

For a single node with fewer than ~50 containers, telemetry is kept in plain PostgreSQL.
**Vector** is the single collector (`monitoring/vector/vector.yaml`, mounted read-only):

- **Container logs** — the `docker_logs` source reads every container's stdout/stderr over the
  Docker socket (independent of the journald change above, which is for Fail2ban), attaching
  `container_name`, `image`, `stream`, `message`, `timestamp`. A `remap` transform derives
  `severity` (defaulting to `unknown`) and best-effort extracts `client_ip` from the message.
- **Traefik access log** — a `file` source tails `/var/log/traefik/access.log` (the host
  `$JOHNCLOUD_ROOT/traefik/logs`, mounted read-only); a `remap` maps each JSON line to the `logs`
  columns with `container = traefik`, `client_ip = ClientHost`, and `severity` from the HTTP
  status. Ingested so bans from the `traefik-4xx`/`traefik-botsearch` jails have log rows to link
  to (see **Linking bans to the logs that triggered them**).
- **Host + container metrics** — `prometheus_scrape` scrapes `node-exporter:9100`,
  `cadvisor:8080`, and `speedtest:9798`.
- **Security events** — a `file` source tails `$JOHNCLOUD_ROOT/security/fail2ban-events.jsonl`
  (mounted read-only as `/var/log/security/`), where the host Fail2ban `jsonlog` action appends
  one JSON line per ban/unban. A `remap` parses the line back into columns and stamps a
  `uuid_v4()` `id` (so `logs.linked_event` can point at it).

Both log sources are written by Vector's native **`postgres` sink** (`docker_logs` and
`traefik_access` share the `logs` sink) into the `monitoring` database on the shared `core`
Postgres server (`core-db-1:5432`).

> **Why there is no SSH-log source.** Linking `sshd` bans to their raw log lines would mean
> Vector reading the host journal (or `/var/log/auth.log`). Both are mode `0640` owned by
> `root`/`syslog`, and Vector runs **rootless** — those owners/groups aren't mapped into its user
> namespace, so the files are unreadable regardless of group membership (the same reason Fail2ban
> reads the journal **as root on the host**, not via Vector). This costs only the raw sshd *line
> text*: an SSH ban's **client IP, geo/ASN, and failure counts are still in `security_events` /
> `security_events_geo`**, because those come from the Fail2ban `jsonlog` action, not Vector.

**Where the security events come from.** Fail2ban runs on the host as root; Vector runs rootless
and cannot cleanly read the host journal, so the event is emitted by Fail2ban rather than scraped
by Vector. The log-only `jsonlog` action (`fail2ban/action.d/jsonlog.template.conf`, rendered by
`install-host-security.sh`) is attached in `[DEFAULT] action` **alongside** the nftables banaction,
so every jail's ban/unban also appends a structured line. Because the nftables drop-set add/remove
*is* the ban/unban, this captures the firewall state changes too — nftables itself is not logged
separately.

**Vector 0.57+ note:** `${VAR}` interpolation is opt-in; the `vector` service sets
`VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` so the sink reads `MONITORING_DB_PASSWORD`
from the environment.

### Schema (`monitoring/scripts/schema.sql`)

Applied by the `initial-config` service (provisions the `monitoring` DB/role, then runs the
schema so Vector can INSERT):

- **`logs`** — `timestamp timestamptz`, `container text`, `severity text`, `message text`
  (all `NOT NULL`), plus nullable `stream`, `image`, `labels jsonb`, `client_ip text` (remote
  client, best-effort from the message / `ClientHost`), and `linked_event uuid` (the
  `security_events.id` whose ban this line triggered — see below). Indexed on `timestamp`,
  `(container, timestamp)`, `severity`, `(client_ip, timestamp)`, and `linked_event`. The
  `client_ip`/`linked_event` columns are added via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
  so existing databases gain them on re-apply (plain `CREATE TABLE IF NOT EXISTS` skips an
  existing table).
- **`metrics`** — mirrors Vector's metric-event JSON: `timestamp`, `name`, `namespace`,
  `tags jsonb`, `kind`, `interval_ms`, and one of
  `counter`/`gauge`/`set`/`distribution`/`aggregated_histogram`/`aggregated_summary`/`sketch`.
  The `metric_samples` view flattens counter/gauge to a numeric value.
- **`security_events`** — Fail2ban ban/unban activity: `timestamp`, `action` (`ban`/`unban`),
  `jail`, `ip` (all `NOT NULL`), plus nullable `failures`, `family`, `port`, `protocol`,
  `bantime` (populated on ban), and `id uuid` (Vector-emitted `uuid_v4()`, the surrogate key
  `logs.linked_event` references). Indexed on `timestamp`, `ip`, `(jail, timestamp)`, and a
  unique index on `id`.
- **`geoip_lookup`** — geo/ASN per banned IP (`ip` PK, `country_code`, `country_name`, `city`,
  `latitude`, `longitude`, `asn`, `asn_org`, `resolved_at`). **Not** written by Vector — the
  `geoip-sync` service fills it from the GeoLite2 mmdb (see below). The `security_events_geo`
  view left-joins `security_events` to it by `ip` for dashboards.

### Linking bans to the logs that triggered them

Fail2ban records only the offender IP/jail/time, never which log lines matched. The link is
therefore **reconstructed in the database**: an `AFTER INSERT` trigger on `security_events`
(`link_security_event()`) back-fills `logs.linked_event` for the log rows that share the ban's
IP and fall within the jail's `findtime` window before the ban (`traefik-4xx` 120 s, others
600 s — mirroring `jail.template.local`). The failing lines are inserted seconds before the ban,
so they are already present when the trigger fires.

This is a pure join between two tables already in the same Postgres, so it runs as a trigger —
**no Python loader** (unlike `geoip-sync`, which stays Python only because it reads an external
mmdb file). VRL can't do it either (no runtime/DB lookup). Query the result through the
**`security_event_log_lines`** view (each ban joined to its log lines), or directly:
`SELECT * FROM logs WHERE linked_event = '<event-id>'`.

Properties and limits:

- **Heuristic, not exact** — 1-second ban-timestamp granularity and per-jail `findtime` windows;
  container apps expose the real client IP only if they log `X-Forwarded-For` (otherwise the
  `message LIKE '%ip%'` fallback is used). Expect occasional over-matching.
- **One ban per line** — a single `linked_event` column (first-ban-wins via `linked_event IS
  NULL`); it does not model a line feeding two overlapping-window bans. A join table would, if
  that ever matters.
- **`recidive` and unbans are skipped** (recidive bans off Fail2ban's own log, not app lines),
  and only rows written after the migration carry `id`/`linked_event`.
- **`sshd` bans have no linked lines** — the raw sshd logs aren't ingested (see *Why there is no
  SSH-log source* above). The ban, its client IP and geo are still in `security_events` /
  `security_events_geo`; only the per-line text is absent. In practice linking is useful for
  `traefik-*` and `docker-apps` (application) bans.

### Retention

```sql
DELETE FROM logs            WHERE timestamp < now() - interval '14 days';
DELETE FROM metrics         WHERE timestamp < now() - interval '14 days';
DELETE FROM security_events WHERE timestamp < now() - interval '90 days';
```

### Querying

```sql
SELECT container, severity, left(message, 80)
FROM logs WHERE severity IN ('error','critical','fatal')
ORDER BY timestamp DESC LIMIT 20;

SELECT name, value FROM metric_samples
WHERE name LIKE 'node_%' ORDER BY timestamp DESC LIMIT 20;
```

Recent bans, and the top offenders:

```sql
SELECT timestamp, action, jail, ip FROM security_events
ORDER BY timestamp DESC LIMIT 20;

SELECT ip, count(*) FILTER (WHERE action = 'ban') AS bans
FROM security_events GROUP BY ip ORDER BY bans DESC LIMIT 10;
```

To cross-reference a Fail2ban ban with application logs, search `logs` for the banned IP:

```sql
SELECT timestamp, container, message FROM logs
WHERE message LIKE '%1.2.3.4%' ORDER BY timestamp DESC LIMIT 50;
```

### Geolocating banned IPs

The `core` stack's `geoipupdate` service already downloads and refreshes (every 72 h) the MaxMind
**GeoLite2 City + ASN** databases into `$JOHNCLOUD_ROOT/traefik/GeoLite2/`. The monitoring stack's
**`geoip-sync`** service (`scripts/geoip-sync.py`, a `python:3.13-alpine` container) mounts that
directory read-only and, every `GEOIP_SYNC_INTERVAL` seconds (default 3600), resolves the distinct
IPs in `security_events` against those mmdb files and upserts a row per IP into `geoip_lookup`.

Why a keyed lookup table rather than inline enrichment or MaxMind's full block table: the set of
*banned* IPs is tiny, so this stays a small table with a trivial equality join, needs no `ip4r`
extension or CIDR-range index, and leaves the raw `security_events` log untouched. Because it
re-resolves every pass, geo tracks the 72 h mmdb refresh automatically — and historical IPs are
re-resolved too. (Vector itself cannot do this: VRL has no runtime HTTP/dynamic lookup, and its
enrichment tables are static, so geo lives in a separate loader.)

Query the enriched view directly:

```sql
SELECT timestamp, ip, jail, country_code, city, asn_org
FROM security_events_geo
WHERE action = 'ban' AND latitude IS NOT NULL
ORDER BY timestamp DESC LIMIT 20;

SELECT country_name, count(*) FILTER (WHERE action = 'ban') AS bans
FROM security_events_geo GROUP BY country_name ORDER BY bans DESC;
```

**Grafana Geomap panel** (on the PostgreSQL datasource reached through the PDC agent as
`monitoring_ro`): add a *Geomap* panel with a *Markers* layer, Location → *Coords* mapped to the
`latitude`/`longitude` fields, over:

```sql
SELECT latitude, longitude, ip, jail, country_code, city
FROM security_events_geo
WHERE action = 'ban' AND latitude IS NOT NULL AND $__timeFilter(timestamp);
```

`geoip_lookup` needs no retention sweep (it is keyed by `ip` and upserted in place); it shrinks
naturally if you prune old `security_events`, since the loader only resolves IPs still present there.

---

## Alternatives Considered

| Option | Verdict | Reason |
|---|---|---|
| **Suricata** | Removed | Packet IDS: needs `CAP_NET_RAW` on the uplink (awkward under rootless Docker), heavy ruleset upkeep, and most useful signal here is already in logs. Overkill for log-driven banning. |
| **Snort** | Not used | Same class as Suricata — a packet IDS/IPS. Not needed when all ingress is on host ports and the interesting evidence is in logs. |
| **CrowdSec** | Removed | Capable (LAPI, community scenarios, nftables bouncer) but heavier than needed for this single node; Fail2ban covers the log → ban path with far less moving parts. |
| **Fail2ban inline/IPS** | N/A | Fail2ban is reactive by design; pair it with a default-deny firewall (above) rather than an inline dropper. |
| **Commercial consoles** | Skipped | Free/OSS constraint; `fail2ban-client` covers all local operations. |
