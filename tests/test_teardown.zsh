#!/usr/bin/env zsh
#
# Behavioural tests for teardown.sh against a mocked Azure CLI.
#
# The guard that motivated this suite: Azure refuses to modify extensions on a
# stopped VM, so deleting a run-command resource fails on a deallocated VM with
# "(OperationNotAllowed) Cannot modify extensions in the VM when the VM is not
# running." teardown.sh must detect that up front and explain, rather than
# prompting and then dying on an opaque Azure error.

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
AVD_RUNCMD_NAME="install-vs-cpp"
CFG

run_teardown() {
  local scenario="$1"; shift
  MOCK_CALL_LOG="$WORK/calls.log"
  : > "$MOCK_CALL_LOG"
  rm -f "$MOCK_CALL_LOG.deleted"
  out=$(
    PATH="$MOCK_DIR:$PATH" \
    AVD_CONFIG="$WORK/config.env" \
    MOCK_SCENARIO="$scenario" \
    MOCK_STALE_RUNCMD="${MOCK_STALE_RUNCMD:-1}" \
    MOCK_CALL_LOG="$MOCK_CALL_LOG" \
    AVD_LOG_DIR="$WORK/logs" \
    "$ROOT/teardown.sh" "$@" 2>&1
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

print -r -- "teardown.sh behavioural tests"
print -r -- "-----------------------------"

# ------------------------------------------- deallocated VM, resource present -
# The real-world case: someone captured an image, the VM stopped, and the
# run-command is stranded.
run_teardown deallocated --yes; rc=$?
check "FAILS when the VM is stopped and a run-command still exists" "$(( rc != 0 ))"
check "explains that Azure rejects extension changes on a stopped VM" \
      "$([[ "$out" == *"extension"* ]] && print 1 || print 0)"
check "does not attempt the delete it knows will fail" \
      "$(grep -q '^vm run-command delete' "$WORK/calls.log" && print 0 || print 1)"
check "offers leaving it in place as an option" \
      "$([[ "$out" == *"costs nothing"* ]] && print 1 || print 0)"
check "warns against starting a sysprepped VM" \
      "$([[ "$out" == *"OOBE"* || "$out" == *"generalised"* ]] && print 1 || print 0)"
check "suggests the correct order for next time" \
      "$([[ "$out" == *"while the VM is still running"* ]] && print 1 || print 0)"

# ------------------------------------ deallocated VM, no resource to remove ---
MOCK_STALE_RUNCMD=0 run_teardown deallocated --yes; rc=$?
check "succeeds on a stopped VM when there is no run-command to remove" "$(( rc == 0 ))"
check "says there was nothing to remove" \
      "$([[ "$out" == *"nothing to remove"* ]] && print 1 || print 0)"
unset MOCK_STALE_RUNCMD

# --------------------------------------------- running VM, resource present ---
run_teardown success --yes; rc=$?
check "removes the run-command when the VM is running" "$(( rc == 0 ))"
check "actually issued the delete" \
      "$(grep -q '^vm run-command delete' "$WORK/calls.log" && print 1 || print 0)"
check "does not deallocate unless asked" \
      "$(grep -q '^vm deallocate' "$WORK/calls.log" && print 0 || print 1)"

run_teardown success --deallocate --yes; rc=$?
check "deallocates when asked" \
      "$(grep -q '^vm deallocate' "$WORK/calls.log" && print 1 || print 0)"
check "deletes the resource before deallocating" \
      "$(awk '/^vm run-command delete/{d=NR} /^vm deallocate/{a=NR} END{exit !(d && a && d < a)}' "$WORK/calls.log" && print 1 || print 0)"

# ------------------------------------------------------- already deallocated --
MOCK_STALE_RUNCMD=0 run_teardown deallocated --deallocate --yes; rc=$?
check "does not re-deallocate an already deallocated VM" \
      "$(grep -q '^vm deallocate' "$WORK/calls.log" && print 0 || print 1)"
check "says it is already deallocated" \
      "$([[ "$out" == *"already deallocated"* ]] && print 1 || print 0)"
unset MOCK_STALE_RUNCMD

# ------------------------------------------------- verification after delete --
MOCK_DELETE_NOOP=1 run_teardown success --yes; rc=$?
check "FAILS if the resource still exists after the delete call" "$(( rc != 0 ))"
check "says the resource still exists" \
      "$([[ "$out" == *"still exists"* ]] && print 1 || print 0)"
unset MOCK_DELETE_NOOP

# ----------------------------------------------------------- argument guard ---
run_teardown success --nonsense --yes; rc=$?
check "rejects unknown arguments" "$(( rc != 0 ))"

print -r -- ""
print -r -- "passed: $PASS   failed: $FAIL"
if (( FAIL )); then
  print -r -- "failing tests:"
  for f in "${FAILURES[@]}"; do print -r -- "  - $f"; done
  exit 1
fi
exit 0
