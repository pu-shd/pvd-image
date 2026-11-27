#!/usr/bin/env zsh
#
# Behavioural tests for pykx.sh against a mocked Azure CLI.
#
# The guards specific to this driver: the versions the guest reports must be
# the versions config.env asks for, and when a check host is configured, a
# guest that installed but could not query it has not produced a usable image.

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

write_config() {
  cat > "$WORK/config.env" <<CFG
AVD_SUBSCRIPTION_ID="mock-sub"
AVD_RESOURCE_GROUP="mock-rg"
AVD_VM_NAME="MOCK-VM"
PYKX_VERSION="4.2.0"
PYKX_PYTHON_VERSION="3.12"
PYKX_UV_VERSION="0.8.0"
PYKX_UV_SHA256="bad5afed0c18bd7f6c5125f5c7ab89ac830a3db7340c96d50a50527e9880cdfe"
PYKX_INSTALL_PATH="C:\\Program Files\\HFM"
PYKX_COMMAND_PREFIX="hfm"
PYKX_CHECK_HOST="q.example.invalid"
PYKX_CHECK_PORT="6005"
$*
CFG
}

run_pykx() {
  local scenario="$1"; shift
  MOCK_CALL_LOG="$WORK/calls.log"
  : > "$MOCK_CALL_LOG"
  out=$(
    PATH="$MOCK_DIR:$PATH" \
    AVD_CONFIG="$WORK/config.env" \
    MOCK_SCENARIO="$scenario" \
    MOCK_EXEC_STATE="${MOCK_EXEC_STATE:-Succeeded}" \
    MOCK_CALL_LOG="$MOCK_CALL_LOG" \
    AVD_LOG_DIR="$WORK/logs" \
    "$ROOT/pykx.sh" "$@" 2>&1
  )
  return $?
}

called() { grep -q -- "$1" "$WORK/calls.log" && print 1 || print 0 }

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

print -r -- "pykx.sh behavioural tests"
print -r -- "-------------------------"

unset MOCK_EXEC_STATE MOCK_PYKX_VERSION MOCK_PYTHON_VERSION MOCK_CHECK
write_config

# ---------------------------------------------------------------- happy path --
run_pykx pykx; rc=$?
check "succeeds when the guest confirms the versions and the check" "$(( rc == 0 ))"
check "passes the PyKX version as a parameter" "$(called 'PykxVersion=4.2.0')"
check "passes the uv SHA-256 as a parameter" "$(called 'UvSha256=bad5afed')"
check "passes an install path containing spaces intact" "$(called 'InstallPath=C:\\Program Files\\HFM')"
check "passes the check host and port" "$(called 'CheckHost=q.example.invalid CheckPort=6005')"
check "passes the command prefix" "$(called 'CommandPrefix=hfm')"
check "names the user commands" "$([[ "$out" == *"hfm-python, hfm-test"* ]] && print 1 || print 0)"
check "reads markers from instanceView.output only" "$(called '--query instanceView.output')"

# ------------------------------------------------------------ version guards --
MOCK_PYKX_VERSION=4.3.0 run_pykx pykx; rc=$?
check "FAILS when the guest reports a different PyKX version" "$(( rc != 0 ))"
check "says which PyKX version it got" "$([[ "$out" == *"PyKX '4.3.0'"* ]] && print 1 || print 0)"
unset MOCK_PYKX_VERSION

MOCK_PYTHON_VERSION=3.13.1 run_pykx pykx; rc=$?
check "FAILS when the guest reports a different Python minor version" "$(( rc != 0 ))"
unset MOCK_PYTHON_VERSION

MOCK_PYTHON_VERSION=3.120.1 run_pykx pykx; rc=$?
check "does not take 3.120 for 3.12" "$(( rc != 0 ))"
unset MOCK_PYTHON_VERSION

# ------------------------------------------------------------- check guards ---
MOCK_CHECK=skipped run_pykx pykx; rc=$?
check "FAILS when a check host is configured but the guest skipped the check" "$(( rc != 0 ))"
unset MOCK_CHECK

MOCK_CHECK=skipped run_pykx pykx --skip-check; rc=$?
check "--skip-check succeeds without a check" "$(( rc == 0 ))"
check "--skip-check sends no check host" "$(( $(called 'CheckHost=') == 0 ))"

write_config 'PYKX_CHECK_HOST=""' 'PYKX_CHECK_PORT=""'
MOCK_CHECK=skipped run_pykx pykx; rc=$?
check "succeeds with no check host configured" "$(( rc == 0 ))"
unset MOCK_CHECK
write_config

# ------------------------------------------------- silence must not pass -------
run_pykx silent; rc=$?
check "FAILS when the guest produced no markers" "$(( rc != 0 ))"
check "explains the missing marker" "$([[ "$out" == *"no AVD_STATUS marker"* ]] && print 1 || print 0)"

run_pykx pykxfail; rc=$?
check "FAILS when the guest reports failure" "$(( rc != 0 ))"
check "relays the guest's reason" "$([[ "$out" == *"querying the check host failed"* ]] && print 1 || print 0)"

MOCK_EXEC_STATE=Failed run_pykx pykx; rc=$?
check "FAILS when executionState is not Succeeded" "$(( rc != 0 ))"
unset MOCK_EXEC_STATE

# -------------------------------------------------------- power and --start ---
run_pykx deallocated; rc=$?
check "refuses to run against a stopped VM without --start" "$(( rc != 0 ))"
check "does not create a run-command on a stopped VM" "$(( $(called '^vm run-command create') == 0 ))"

run_pykx deallocated --start --dry-run; rc=$?
check "--start --dry-run says it would start the VM" "$([[ "$out" == *"would start MOCK-VM"* ]] && print 1 || print 0)"
check "--dry-run starts nothing" "$(( $(called '^vm start') == 0 ))"

# ------------------------------------------------------------------ dry run ---
run_pykx pykx --dry-run; rc=$?
check "dry-run exits cleanly" "$(( rc == 0 ))"
check "dry-run creates no run-command" "$(( $(called '^vm run-command create') == 0 ))"

# ------------------------------------------------------------------- remove ---
MOCK_CHECK=skipped run_pykx pykx --remove; rc=$?
check "--remove succeeds" "$(( rc == 0 ))"
check "--remove passes Action=remove" "$(called 'Action=remove')"
check "--remove sends no versions" "$(( $(called 'PykxVersion=') == 0 ))"
unset MOCK_CHECK

# ------------------------------------------------------------- config guards --
write_config 'PYKX_VERSION="4.2.0; rm"'
run_pykx pykx; rc=$?
check "refuses a malformed PYKX_VERSION before calling Azure" \
      "$([[ $rc != 0 && "$out" == *"PYKX_VERSION"* ]] && print $(( $(called 'run-command') == 0 )) || print 0)"

write_config 'PYKX_UV_SHA256="abc"'
run_pykx pykx; rc=$?
check "refuses a malformed uv SHA-256" "$(( rc != 0 ))"

write_config 'PYKX_CHECK_PORT="70000"'
run_pykx pykx; rc=$?
check "refuses a check port above 65535" "$(( rc != 0 ))"

write_config 'PYKX_COMMAND_PREFIX="hfm test"'
run_pykx pykx; rc=$?
check "refuses a command prefix with a space" "$(( rc != 0 ))"

cat > "$WORK/config.env" <<'CFG'
AVD_SUBSCRIPTION_ID="mock-sub"
AVD_RESOURCE_GROUP="mock-rg"
AVD_VM_NAME="MOCK-VM"
CFG
run_pykx pykx; rc=$?
check "refuses to install with no PyKX settings" "$([[ $rc != 0 && "$out" == *"PYKX_VERSION"* ]] && print 1 || print 0)"
check "does not need VS_EXPECTED_VERSION" "$([[ "$out" != *"VS_EXPECTED_VERSION"* ]] && print 1 || print 0)"

write_config 'PYKX_UV_SHA256="REPLACE_WITH_UV_SHA256"'
run_pykx pykx; rc=$?
check "refuses an unedited template placeholder" "$([[ $rc != 0 && "$out" == *"placeholder"* ]] && print 1 || print 0)"

write_config
run_pykx pykx --nonsense; rc=$?
check "rejects unknown arguments" "$(( rc != 0 ))"

print -r -- ""
print -r -- "passed: $PASS   failed: $FAIL"
if (( FAIL )); then
  print -r -- "failing tests:"
  for f in "${FAILURES[@]}"; do print -r -- "  - $f"; done
  exit 1
fi
exit 0
