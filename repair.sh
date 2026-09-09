#!/usr/bin/env zsh
#
# Remove a Visual Studio instance from the image VM by installation path.
#
#   ./repair.sh --path 'C:\Program'      remove the instance at that path
#   ./repair.sh --path 'C:\Program' --keep-dir
#
# Written for the case where an install landed in the wrong directory. Run this,
# then ./deploy.sh for a clean install.
#
# Like deploy.sh, this refuses to call an empty guest report a success.

emulate -L zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/common.sh"

TARGET_PATH="" KEEP_DIR=0 ASSUME_YES=0
while (( $# )); do
  case "$1" in
    --path)     shift; TARGET_PATH="$1" ;;
    --keep-dir) KEEP_DIR=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

[[ -n "$TARGET_PATH" ]] || { die "--path is required (e.g. --path 'C:\\Program')"; exit 2 }

load_config
require_az

PS_SCRIPT="$SCRIPT_DIR/scripts/Uninstall-VisualStudio.ps1"
[[ -f "$PS_SCRIPT" ]] || { die "missing $PS_SCRIPT"; exit 1 }

runcmd_name="uninstall-vs"
: "${AVD_POLL_INTERVAL_SECONDS:=30}"
timeout_seconds=3600

log "target: $AVD_VM_NAME ($AVD_RESOURCE_GROUP)"
log "will remove the Visual Studio instance installed at: $TARGET_PATH"

power=$(vm_power_state || true)
[[ "$power" == *running* ]] || { die "VM is '${power:-unknown}' - start it first"; exit 1 }

if (( ! ASSUME_YES )); then
  print -n "Uninstall Visual Studio at '$TARGET_PATH' on $AVD_VM_NAME? [y/N] "
  read -r reply
  [[ "$reply" == [yY]* ]] || { log "aborted"; exit 0 }
fi

typeset -a runcmd_params
runcmd_params=( "TargetInstallPath=${TARGET_PATH}" )
(( KEEP_DIR )) && runcmd_params+=( "RemoveEmptyDirectory=false" )

if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
  log "removing stale run-command resource '$runcmd_name'"
  az vm run-command delete -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" --yes -o none
fi

script_body="$(<"$PS_SCRIPT")"

log "dispatching uninstall (this typically takes 5-15 minutes)"
az vm run-command create \
  -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" --name "$runcmd_name" \
  --subscription "$AVD_SUBSCRIPTION_ID" \
  --script "$script_body" \
  --parameters "${runcmd_params[@]}" \
  --timeout-in-seconds "$timeout_seconds" \
  --async-execution true \
  -o none

deadline=$(( $(date +%s) + timeout_seconds + 300 ))
exec_state=""
while (( $(date +%s) < deadline )); do
  sleep "$AVD_POLL_INTERVAL_SECONDS"
  exec_state=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
                 --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" \
                 --instance-view --query "instanceView.executionState" -o tsv 2>/dev/null || print -r -- "Unknown")
  log "execution state: $exec_state"
  [[ "$exec_state" == (Succeeded|Failed|TimedOut|Canceled) ]] && break
done

log_dir="${AVD_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$log_dir"
logfile="$log_dir/${runcmd_name}-$(date -u +%Y%m%dT%H%M%SZ).log"
az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
   --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" --instance-view -o json > "$logfile"
log "raw instance view saved to $logfile"

guest_out=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
              --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" \
              --instance-view --query "instanceView.output" -o tsv 2>/dev/null || true)

if [[ "$exec_state" != "Succeeded" ]]; then
  die "run-command execution state was '$exec_state'. See $logfile"
  exit 1
fi
if ! print -r -- "$guest_out" | grep -q 'AVD_STATUS='; then
  die "guest produced no AVD_STATUS marker - treating as FAILURE. See $logfile"
  exit 1
fi
if ! print -r -- "$guest_out" | grep -q 'AVD_STATUS=success'; then
  reason=$(print -r -- "$guest_out" | grep -o 'AVD_REASON=.*' | head -1)
  die "guest reported failure. ${reason:-no reason given} See $logfile"
  exit 1
fi

log "SUCCESS: $(print -r -- "$guest_out" | grep -o 'AVD_REASON=.*' | head -1)"
log "next: ./deploy.sh for a clean install"
