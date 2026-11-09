#!/usr/bin/env bash
# Test harness for the Suricata detection + CrowdSec ban pipeline.
#
#   ./tests/run.sh          offline suite only (safe, no root, deterministic)
#   ./tests/run.sh --live   also run the live end-to-end ban test (root + services up)
#
# Offline tests always run. The live test mutates the host firewall and is gated
# behind --live plus a pre-flight check (root, suricata.service, crowdsec.service,
# crowdsec-firewall-bouncer.service).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIVE=0
for arg in "$@"; do
  case "$arg" in
    --live) LIVE=1 ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

FAILED=0
run_script() {
  echo
  bash "$1" || FAILED=$((FAILED + 1))
}

# --- offline suite (always) --------------------------------------------------
run_script "$SCRIPT_DIR/offline/test_config_sanity.sh"
run_script "$SCRIPT_DIR/offline/test_filter_regex.sh"
run_script "$SCRIPT_DIR/offline/test_suricata_rules.sh"

# --- live suite (opt-in) -----------------------------------------------------
echo
if [ "$LIVE" -eq 1 ]; then
  reason=""
  [ "$(id -u)" -eq 0 ] || reason="must run as root (sudo)"
  if [ -z "$reason" ] && ! systemctl is-active --quiet suricata 2>/dev/null; then
    reason="suricata.service is not running"
  fi
  if [ -z "$reason" ] && ! command -v cscli >/dev/null 2>&1; then
    reason="cscli not found (CrowdSec not installed)"
  fi
  if [ -z "$reason" ] && ! systemctl is-active --quiet crowdsec 2>/dev/null; then
    reason="crowdsec.service is not running"
  fi
  if [ -z "$reason" ] && ! systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null; then
    reason="crowdsec-firewall-bouncer.service is not running"
  fi

  if [ -n "$reason" ]; then
    echo "== live: SKIPPED ($reason) =="
  else
    run_script "$SCRIPT_DIR/live/test_e2e_ban.sh"
  fi
else
  echo "== live: skipped (pass --live to run the end-to-end ban test) =="
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "ALL SUITES PASSED"
  exit 0
else
  echo "$FAILED SUITE(S) FAILED"
  exit 1
fi
