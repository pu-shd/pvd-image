#!/usr/bin/env zsh
#
# Behavioural tests for shortcuts.sh against a mocked Azure CLI.
#
# The guard specific to this driver: it must confirm the guest processed as many
# shortcuts as were asked for. A guest that reports success having created one of
# three is a failure, not a pass.

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
AVD_SHORTCUTS="Excel=C:\\Program Files\\Microsoft Office\\root\\Office16\\EXCEL.EXE"
CFG

run_shortcuts() {
  local scenario="$1"; shift
  MOCK_CALL_LOG="$WORK/calls.log"
  : > "$MOCK_CALL_LOG"
  out=$(
    PATH="$MOCK_DIR:$PATH" \
    AVD_CONFIG="$WORK/config.env" \
    MOCK_SCENARIO="$scenario" \
    MOCK_EXEC_STATE="${MOCK_EXEC_STATE:-Succeeded}" \
    MOCK_STALE_RUNCMD="${MOCK_STALE_RUNCMD:-0}" \
    MOCK_SHORTCUT_COUNT="${MOCK_SHORTCUT_COUNT:-1}" \
    MOCK_CALL_LOG="$MOCK_CALL_LOG" \
    AVD_LOG_DIR="$WORK/logs" \
    "$ROOT/shortcuts.sh" "$@" 2>&1
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

print -r -- "shortcuts.sh behavioural tests"
print -r -- "------------------------------"

unset MOCK_EXEC_STATE MOCK_STALE_RUNCMD MOCK_SHORTCUT_COUNT

# ---------------------------------------------------------------- happy path --
run_shortcuts shortcuts; rc=$?
check "succeeds when the guest confirms the shortcut" "$(( rc == 0 ))"
check "passes the spec from config.env as a parameter" \
      "$(grep -q -- 'Shortcuts=Excel=C:\\Program Files' "$WORK/calls.log" && print 1 || print 0)"
check "passes Action=create by default" \
      "$(grep -q -- 'Action=create' "$WORK/calls.log" && print 1 || print 0)"
check "names the created shortcut in its output" \
      "$([[ "$out" == *"Excel"* ]] && print 1 || print 0)"

# --------------------------------------------------------------- remove mode --
run_shortcuts shortcuts --remove; rc=$?
check "passes Action=remove with --remove" \
      "$(grep -q -- 'Action=remove' "$WORK/calls.log" && print 1 || print 0)"

# ----------------------------------------------------------------- spec guard --
run_shortcuts shortcuts --spec 'Excel=C:\a\EXCEL.EXE;Word=C:\a\WINWORD.EXE'; rc=$?
check "FAILS when the guest processed fewer shortcuts than requested" "$(( rc != 0 ))"
check "says how many were asked for versus done" \
      "$([[ "$out" == *"asked for 2"* ]] && print 1 || print 0)"

MOCK_SHORTCUT_COUNT=2 run_shortcuts shortcuts --spec 'Excel=C:\a\EXCEL.EXE;Word=C:\a\WINWORD.EXE'; rc=$?
check "succeeds when the guest count matches the request" "$(( rc == 0 ))"
unset MOCK_SHORTCUT_COUNT

# ------------------------------------------------- silence must not pass -------
run_shortcuts silent; rc=$?
check "FAILS when the guest produced no markers" "$(( rc != 0 ))"
check "explains the missing marker" \
      "$([[ "$out" == *"no AVD_STATUS marker"* ]] && print 1 || print 0)"
check "reads markers from instanceView.output only" \
      "$(grep -q -- '--query instanceView.output' "$WORK/calls.log" && print 1 || print 0)"

run_shortcuts guestfail; rc=$?
check "FAILS when the guest reports failure" "$(( rc != 0 ))"

MOCK_EXEC_STATE=Failed run_shortcuts shortcuts; rc=$?
check "FAILS when executionState is not Succeeded" "$(( rc != 0 ))"
unset MOCK_EXEC_STATE

# ------------------------------------------------------------- power state ----
run_shortcuts deallocated; rc=$?
check "refuses to run against a VM that is not running" "$(( rc != 0 ))"

# ------------------------------------------------------------------ dry run ---
run_shortcuts shortcuts --dry-run; rc=$?
check "dry-run exits cleanly" "$(( rc == 0 ))"
check "dry-run creates no run-command" \
      "$(grep -q '^vm run-command create' "$WORK/calls.log" && print 0 || print 1)"

# ----------------------------------------------------------- argument guard ---
run_shortcuts shortcuts --nonsense; rc=$?
check "rejects unknown arguments" "$(( rc != 0 ))"

# ---------------------------------------------------------- empty spec guard --
cat > "$WORK/empty.env" <<'CFG'
AVD_SUBSCRIPTION_ID="mock-sub"
AVD_RESOURCE_GROUP="mock-rg"
AVD_VM_NAME="MOCK-VM"
VS_EXPECTED_VERSION="18.10.0"
CFG
out=$(PATH="$MOCK_DIR:$PATH" AVD_CONFIG="$WORK/empty.env" MOCK_SCENARIO=shortcuts \
      AVD_LOG_DIR="$WORK/logs" "$ROOT/shortcuts.sh" 2>&1); rc=$?
check "refuses to run with no shortcuts configured" "$(( rc != 0 ))"
check "explains that AVD_SHORTCUTS or --spec is needed" \
      "$([[ "$out" == *"no shortcuts given"* ]] && print 1 || print 0)"

print -r -- ""
print -r -- "passed: $PASS   failed: $FAIL"
if (( FAIL )); then
  print -r -- "failing tests:"
  for f in "${FAILURES[@]}"; do print -r -- "  - $f"; done
  exit 1
fi
exit 0
