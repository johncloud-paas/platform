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

`setup_before_up.sh` sources the stack's `.env` and renders `*.template.*` files with `envsubst` into their real counterparts, then copies them under `$JOHNCLOUD_ROOT`. **The rendered outputs are gitignored** (e.g. `core/traefik/*_config.yml`, `monitoring/suricata/suricata.yaml`, `monitoring/fail2ban/jail.d/suricata.conf`) — edit the `*.template.*` source, never the rendered file. `$JOHNCLOUD_ROOT` (from `.env`) is the persistent data root **outside the repo**; stacks write all state there.

## Service exposure is label-driven

Services are **not** wired into Traefik by hand. A container declares `pangolin.public-resources.<name>.*` labels (full-domain, protocol, port, `ssl`, `auth.sso-enabled`, `auth.sso-roles[n]`, optional healthcheck/maintenance). **Newt** (core stack) watches the Docker socket, reads these labels, and registers the resource with **Pangolin**, which pushes dynamic config to **Traefik**. `homepage.*` labels feed the dashboard. Adding a service = adding labels to its compose, then `./startstack.sh` its directory. The flows are documented as sequence diagrams in `docs/use-cases/`.

## Request path (core stack = ingress + control plane)

- **Gerbil** is the only container that binds host ports 80/443/51820 — the WireGuard gateway. **Traefik** runs with `network_mode: service:gerbil` (shared network namespace), terminates TLS (Let's Encrypt via ACME), and routes. Changing exposed ports means editing the Gerbil service.
- **Access control** has two mechanisms: the Traefik `badger` plugin middleware (validates sessions against Pangolin's own SSO) and **Authentik** `forwardAuth` (separate identity provider). A resource's `auth.sso-*` labels pick its protection.
- `docker-socket-proxy` brokers read-only Docker API access; `geoipupdate` maintains the shared MaxMind GeoLite2 DBs; `certdumper` extracts certs from the ACME store.

## Rootless, with one rootful exception

The platform assumes rootless Docker (`DOCKER_HOST` → `$XDG_RUNTIME_DIR/docker.sock`; README has the host setup). **Suricata is the exception**: it needs `CAP_NET_RAW` in the init namespace to sniff the physical uplink, which rootless cannot grant, so it runs under the **system (rootful) daemon** from its own `monitoring/suricata/docker-compose.yml`. `monitoring/setup_before_up.sh` starts it via `sudo docker compose`, and also installs the **host-side Fail2ban** glue into `/etc/fail2ban/` (Fail2ban runs on the host, not in a container). Suricata writes `eve.json` to a shared logs dir that both fluent-bit and host Fail2ban tail.

## Monitoring & the detection pipeline

`monitoring` runs the VictoriaMetrics/Logs/Traces trio, fluent-bit, node-exporter, cadvisor, speedtest, and the Grafana PDC agent. The security chain is: packet on wire → Suricata alert (`eve.json`, severity 1) → host Fail2ban filter matches `src_ip` → `suricata-raw` action DROPs it in iptables raw/PREROUTING. Design rationale and decisions live in `monitoring/Monitoring.md`.

## Tests

The only automated tests cover the Suricata→Fail2ban pipeline (`monitoring/tests/`):

```bash
cd monitoring
./tests/run.sh            # offline suite — safe, no root, deterministic (what CI runs)
sudo ./tests/run.sh --live  # also the invasive end-to-end ban test (needs root + stack up)
```

Offline suites **skip green** (not fail) when `fail2ban-regex`/`fail2ban-client` or `docker` are absent; CI installs `fail2ban` so they actually run. The live test is pre-flight-gated (root, running `suricata` container, Fail2ban daemon + `suricata` jail) and cleans up its ban/rule via a trap. Tests read the **committed** config and `monitoring/.env`, not rendered copies. CI (`.github/workflows/monitoring-tests.yml`) runs the offline suite on every push and PR.
