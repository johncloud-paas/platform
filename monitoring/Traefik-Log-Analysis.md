# Analysing TLS & WireGuard-delivered traffic via Traefik logs

Companion to [`Monitoring.md`](./Monitoring.md) and [`Suricata-Setup.md`](./Suricata-Setup.md).

Suricata goes blind in exactly two places on this stack:

1. **TLS** is terminated at **Traefik** — on `eth0` the HTTPS body is ciphertext.
2. **WireGuard** (Gerbil/Newt tunnels, `51820`/`21820` udp) — on `eth0` the
   tunnelled traffic is ciphertext.

**Traefik is the point where both become plaintext.** Its JSON access log is
therefore the sensor for the application layer that Suricata can't read. This doc
shows what you can recover, and how to analyse it with the stack you *already*
run (VictoriaLogs + Fluent-bit + Grafana).

---

## 1. What Traefik logs can and cannot tell you

| Question | Answered by Traefik logs? | Field(s) |
|---|---|---|
| What **TLS version / cipher** did each client negotiate? | ✅ yes | `TLSVersion`, `TLSCipher` |
| Which **SNI / host** was requested? | ✅ yes | `RequestHost` |
| **Real external client IP** (for correlation with Suricata `eth0`) | ✅ yes | `ClientHost` |
| Which **tunnelled resource** (behind a Newt/WireGuard tunnel) was hit, with status & latency? | ✅ yes — this is the *application-layer view* of WireGuard traffic | `ServiceName`, `ServiceURL`, `DownstreamStatus`, `Duration` |
| HTTP method / path / UA / status | ✅ yes | `RequestMethod`, `RequestPath`, `request_User-Agent`, `DownstreamStatus` |
| WireGuard **protocol** metrics (handshakes, per-peer bytes, endpoints) | ❌ **no** — not an HTTP concept | → use `wg show` on Gerbil (§5) |

> **The WireGuard nuance, stated plainly:** you cannot analyse the WireGuard
> *protocol* from Traefik logs. What you *can* do is analyse the **traffic that
> arrived through a tunnel** — because once Gerbil/Newt decrypt it and Traefik
> routes it, every tunnelled request shows up in the access log as a
> `ServiceName`. So "WireGuard analysis via Traefik logs" = *per-resource,
> per-client, status & latency of tunnel-delivered traffic*. Protocol-level
> metrics come from `wg show` (§5).

Your log already captures the TLS fields — `core/traefik/static_config.yml` sets
`accessLog.format: json` and keeps all core fields by default (only headers are
filtered). Nothing to change there.

Host path of the log (from `core/docker-compose.yml`:
`./pangolin/traefik/logs:/var/log/traefik`):

```
core/pangolin/traefik/logs/access.log
```

---

## 2. Immediate analysis with `jq` (no infra needed)

Run these straight against the file. Good for spot checks and for verifying
fields before wiring the pipeline.

```bash
LOG=core/pangolin/traefik/logs/access.log

# --- TLS posture -----------------------------------------------------------

# TLS version distribution (spot any legacy 1.0/1.1 still negotiating)
jq -r 'select(.TLSVersion!=null) | .TLSVersion' "$LOG" | sort | uniq -c | sort -rn

# Cipher suites in use, per host
jq -r 'select(.TLSCipher!=null) | [.RequestHost,.TLSVersion,.TLSCipher] | @tsv' "$LOG" \
  | sort | uniq -c | sort -rn

# WEAK TLS offenders: anyone negotiating < TLS 1.2  (who, from where, to what)
jq -r 'select(.TLSVersion!=null and (.TLSVersion < "1.2"))
       | [.StartUTC,.ClientHost,.RequestHost,.TLSVersion,.TLSCipher] | @tsv' "$LOG"

# --- Tunnel-delivered application traffic (the "WireGuard" view) ------------

# Which backends/resources are being used, how often, and how slow (ns)
jq -r 'select(.ServiceName!=null)
       | [.ServiceName,.DownstreamStatus,(.Duration/1000000|floor)] | @tsv' "$LOG" \
  | awk '{c[$1]++; s[$1]+=$3} END{for(k in c) printf "%-30s req=%-6d avg_ms=%d\n",k,c[k],s[k]/c[k]}' \
  | sort -k2 -t= -rn

# --- Threat / abuse signals (correlate ClientHost with Suricata eth0) -------

# Top client IPs by request volume
jq -r '.ClientHost' "$LOG" | sort | uniq -c | sort -rn | head -20

# 4xx/5xx by client — probing / brute force / scanners
jq -r 'select(.DownstreamStatus>=400)
       | [.ClientHost,.DownstreamStatus,.RequestHost,.RequestPath] | @tsv' "$LOG" \
  | sort | uniq -c | sort -rn | head -30
```

`ClientHost` here is the **real external IP** (Gerbil publishes :443 and Traefik
shares its netns, so there's no extra proxy hop masking it). That makes it a
clean join key against Suricata `eve.json` `src_ip` from `eth0`.

---

## 3. Ship it into VictoriaLogs (your existing pipeline)

Your `monitoring/` stack already runs **VictoriaLogs** with **Fluent-bit** tailing
container logs. Traefik writes its access log to a **file** (not stdout), so
Fluent-bit isn't picking it up yet. Add one input + one output and a mount.

### 3a. Mount the Traefik log dir into Fluent-bit

In `monitoring/docker-compose.yml`, add to the `fluent-bit` service `volumes:`
(adjust the host path to wherever the repo lives on the server):

```yaml
      - /home/yann/repos/johncloud/platform/core/pangolin/traefik/logs:/var/log/traefik:ro
```

> Tip: promote it to a variable (e.g. `TRAEFIK_LOG_DIR`) in `sample.env` so it's
> not a hard-coded path, matching how the rest of the stack uses `$JOHNCLOUD_ROOT`.

### 3b. Add a tail input + Loki output (`monitoring/fluent-bit/fluent-bit.conf`)

```ini
[INPUT]
    Name              tail
    Tag               traefik.access
    Path              /var/log/traefik/access.log
    Parser            json
    Refresh_Interval  10
    DB                /tmp/fluent-bit-traefik.db

[OUTPUT]
    Name          loki
    Match         traefik.access
    Host          victorialogs
    Port          9428
    URI           /insert/loki/api/v1/push
    Labels        job=traefik
    Label_Keys    $RequestHost
    Line_Format   json
```

Notes:
- `Parser json` + the image's default `parsers.conf` parses each JSON line.
- Keep only **low-cardinality** fields as Loki stream labels (`RequestHost` is a
  bounded set of your domains). Do **not** label by `ClientHost`/`RequestPath` —
  high cardinality. They remain queryable as fields (§4 uses `unpack_json`).
- Don't route Traefik's TLS/client data to any cloud; it stays in local
  VictoriaLogs. (PDC only connects Grafana Cloud to your metrics — mind what you
  expose.)

Reload: `docker compose -f monitoring/docker-compose.yml restart fluent-bit`.

---

## 4. Query it — LogsQL (VictoriaLogs UI or Grafana)

VictoriaLogs web UI: `http://victorialogs:9428/select/vmui/` (put it behind
Pangolin, don't expose it raw). Or add the **VictoriaLogs datasource** in your
Grafana and build panels.

Because the record is ingested as a JSON line, use `unpack_json` to expose fields:

```logsql
# TLS version distribution, last 24h
_time:1d job:traefik | unpack_json | stats by (TLSVersion) count()

# Weak TLS (anything below 1.2) — audit + alert candidate
_time:7d job:traefik | unpack_json | filter TLSVersion:("1.0" OR "1.1")
  | stats by (ClientHost, RequestHost, TLSVersion) count()

# Cipher suite inventory per host
_time:1d job:traefik | unpack_json | stats by (RequestHost, TLSCipher) count()

# Tunnel-delivered resource usage (the "WireGuard app view")
_time:1d job:traefik | unpack_json | stats by (ServiceName) count()
  | sort by (count) desc

# Backend latency outliers (p99 by resource)
_time:1d job:traefik | unpack_json | stats by (ServiceName) quantile(0.99, Duration)

# Scanners / brute force: 4xx-5xx by client IP
_time:1d job:traefik | unpack_json | filter DownstreamStatus:>=400
  | stats by (ClientHost) count() | sort by (count) desc | limit 20
```

Grafana panel ideas (one dashboard, "Edge / TLS"):
- **Stat**: count of sub-TLS-1.2 handshakes (red if > 0).
- **Table**: top weak-TLS clients.
- **Pie**: TLS version & cipher mix.
- **Time series**: requests/s per `ServiceName` (tunnel traffic over time).
- **Table**: top 4xx/5xx client IPs → your manual-ban shortlist for Fail2ban.

You can turn the weak-TLS and 4xx/5xx queries into **vmalert** rules in your
existing VictoriaMetrics alerting (`monitoring/victoriametrics/alert.rules`).

---

## 5. Actual WireGuard (protocol) metrics — from Gerbil, not Traefik

For handshakes, per-peer transfer, and endpoints, read the WireGuard interface on
**Gerbil** (it holds `NET_ADMIN` and runs `wg`):

```bash
# live peer table: endpoints, last handshake, rx/tx bytes
docker compose -f core/docker-compose.yml exec gerbil wg show
```

To get this into your dashboards, run a WireGuard exporter **in Gerbil's network
namespace** so it can see the `wg` interface, scraped by VictoriaMetrics:

```yaml
  # add to core/docker-compose.yml
  wg-exporter:
    image: mindflavor/prometheus-wireguard-exporter:latest
    restart: unless-stopped
    network_mode: service:gerbil     # share Gerbil's netns → sees wg0
    cap_add: [NET_ADMIN]
    command: ["-n", "/etc/wireguard/wg0.conf", "-r"]   # -r resolves peer names
```

Then add a scrape job in `monitoring/victoriametrics/victoriametrics.yml`
(`wireguard_sent_bytes_total`, `wireguard_received_bytes_total`,
`wireguard_latest_handshake_seconds`). Alert on **stale handshakes**
(`time() - wireguard_latest_handshake_seconds > 300`) to catch dead tunnels.

> This is the complement to Traefik logs: **Gerbil/`wg` = transport health**,
> **Traefik logs = what rode through the transport**. Together they cover
> WireGuard end to end without ever needing to decrypt a packet.

---

## 6. How this fits the three sensors

| Layer | Sensor | Sees |
|---|---|---|
| L3/L4 edge, all ports, pre-NAT | **Suricata on `eth0`** | real client IP, scans, TLS handshake metadata (JA3/SNI), WireGuard *packets* (counts, peers) |
| L7 after TLS termination & tunnel delivery | **Traefik JSON access log** (this doc) | TLS version/cipher, host/path/UA/status, per-resource tunnel traffic |
| WireGuard transport | **Gerbil `wg show` / exporter** | handshakes, per-peer bytes, endpoints |

All three feed the same places: **VictoriaLogs/Grafana** for analysis, and
**Fail2ban** for banning (Suricata `eve.json` + Traefik `access.log`, exactly as
`Monitoring.md` plans). `ClientHost` (Traefik) ↔ `src_ip` (Suricata) is the join
key that lets a Grafana panel or a Fail2ban jail act on the same offender seen at
two layers.
```
