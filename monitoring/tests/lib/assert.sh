# assert.sh — tiny assertion helpers shared by the Fail2ban test suite.
#
# Source this from a test script:
#   . "$TESTS_DIR/lib/assert.sh"
# then use pass/fail/skip/assert_* and end with `finish` (which sets the exit code).
#
# Counters are kept in the sourcing shell. `finish` returns non-zero if any
# assertion failed, so run.sh can tally suite results.

: "${_ASSERT_PASS:=0}"
: "${_ASSERT_FAIL:=0}"
: "${_ASSERT_SKIP:=0}"

pass() { _ASSERT_PASS=$((_ASSERT_PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { _ASSERT_FAIL=$((_ASSERT_FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { _ASSERT_SKIP=$((_ASSERT_SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected '$1', got '$2')"
  fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *)      fail "$3 (missing '$2')" ;;
  esac
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpectedly found '$2')" ;;
    *)      pass "$3" ;;
  esac
}

# assert_match <file> <extended-regex> <message> : file has >=1 line matching regex
assert_match() {
  if grep -Eq "$2" "$1" 2>/dev/null; then
    pass "$3"
  else
    fail "$3 (no line in $1 matched /$2/)"
  fi
}

# finish : print the tally and set the suite exit code.
finish() {
  printf -- '-- %d passed, %d failed, %d skipped --\n' \
    "$_ASSERT_PASS" "$_ASSERT_FAIL" "$_ASSERT_SKIP"
  [ "$_ASSERT_FAIL" -eq 0 ]
}
