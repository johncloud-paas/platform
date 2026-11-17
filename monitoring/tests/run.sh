#!/usr/bin/env bash
# Test harness for the Fail2ban detection + ban pipeline.
#
#   ./tests/run.sh          offline suite only (safe, no root, deterministic)
#   ./tests/run.sh --live   also run the live end-to-end ban test (root + fail2ban up)
#
# Offline tests always run (they SKIP green when fail2ban-regex/fail2ban-client are
# absent). The live test mutates the host firewall and is gated behind --live plus a
# pre-flight check (root, running fail2ban.service, at least one configured jail).
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

# --- live suite (opt-in) -----------------------------------------------------
echo
if [ "$LIVE" -eq 1 ]; then
  reason=""
  [ "$(id -u)" -eq 0 ] || reason="must run as root (sudo)"
  if [ -z "$reason" ] && ! command -v fail2ban-client >/dev/null 2>&1; then
    reason="fail2ban-client not found (Fail2ban not installed)"
  fi
  if [ -z "$reason" ] && ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    reason="fail2ban.service is not running"
  fi
  if [ -z "$reason" ] && ! fail2ban-client status 2>/dev/null | grep -q "Jail list"; then
    reason="no Fail2ban jails configured"
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
