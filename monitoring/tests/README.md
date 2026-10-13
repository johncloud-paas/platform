# Suricata → Fail2ban pipeline tests

Repeatable scenario proving the IDS/auto-ban chain works end to end:

```
packet on the wire → Suricata detects (eve.json alert, severity 1)
  → host Fail2ban filter matches src_ip
  → suricata-raw action DROPs the source in iptables raw/PREROUTING
```

The tests exercise the real, committed config (`monitoring/fail2ban/**`,
`monitoring/suricata/local.rules`) — not copies.

## Layout

| Path | What it checks |
|------|----------------|
| `run.sh` | Entrypoint. `./tests/run.sh [--live]` |
| `offline/test_config_sanity.sh` | Filter scoped to severity 1, raw/PREROUTING ban action, polling backend; `fail2ban-client -t` when present |
| `offline/test_filter_regex.sh` | `fail2ban-regex` vs `eve.json` fixtures: severity-1 matches & captures the IP; severity-2, the ICMP smoke test, and non-alert events do **not** match |
| `offline/test_suricata_rules.sh` | `suricata -T` loads `local.rules` and the e2e rule (containerized) |
| `fixtures/eve/*.json` | Hand-written single-line Suricata EVE events used by the regex test |
| `live/test_e2e_ban.sh` | Real traffic → detection → ban → assert → cleanup |
| `live/fail2ban-e2e.rules` | Temporary `priority:1` rule (sid 1000099) firing on src `203.0.113.66` |
| `live/inject_packet.py` | scapy spoofed-source sender (fallback to `hping3`) |

## Running

### Offline (default — safe, no root, CI-friendly)

```bash
cd monitoring
./tests/run.sh
```

Runs the three offline suites and reports the live suite as skipped. A suite skips
(rather than fails) when a tool is missing: `fail2ban-regex`/`fail2ban-client` from
the `fail2ban` package, and `docker` for the `suricata -T` check.

### Live end-to-end (invasive — root + running stack)

```bash
cd monitoring
sudo ./tests/run.sh --live
```

Pre-flight gates the live test on: root, the `suricata` container running, the
`fail2ban` daemon up, and the `suricata` jail enabled — otherwise it is skipped
with a reason. Needs `hping3` (preferred) or `python3` + `scapy` to emit the packet.

**What it does:** installs a temporary `priority:1` rule into the running sensor's
runtime rules, sends one spoofed-source SYN (`src=203.0.113.66`,
[RFC 5737](https://datatracker.ietf.org/doc/html/rfc5737) TEST-NET-3 — never a real
client, outside the jail `ignoreip`) across the monitored uplink, then asserts the
severity-1 alert in `eve.json`, the ban in `fail2ban-client status suricata`, and
the `iptables -t raw -S PREROUTING` DROP. A trap always unbans the IP, removes the
temporary rule, and reloads Suricata — so no ban or test rule is left behind.

**Manual re-check after a run:**

```bash
fail2ban-client status suricata          # should list no 203.0.113.66
iptables -t raw -S PREROUTING            # no leftover DROP for 203.0.113.66
```

## Notes

- Config is read from `monitoring/.env` (`JOHNCLOUD_ROOT`, `SURICATA_UPLINK`), the
  same vars `setup_before_up.sh` uses — not from the gitignored, possibly-stale
  rendered jail.
- The live test edits `$JOHNCLOUD_ROOT/suricata/local.rules` (host runtime copy,
  outside the repo) and restores it on exit.
