# Monitoring, Intrusion Detection & Blocking

Design notes for host traffic monitoring, malicious-activity detection via
customizable policies, and manual/automatic blocking on this node.

## Context & Requirements

- **Environment:** single-node Ubuntu, Docker Compose (not Swarm, not Kubernetes).
- **Existing stack:** Pangolin (`fosrl/pangolin`) + Gerbil + Newt tunneling,
  Traefik reverse proxy, GeoIP (MaxMind GeoLite2), docker-socket-proxy, Dockhand.
  Traefik access logs already land in `./pangolin/logs/`.
- **Goals:**
  1. Monitor **all** traffic on the host (every port/protocol, not just HTTP).
  2. Detect malicious activity through **customizable policies**.
  3. **Block** offenders, **manually or automatically**.
- **Hard constraint:** fully **free and open source**. No commercial tier that
  gates the interesting functionality.

## Decision Summary

| Decision | Choice | Date |
|---|---|---|
| Detection sensor | **Suricata** (IDS mode, `af-packet`) | 2026-10-08 |
| Rule source | **ET Open** ruleset + custom `local.rules` | 2026-10-08 |
| Block engine | **Fail2ban** → nftables (auto) + raw nftables (manual) | 2026-10-08 |
| Blocking posture | **Detection-first** (manual only), flip to auto later | 2026-10-08 |
| Alert UI (optional) | **EveBox** (GPLv2) | 2026-10-08 |
| Rejected | **CrowdSec** — see below | 2026-10-08 |

## Why not CrowdSec

CrowdSec was the first candidate (Docker-native, YAML policies, Traefik bouncer
plugin, nice manual-ban CLI). **Rejected because** its core is open source but the
genuinely valuable functionality is paywalled and increasingly so:

- Premium / curated IP blocklists (the crowd-sourced reputation that is its main
  selling point).
- The management console and multi-server features.

We want a stack with **no "upgrade for the good stuff" tier**. CrowdSec is also
log-only unless you bolt Suricata onto it anyway — so for true packet-level
visibility we would end up running Suricata regardless.

**What we give up by dropping CrowdSec:** crowd-sourced IP reputation. Partially
replaceable with free threat-intel lists (abuse.ch, FireHOL, Spamhaus DROP)
loaded into an nftables set on a cron — fully free, just more DIY.

## Chosen Stack: Suricata + Fail2ban

Each tool maps to one requirement, and nothing is gated:

| Requirement | Tool | Paywall? |
|---|---|---|
| Monitor **all** traffic on host | **Suricata** `af-packet` mode — sniffs every packet on the interface, all ports/protocols | None (GPLv2) |
| Detect via customizable policies | **ET Open** ruleset (~50k rules) **+ own `local.rules`** | ET **Open** free forever; only ET *Pro* costs money (not needed) |
| Block manually or automatically | **Fail2ban** → nftables. Manual: `fail2ban-client set <jail> banip`. Auto: jails on Suricata + Traefik logs | None (GPLv2) |

**Division of labour:** Suricata is the *sensor* (it sees and judges all
traffic, writes alerts to `eve.json`). Fail2ban is the *block engine* (clean CLI
for manual bans, jail configs for auto bans). Suricata *can* block itself via
inline IPS/NFQUEUE mode, but that is fiddlier kernel plumbing; using Fail2ban as
the blocker keeps it simplest and matches the detection-first posture.

### Architecture

```
┌─────────────┐   sniffs all packets    ┌──────────────┐
│  Suricata   │ ──────────────────────► │  eve.json    │
│ (host net,  │   ET Open + custom      │  (alerts)    │
│  IDS mode)  │      rules              └──────┬───────┘
└─────────────┘                                │ reads
                                               ▼
pangolin/logs/*.log ──────────────────► ┌──────────────┐  nftables
(Traefik access logs) ─────────────────►│  Fail2ban    │ ─────────► drop IP
                                         │ (jails:      │  (all ports)
                                         │  manual+auto)│
                                         └──────────────┘
```

- **Suricata:** container with `network_mode: host` + `cap_add: [NET_ADMIN,
  NET_RAW]`, watching the main interface. Rules in `./suricata/rules/`
  (ET Open auto-updated + a `local.rules` we own).
- **Fail2ban:** container with `network_mode: host` + `NET_ADMIN`, action =
  nftables, reading `eve.json` and `./pangolin/logs/`.
- **EveBox (optional, GPLv2):** web UI to browse Suricata alerts and
  archive/escalate them, instead of `tail -f eve.json`.

### Blocking posture: detection-first

Start in **IDS mode** (passive sniff, no inline/NFQUEUE). Fail2ban jails start
**disabled / detection mode** — Suricata just alerts into `eve.json`, we review
and ban by hand:

```bash
fail2ban-client set suricata banip 1.2.3.4     # manual ban
fail2ban-client set suricata unbanip 1.2.3.4   # undo
fail2ban-client status suricata                # see bans
```

Once the rules are trusted, flip the jail to `enabled = true` for automatic
banning. Same config, one switch.

## Trade-off: Fail2ban vs. raw nftables

This is **not** either/or — **Fail2ban uses nftables under the hood.** When a
jail fires it runs `nft add element ...` into an nftables set. The real question
is "what *drives* nftables":

- **Raw nftables** = you decide the IP and type the command.
- **Fail2ban** = a daemon watches logs, decides the IP, and types the command for
  you — plus the capabilities below.

| Need | Raw nftables | Fail2ban |
|---|---|---|
| Watch `eve.json` + Traefik logs and react | Write + maintain a parser/daemon | Built in (log tailing, regex filters) |
| **Expiring bans** (ban 24h, auto-release) | Manual, or a cron sweeping timestamps | `bantime = 24h`, native |
| Escalating / repeat-offender bans | DIY bookkeeping | `bantime.increment = true` |
| Survive reboot (re-apply bans) | Persist + replay the set yourself | Handled |
| One CLI for ban/unban/status | `nft add/delete element` + track state | `fail2ban-client set jail banip/unbanip/status` |
| Whitelist own IPs | Manual set entries | `ignoreip` |

The underestimated parts are **ban expiry and persistence**. A bare nftables set
is permanent and in-memory: ban an IP and it stays forever (until you remember
it) and vanishes on reboot. Doing time-based expiry + reboot survival +
repeat-offender logic in nftables means writing exactly the daemon Fail2ban
already is.

**Conclusion:**
- **Manual bans:** raw nftables is fine (`nft add element ...`), or route through
  `fail2ban-client ... banip` so all state lives in one place. Both write the
  same rule.
- **Automatic detection → ban:** Fail2ban earns its place here. The alternative
  is a custom script tailing `eve.json`, parsing, deduping, tracking timers and
  persisting across reboots — i.e. reinventing Fail2ban in ~200 lines of config.

**Pure-nftables alternative** (legitimate minimalist choice): skip Fail2ban,
write a small `eve.json` → `nft` watcher, and give up timed expiry/persistence
(or add a cron for it). Larger DIY surface; chosen against for "simplest".

## Alternatives Considered

| Option | Verdict | Reason |
|---|---|---|
| **CrowdSec** | Rejected | Best functionality paywalled; log-only without Suricata anyway |
| **Fail2ban alone** | Insufficient | Log-based only (regex); no packet-level "all traffic" visibility |
| **Suricata inline IPS (NFQUEUE)** | Deferred | Suricata blocks itself, but fiddlier kernel plumbing; revisit if auto-block needs sub-second inline drops |
| **Zeek** | Not needed | Excellent network analysis, but heavier and detection-focused; overkill for block-oriented goal |
| **OPNsense / pfSense** | Out of scope | Gateway appliance, not a Docker Compose service on this node |

## Implementation Checklist (not yet built)

- [ ] Confirm host interface carrying traffic (`ip -br link`, usually `eth0` / `ens*`).
- [ ] Add `suricata` service (`network_mode: host`, `NET_ADMIN`/`NET_RAW`),
      config + rules under `./suricata/`.
- [ ] Wire ET Open ruleset auto-update (`suricata-update`) + `local.rules`.
- [ ] Add `fail2ban` service (`network_mode: host`, `NET_ADMIN`), nftables action,
      reading `eve.json` + `./pangolin/logs/`.
- [ ] Start jails in detection-only mode; verify alerts land in `eve.json`.
- [ ] (Optional) Add EveBox for alert review UI.
- [ ] After tuning, enable automatic banning on trusted jails.
- [ ] (Optional) Cron free threat-intel blocklists (abuse.ch / FireHOL / Spamhaus
      DROP) into an nftables set to partly replace CrowdSec reputation.
