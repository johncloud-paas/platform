# Tiny bash assertion helpers for the monitoring test harness.
# Source this from a test script, call the assert_* helpers, then `finish`.
# Each test script is self-contained: it tracks its own counters and exits
# non-zero if any case failed, so it is runnable standalone or via run.sh.

# shellcheck shell=bash

_PASS=0
_FAIL=0
_SKIP=0

if [ -t 1 ]; then
  _C_GRN=$'\033[32m'; _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_RST=$'\033[0m'
else
  _C_GRN=''; _C_RED=''; _C_YEL=''; _C_RST=''
fi

pass() { _PASS=$((_PASS + 1)); printf '  %sPASS%s %s\n' "$_C_GRN" "$_C_RST" "$1"; }
fail() { _FAIL=$((_FAIL + 1)); printf '  %sFAIL%s %s\n' "$_C_RED" "$_C_RST" "$1"; }
skip() { _SKIP=$((_SKIP + 1)); printf '  %sSKIP%s %s\n' "$_C_YEL" "$_C_RST" "$1"; }

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected '$1', got '$2')"
  fi
}

# assert_contains HAYSTACK NEEDLE MESSAGE
assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *)      fail "$3 (missing '$2')" ;;
  esac
}

# assert_not_contains HAYSTACK NEEDLE MESSAGE
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpectedly contains '$2')" ;;
    *)      pass "$3" ;;
  esac
}

# finish — print per-script summary and exit non-zero on any failure.
finish() {
  printf '  ----------------------------------------\n'
  printf '  %d passed, %d failed, %d skipped\n' "$_PASS" "$_FAIL" "$_SKIP"
  [ "$_FAIL" -eq 0 ]
}
