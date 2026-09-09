#!/usr/bin/env zsh
#
# Behavioural tests for deploy.sh against a mocked Azure CLI.
#
# The property that matters most here: the driver must FAIL when the guest says
# nothing. A run-command can report executionState=Succeeded while the script
# inside it never ran; treating that as a pass would silently ship a broken
# image. Several cases below exist purely to pin that down.

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
VS_EXPECTED_BUILD="12201.205"
VS_BOOTSTRAPPER_URL="https://example.invalid/vs_community.exe"
VS_INSTALL_PATH="C:\\Program Files\\Microsoft Visual Studio\\2026\\Community"
AVD_RUNCMD_TIMEOUT_SECONDS="30"
AVD_RUNCMD_NAME="test-install-vs"
AVD_POLL_INTERVAL_SECONDS="1"
CFG

# run_deploy <scenario> [extra deploy.sh args...] -> sets $out, returns exit code
run_deploy() {
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
    "$ROOT/deploy.sh" "$@" 2>&1
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

print -r -- "deploy.sh behavioural tests"
print -r -- "---------------------------"

# ---------------------------------------------------------------- happy path --
unset MOCK_EXEC_STATE MOCK_STALE_RUNCMD
run_deploy success; rc=$?
check "succeeds when the guest reports success with the expected version" \
      "$(( rc == 0 ))"
check "reports the installed display version in its output" \
      "$([[ "$out" == *"Visual Studio 18.10.0"* ]] && print 1 || print 0)"

# ------------------------------------------- parameter passing (regression) ---
# The driver must hand parameters to run-command via --parameters. Prepending
# them to the script text puts code ahead of param(), which is a parse error on
# the guest and kills the run in under a second.
check "passes ExpectedVersion via --parameters" \
      "$(grep -q -- '--parameters ExpectedVersion=18.10.0' "$WORK/calls.log" && print 1 || print 0)"
check "does not prepend an assignment ahead of the script's param() block" \
      "$(grep -q -- '--script \$ExpectedVersion=' "$WORK/calls.log" && print 0 || print 1)"

run_deploy success --allow-drift >/dev/null 2>&1
check "passes ExpectedBuild via --parameters" \
      "$(grep -q -- 'ExpectedBuild=12201.205' "$WORK/calls.log" && print 1 || print 0)"
check "passes the quoted InstallPath through --parameters" \
      "$(grep -q -- 'InstallPath=C:\\Program Files' "$WORK/calls.log" && print 1 || print 0)"

check "passes AllowVersionDrift=true when --allow-drift is given" \
      "$(grep -q -- 'AllowVersionDrift=true' "$WORK/calls.log" && print 1 || print 0)"

run_deploy success >/dev/null 2>&1
check "omits AllowVersionDrift when --allow-drift is not given" \
      "$(grep -q -- 'AllowVersionDrift=' "$WORK/calls.log" && print 0 || print 1)"

# ------------------------------------------------- silence must not pass ------
# The mock's full resource JSON embeds a `source.script` containing literal
# marker strings, exactly as the real API echoes back the uploaded script. A
# driver that greps the whole blob matches its own source and reports nonsense
# ("AVD_REASON=$Reason"). Markers must come from instanceView.output alone.
run_deploy silent; rc=$?
check "FAILS when the guest produced no markers (silence != success)" \
      "$(( rc != 0 ))"
check "explains that the missing marker is being treated as failure" \
      "$([[ "$out" == *"no AVD_STATUS marker"* ]] && print 1 || print 0)"
check "reads markers from instanceView.output, not the whole resource JSON" \
      "$(grep -q -- '--query instanceView.output' "$WORK/calls.log" && print 1 || print 0)"
check "does not mistake the echoed script source for a guest report" \
      "$([[ "$out" != *'AVD_REASON=$Reason'* ]] && print 1 || print 0)"
check "surfaces guest stderr when the guest went silent" \
      "$([[ "$out" == *"ParserError"* ]] && print 1 || print 0)"

# ------------------------------------------------------ guest-reported failure -
run_deploy guestfail; rc=$?
check "FAILS when the guest reports AVD_STATUS=failed" "$(( rc != 0 ))"
check "surfaces the guest's reason" \
      "$([[ "$out" == *"1618"* ]] && print 1 || print 0)"

# ------------------------------------------------------------- version drift --
run_deploy drift; rc=$?
check "FAILS when Stable delivered a different version than configured" "$(( rc != 0 ))"
check "names both the installed and expected versions" \
      "$([[ "$out" == *"18.11.0"* && "$out" == *"18.10.0"* ]] && print 1 || print 0)"

run_deploy drift --allow-drift; rc=$?
check "accepts a drifted version when --allow-drift is passed" "$(( rc == 0 ))"

# ------------------------------------------------- success without a version --
run_deploy noversion; rc=$?
check "FAILS on a success marker with no version (refuses to trust it)" "$(( rc != 0 ))"

# ----------------------------------------------------- execution state guard --
MOCK_EXEC_STATE=Failed run_deploy success; rc=$?
check "FAILS when executionState is not Succeeded" "$(( rc != 0 ))"
unset MOCK_EXEC_STATE

MOCK_EXEC_STATE=TimedOut run_deploy success; rc=$?
check "FAILS when the run-command timed out" "$(( rc != 0 ))"
unset MOCK_EXEC_STATE

# ------------------------------------------------------------- power state ----
run_deploy deallocated; rc=$?
check "refuses to run against a deallocated VM without --start" "$(( rc != 0 ))"
check "points at Nerdio as the preferred way to start it" \
      "$([[ "$out" == *"Nerdio"* ]] && print 1 || print 0)"

run_deploy deallocated --start; rc=$?
check "starts the VM when --start is given" "$(( rc == 0 ))"
check "actually issued 'vm start'" \
      "$(grep -q '^vm start' "$WORK/calls.log" && print 1 || print 0)"

# ---------------------------------------------------------- reboot reporting --
run_deploy reboot; rc=$?
check "succeeds but warns when a reboot is required" \
      "$(( rc == 0 ))"
check "warns about the pending reboot before sealing" \
      "$([[ "$out" == *"reboot is required"* ]] && print 1 || print 0)"

# ------------------------------------------------------- stale resource path --
MOCK_STALE_RUNCMD=1 run_deploy success; rc=$?
check "removes a stale run-command resource before creating a new one" \
      "$(grep -q '^vm run-command delete' "$WORK/calls.log" && print 1 || print 0)"
unset MOCK_STALE_RUNCMD

# ------------------------------------------------------------------ dry run ---
run_deploy success --dry-run; rc=$?
check "dry-run exits cleanly" "$(( rc == 0 ))"
check "dry-run creates no run-command" \
      "$(grep -q '^vm run-command create' "$WORK/calls.log" && print 0 || print 1)"

# ----------------------------------------------------------- argument guard ---
run_deploy success --nonsense; rc=$?
check "rejects unknown arguments" "$(( rc != 0 ))"

# ------------------------------------------------------------ config guards ---
out=$(PATH="$MOCK_DIR:$PATH" AVD_CONFIG="$WORK/does-not-exist.env" \
      AVD_LOG_DIR="$WORK/logs" "$ROOT/deploy.sh" 2>&1); rc=$?
check "fails when config.env is absent" "$(( rc != 0 ))"
check "points the user at config.env.example" \
      "$([[ "$out" == *"config.env.example"* ]] && print 1 || print 0)"

cat > "$WORK/placeholder.env" <<'CFG'
AVD_SUBSCRIPTION_ID="REPLACE_WITH_SUBSCRIPTION_ID"
AVD_RESOURCE_GROUP="REPLACE_WITH_RESOURCE_GROUP"
AVD_VM_NAME="REPLACE_WITH_VM_NAME"
VS_EXPECTED_VERSION="18.10.0"
CFG
out=$(PATH="$MOCK_DIR:$PATH" AVD_CONFIG="$WORK/placeholder.env" \
      AVD_LOG_DIR="$WORK/logs" "$ROOT/deploy.sh" 2>&1); rc=$?
check "refuses to run with unedited template placeholders" "$(( rc != 0 ))"
check "names the placeholder variable it found" \
      "$([[ "$out" == *"AVD_SUBSCRIPTION_ID"* ]] && print 1 || print 0)"

print -r -- ""
print -r -- "passed: $PASS   failed: $FAIL"
if (( FAIL )); then
  print -r -- "failing tests:"
  for f in "${FAILURES[@]}"; do print -r -- "  - $f"; done
  exit 1
fi
exit 0
