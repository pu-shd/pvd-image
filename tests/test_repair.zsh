#!/usr/bin/env zsh
#
# Behavioural tests for repair.sh against a mocked Azure CLI.
#
# repair.sh uninstalls a Visual Studio instance by path, so the guards that
# matter are: it refuses to run without an explicit path (never sweeping up an
# unrelated install), it requires confirmation, and it applies the same
# silence-is-not-success rule as deploy.sh.

emulate -L zsh
setopt pipe_fail

TEST_DIR="${0:A:h}"
ROOT="${TEST_DIR:h}"
MOCK_DIR="$TEST_DIR/mocks"

PASS=0 FAIL=0
typeset -a FAILURES

chmod +x "$MOCK_DIR/az" 2>/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/config.env" <<'CFG'
AVD_SUBSCRIPTION_ID="mock-sub"
AVD_RESOURCE_GROUP="mock-rg"
AVD_VM_NAME="MOCK-VM"
VS_EXPECTED_VERSION="18.10.0"
AVD_POLL_INTERVAL_SECONDS="1"
CFG

run_repair() {
  local scenario="$1"; shift
  MOCK_CALL_LOG="$WORK/calls.log"
  : > "$MOCK_CALL_LOG"
  out=$(
    PATH="$MOCK_DIR:$PATH" \
    AVD_CONFIG="$WORK/config.env" \
    MOCK_SCENARIO="$scenario" \
    MOCK_EXEC_STATE="${MOCK_EXEC_STATE:-Succeeded}" \
    MOCK_STALE_RUNCMD="${MOCK_STALE_RUNCMD:-0}" \
    MOCK_CALL_LOG="$MOCK_CALL_LOG" \
    AVD_LOG_DIR="$WORK/logs" \
    "$ROOT/repair.sh" "$@" 2>&1
  )
  return $?
}

check() {
  local name="$1" condition="$2"
  if (( condition )); then
    print -r -- "  ok   - $name"
    (( PASS++ ))
  else
    print -r -- "  FAIL - $name"
    FAILURES+=("$name")
    (( FAIL++ ))
  fi
}

print -r -- "repair.sh behavioural tests"
print -r -- "---------------------------"

unset MOCK_EXEC_STATE MOCK_STALE_RUNCMD

# --------------------------------------------------------------- path guard ---
run_repair success --yes; rc=$?
check "refuses to run without --path (never guesses a target)" "$(( rc != 0 ))"
check "says --path is required" \
      "$([[ "$out" == *"--path is required"* ]] && print 1 || print 0)"

run_repair success --path 'C:\Program' --yes; rc=$?
check "succeeds when the guest confirms removal" "$(( rc == 0 ))"
check "passes the target path as a run-command parameter" \
      "$(grep -q -- 'TargetInstallPath=C:\\Program' "$WORK/calls.log" && print 1 || print 0)"
check "dispatches the uninstall run-command" \
      "$(grep -q '^vm run-command create' "$WORK/calls.log" && print 1 || print 0)"

# ------------------------------------------------------------ empty-dir flag --
run_repair success --path 'C:\Program' --keep-dir --yes >/dev/null 2>&1
check "passes RemoveEmptyDirectory=false with --keep-dir" \
      "$(grep -q -- 'RemoveEmptyDirectory=false' "$WORK/calls.log" && print 1 || print 0)"

run_repair success --path 'C:\Program' --yes >/dev/null 2>&1
check "omits RemoveEmptyDirectory by default (removal is the default)" \
      "$(grep -q -- 'RemoveEmptyDirectory=' "$WORK/calls.log" && print 0 || print 1)"

# ------------------------------------------------- silence must not pass -------
run_repair silent --path 'C:\Program' --yes; rc=$?
check "FAILS when the guest produced no markers" "$(( rc != 0 ))"
check "explains the missing marker" \
      "$([[ "$out" == *"no AVD_STATUS marker"* ]] && print 1 || print 0)"
check "reads markers from instanceView.output only" \
      "$(grep -q -- '--query instanceView.output' "$WORK/calls.log" && print 1 || print 0)"

run_repair guestfail --path 'C:\Program' --yes; rc=$?
check "FAILS when the guest reports failure" "$(( rc != 0 ))"

MOCK_EXEC_STATE=Failed run_repair success --path 'C:\Program' --yes; rc=$?
check "FAILS when executionState is not Succeeded" "$(( rc != 0 ))"
unset MOCK_EXEC_STATE

# ------------------------------------------------------------- power state ----
run_repair deallocated --path 'C:\Program' --yes; rc=$?
check "refuses to run against a VM that is not running" "$(( rc != 0 ))"

# ----------------------------------------------------------- argument guard ---
run_repair success --path 'C:\Program' --nonsense --yes; rc=$?
check "rejects unknown arguments" "$(( rc != 0 ))"

print -r -- ""
print -r -- "passed: $PASS   failed: $FAIL"
if (( FAIL )); then
  print -r -- "failing tests:"
  for f in "${FAILURES[@]}"; do print -r -- "  - $f"; done
  exit 1
fi
exit 0
