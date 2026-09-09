#!/usr/bin/env zsh
#
# Install Visual Studio Community (C++ workload) onto the AVD image VM using
# Azure run-command. Requires no network route to the VM and no VPN.
#
#   ./deploy.sh [--start] [--allow-drift] [--dry-run] [--timeout N]
#
# --start        start the VM if it is deallocated (it usually is)
# --allow-drift  accept a Stable version other than VS_EXPECTED_VERSION
# --dry-run      print what would run, change nothing
#
# Exits non-zero unless the guest explicitly reported success. A run-command
# that produces no output is a FAILURE here, never a pass.

emulate -L zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/common.sh"

START_VM=0 ALLOW_DRIFT=0 DRY_RUN=0 TIMEOUT_OVERRIDE=""
while (( $# )); do
  case "$1" in
    --start)       START_VM=1 ;;
    --allow-drift) ALLOW_DRIFT=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --timeout)     shift; TIMEOUT_OVERRIDE="$1" ;;
    -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
    *)             die "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

load_config
require_az

: "${AVD_RUNCMD_NAME:=install-vs-cpp}"
: "${AVD_RUNCMD_TIMEOUT_SECONDS:=5400}"
: "${AVD_POLL_INTERVAL_SECONDS:=30}"
[[ -n "$TIMEOUT_OVERRIDE" ]] && AVD_RUNCMD_TIMEOUT_SECONDS="$TIMEOUT_OVERRIDE"

PS_SCRIPT="$SCRIPT_DIR/scripts/Install-VisualStudio.ps1"
[[ -f "$PS_SCRIPT" ]] || { die "missing $PS_SCRIPT"; exit 1 }

log "target: $AVD_VM_NAME ($AVD_RESOURCE_GROUP) in $AVD_SUBSCRIPTION_ID"
log "expecting Visual Studio $VS_EXPECTED_VERSION"

# ------------------------------------------------------------ power state ---
power=$(vm_power_state || true)
log "power state: ${power:-unknown}"
if [[ "$power" != *running* ]]; then
  if (( START_VM )); then
    if (( DRY_RUN )); then
      log "[dry-run] would start $AVD_VM_NAME"
    else
      log "starting $AVD_VM_NAME (this takes a couple of minutes)"
      az vm start -g "$AVD_RESOURCE_GROUP" -n "$AVD_VM_NAME" --subscription "$AVD_SUBSCRIPTION_ID" -o none
      wait_for_agent 420
    fi
  else
    die "VM is '${power:-unknown}'. Start it from Nerdio (preferred, keeps image state consistent) or pass --start."
    exit 1
  fi
fi

# --------------------------------------------------- build the guest script --
# Parameters go through run-command's --parameters, which binds them to the
# script's param() block by name. They must NOT be prepended to the script text:
# param() has to be the first statement in a PowerShell script, so anything in
# front of it makes the whole file fail to parse.
script_body="$(<"$PS_SCRIPT")"

typeset -a runcmd_params
runcmd_params=( "ExpectedVersion=${VS_EXPECTED_VERSION}" )
[[ -n "${VS_EXPECTED_BUILD:-}" ]] && runcmd_params+=( "ExpectedBuild=${VS_EXPECTED_BUILD}" )
[[ -n "${VS_INSTALL_PATH:-}"   ]] && runcmd_params+=( "InstallPath=${VS_INSTALL_PATH}" )
(( ALLOW_DRIFT )) && runcmd_params+=( "AllowVersionDrift=true" )

if (( DRY_RUN )); then
  log "[dry-run] would create run-command '$AVD_RUNCMD_NAME' (timeout ${AVD_RUNCMD_TIMEOUT_SECONDS}s)"
  log "[dry-run] parameters: ${runcmd_params[*]}"
  log "[dry-run] script bytes: ${#script_body}"
  exit 0
fi

# A previous run leaves the resource behind; creating over it errors.
if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
  log "removing stale run-command resource '$AVD_RUNCMD_NAME'"
  az vm run-command delete -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" --yes -o none
fi

log "dispatching install (async; poll every ${AVD_POLL_INTERVAL_SECONDS}s, cap ${AVD_RUNCMD_TIMEOUT_SECONDS}s)"
az vm run-command create \
  -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" --name "$AVD_RUNCMD_NAME" \
  --subscription "$AVD_SUBSCRIPTION_ID" \
  --script "$script_body" \
  --parameters "${runcmd_params[@]}" \
  --timeout-in-seconds "$AVD_RUNCMD_TIMEOUT_SECONDS" \
  --async-execution true \
  -o none

# ------------------------------------------------------------------ poll ----
deadline=$(( $(date +%s) + AVD_RUNCMD_TIMEOUT_SECONDS + 300 ))
exec_state=""
while (( $(date +%s) < deadline )); do
  sleep "$AVD_POLL_INTERVAL_SECONDS"
  exec_state=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
                 --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" \
                 --instance-view --query "instanceView.executionState" -o tsv 2>/dev/null || print -r -- "Unknown")
  log "execution state: $exec_state"
  [[ "$exec_state" == (Succeeded|Failed|TimedOut|Canceled) ]] && break
done

view=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
         --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" \
         --instance-view -o json)

# Markers must be read from the guest's stdout ALONE. The full resource JSON
# also carries `source.script` - our own script text - whose literal
# "AVD_REASON=$Reason" lines match these greps and make every run look like it
# reported something. Ask the server for just the output field.
guest_out=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
              --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" \
              --instance-view --query "instanceView.output" -o tsv 2>/dev/null || true)
guest_err=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
              --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" \
              --instance-view --query "instanceView.error" -o tsv 2>/dev/null || true)

log_dir="${AVD_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$log_dir"
logfile="$log_dir/${AVD_RUNCMD_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"
print -r -- "$view" > "$logfile"
log "raw instance view saved to $logfile"

# ------------------------------------------------- verdict: silence != pass --
if [[ "$exec_state" != "Succeeded" ]]; then
  [[ -n "$guest_err" ]] && warn "guest stderr: ${guest_err:0:800}"
  die "run-command execution state was '$exec_state' (expected Succeeded). See $logfile"
  exit 1
fi

if ! print -r -- "$guest_out" | grep -q 'AVD_STATUS='; then
  [[ -n "$guest_err" ]] && warn "guest stderr: ${guest_err:0:800}"
  die "guest produced no AVD_STATUS marker - treating as FAILURE, not success. See $logfile"
  exit 1
fi

if ! print -r -- "$guest_out" | grep -q 'AVD_STATUS=success'; then
  reason=$(print -r -- "$guest_out" | grep -o 'AVD_REASON=.*' | head -1)
  die "guest reported failure. ${reason:-no reason given} See $logfile"
  exit 1
fi

reported_version=$(print -r -- "$guest_out" | grep -o 'AVD_VERSION=[0-9.]*' | head -1 | cut -d= -f2)
if [[ -z "$reported_version" ]]; then
  die "guest reported success without a version - refusing to trust it. See $logfile"
  exit 1
fi

# AVD_VERSION carries catalog.productDisplayVersion, so this is an exact match
# rather than a prefix test.
if (( ! ALLOW_DRIFT )) && [[ "$reported_version" != "$VS_EXPECTED_VERSION" ]]; then
  die "guest installed $reported_version but config expects $VS_EXPECTED_VERSION. See $logfile"
  exit 1
fi

log "SUCCESS: Visual Studio $reported_version installed and verified on $AVD_VM_NAME"
if print -r -- "$guest_out" | grep -q 'AVD_REBOOT_REQUIRED=true'; then
  warn "a reboot is required before sealing the image"
fi
log "next: verify interactively over RDP, then seal/capture the image in Nerdio"
