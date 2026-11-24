# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

JohnCloud Platform is a self-hosted PaaS for a **single Ubuntu node running rootless Docker**. There is no application source to compile — the repo is a set of independent **Docker Compose stacks** plus the shell glue that renders their config and brings them up.

**Language policy: English is mandatory across the entire repository** — all documentation, README, `docs/`, code comments, and commit messages. Some existing docs (e.g. the README and `docs/`) are still in French; translate them to English when you touch them, and write any new content in English.

## Stacks & orchestration

Each top-level directory with a `docker-compose.yml` is a stack: `core`, `monitoring`, `authentik`, `backup`, `homepage`. A stack directory may also contain `sample.env` (committed template), `.env` (gitignored, real secrets), and optional `setup_before_up.sh` / `setup_after_up.sh` lifecycle hooks.

Four root scripts operate on a stack **directory** (not a name):

```bash
./startstack.sh <stack-dir> [service]   # pull → down → setup_before_up → up -d --force-recreate --remove-orphans → setup_after_up → logs -f [service]
./stopstack.sh  <stack-dir>             # compose down
./psstack.sh    <stack-dir>             # compose ps
./logstack.sh   <stack-dir> [service]   # compose logs -f
```

`startstack.sh` is the canonical deploy path — run it after editing a stack's compose or templates so the `setup_before_up.sh` render step re-runs.

## Config is generated, not committed

`setup_before_up.sh` sources the stack's `.env` and renders `*.template.*` files with `envsubst` into their real counterparts, then copies them under `$JOHNCLOUD_ROOT`. **The rendered outputs are gitignored** (e.g. `core/traefik/*_config.yml` from `*_config.template.yml`, `core/pangolin/config.yml` from `config.template.yml`) — edit the `*.template.*` source, never the rendered file. The host Fail2ban config is the same idea but lands outside the repo: `monitoring/scripts/install-host-security.sh` renders `monitoring/fail2ban/jail.template.local` into `/etc/fail2ban/jail.local`. `$JOHNCLOUD_ROOT` (from `.env`) is the persistent data root **outside the repo**; stacks write all state there.

## Service exposure is label-driven

Services are **not** wired into Traefik by hand. A container declares `pangolin.public-resources.<name>.*` labels (full-domain, protocol, port, `ssl`, `auth.sso-enabled`, `auth.sso-roles[n]`, optional healthcheck/maintenance). **Newt** (core stack) watches the Docker socket, reads these labels, and registers the resource with **Pangolin**, which pushes dynamic config to **Traefik**. `homepage.*` labels feed the dashboard. Adding a service = adding labels to its compose, then `./startstack.sh` its directory. The flows are documented as sequence diagrams in `docs/use-cases/`.

## Request path (core stack = ingress + control plane)

- **Gerbil** is the only container that binds host ports 80/443/51820 — the WireGuard gateway. **Traefik** runs with `network_mode: service:gerbil` (shared network namespace), terminates TLS (Let's Encrypt via ACME), and routes. Changing exposed ports means editing the Gerbil service.
- **Access control** has two mechanisms: the Traefik `badger` plugin middleware (validates sessions against Pangolin's own SSO) and **Authentik** `forwardAuth` (separate identity provider). A resource's `auth.sso-*` labels pick its protection.
- `docker-socket-proxy` brokers read-only Docker API access; `geoipupdate` maintains the shared MaxMind GeoLite2 DBs; `certdumper` extracts certs from the ACME store.

## Rootless Docker

The platform assumes rootless Docker (`DOCKER_HOST` → `$XDG_RUNTIME_DIR/docker.sock`; README has the host setup). The one component that runs **on the host, not in a container**, is **Fail2ban**: `monitoring/scripts/install-host-security.sh` installs it via apt, renders `monitoring/fail2ban/jail.template.local` into `/etc/fail2ban/jail.local` with `envsubst`, copies the custom filters into `/etc/fail2ban/filter.d/`, and enables the systemd service. It reads the systemd journal (host units, plus container stdout/stderr via the journald log driver) and the Traefik access log. Caveat under rootless Docker: container logs land in the *user* journal, which Fail2ban's systemd backend skips by default (`SYSTEM_ONLY`), so the `docker-apps` jail must opt in with `journalflags = 1` + `journalmatch = _SYSTEMD_USER_UNIT=docker.service` (matches all containers, excludes host sshd) — without it that jail sees no container logs and silently shadows host sshd lines. The former packet-IDS layer (Suricata/Snort) and CrowdSec have been **removed** — a packet IDS needs `CAP_NET_RAW` on the uplink (awkward under rootless Docker) and the useful signal is already in the logs.

## Monitoring & the detection pipeline

`monitoring` runs **Vector**, node-exporter, cadvisor, speedtest, VictoriaTraces, and the Grafana PDC agent. **Vector** replaces the former fluent-bit + VictoriaMetrics/VictoriaLogs path: it collects logs from two sources into the `logs` table — `docker_logs` (container stdout/stderr) and a `file` source on the Traefik JSON access log — and its `prometheus_scrape` source scrapes node-exporter/cadvisor/speedtest, all written via Vector's native `postgres` sink into the `monitoring` PostgreSQL database (the single `core` Postgres, reached cross-stack as `core-db-1`; no TimescaleDB). Ingesting the Traefik access log (not just container logs) is what gives `traefik-*` bans log rows to link to; a `remap` best-effort extracts `client_ip` per line. There is deliberately no SSH-log source: the host journal and `/var/log/auth.log` are `0640` root/syslog-owned and Vector is rootless (their owners aren't mapped into its userns), so `sshd` bans aren't line-linked — their IP/geo still come from `security_events` (the Fail2ban action), just not the raw sshd lines. The `initial-config` service provisions that DB/role and applies `scripts/schema.sql` (tables `logs`, `metrics`, `security_events`, `geoip_lookup`); schema changes to existing tables go in via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` since `CREATE TABLE IF NOT EXISTS` skips an existing table. Note Vector 0.57+ makes `${VAR}` config interpolation opt-in, re-enabled with `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true`. Banned IPs are geo-located out-of-band by the `geoip-sync` service (`scripts/geoip-sync.py`), which periodically resolves the distinct `security_events.ip` values against the GeoLite2 City+ASN mmdb that `core`'s `geoipupdate` maintains and upserts them into the `geoip_lookup` table (joined to events by the `security_events_geo` view, e.g. for a Grafana Geomap); Vector can't do this inline (VRL has no runtime lookup). Each ban is linked to the log lines that triggered it **inside Postgres**: Vector stamps a `uuid_v4()` `security_events.id`, and an `AFTER INSERT` trigger (`link_security_event()`) back-fills `logs.linked_event` for rows matching the ban's IP within the jail's `findtime` window (query via the `security_event_log_lines` view). This is a trigger, not a loader, because it joins two tables already in the DB (unlike `geoip-sync`, which stays Python only because it reads an external mmdb); the match is heuristic (IP + time window, first-ban-wins, `recidive`/unbans skipped). The security chain is log-driven: container/host logs (systemd journal) + the Traefik JSON access log → **Fail2ban** filters (`monitoring/fail2ban/filter.d/`, e.g. `traefik-access` in `4xx`/`bot` mode, `docker-apps`) match an offender's `<HOST>` → the jail's `nftables-multiport` banaction DROPs it in **nftables**. Design rationale and decisions live in `monitoring/README.md`.

## Tests

The only automated tests cover the Fail2ban detection + ban pipeline (`monitoring/tests/`):

```bash
cd monitoring
./tests/run.sh            # offline suite — safe, no root, deterministic
sudo ./tests/run.sh --live  # also the invasive end-to-end ban test (needs root + fail2ban up)
```

The offline suite is two scripts: `test_config_sanity.sh` validates the committed jail template, filters, installer, and `sample.env`; `test_filter_regex.sh` runs `fail2ban-regex` over the fixtures in `tests/fixtures/` to assert the `traefik-access`/`docker-apps` filters match malicious lines and ignore benign ones. Both **skip green** (not fail) when `fail2ban-regex`/`fail2ban-client` is absent; install `fail2ban` locally so they actually run. The live test (`tests/live/test_e2e_ban.sh`) is pre-flight-gated (root, running `fail2ban.service`, ≥1 jail), always targets the inert TEST-NET IP `203.0.113.66`, checks both the manual-ban firewall path and an organic ban through a throwaway jail that reuses the committed filter, and cleans up via a trap. Shared assertion helpers live in `tests/lib/assert.sh`. Tests read the **committed** config, not rendered copies.
