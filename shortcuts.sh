#!/usr/bin/env zsh
#
# Put shortcuts on the all-users desktop of the AVD image VM.
#
#   ./shortcuts.sh                      apply AVD_SHORTCUTS from config.env
#   ./shortcuts.sh --remove             remove those same shortcuts
#   ./shortcuts.sh --spec 'Excel=C:\...\EXCEL.EXE;Word=C:\...\WINWORD.EXE'
#   ./shortcuts.sh --dry-run
#
# Writes to C:\Users\Public\Desktop, which every user of a multi-session host
# sees. Applies the same rule as deploy.sh: an empty guest report is a failure.

emulate -L zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/common.sh"

SPEC_OVERRIDE="" MODE="create" DRY_RUN=0
while (( $# )); do
  case "$1" in
    --spec)    shift; SPEC_OVERRIDE="$1" ;;
    --remove)  MODE="remove" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

load_config
require_az

spec="${SPEC_OVERRIDE:-${AVD_SHORTCUTS:-}}"
[[ -n "$spec" ]] || { die "no shortcuts given: set AVD_SHORTCUTS in config.env or pass --spec"; exit 2 }

PS_SCRIPT="$SCRIPT_DIR/scripts/Set-PublicDesktopShortcuts.ps1"
[[ -f "$PS_SCRIPT" ]] || { die "missing $PS_SCRIPT"; exit 1 }

runcmd_name="set-desktop-shortcuts"
: "${AVD_POLL_INTERVAL_SECONDS:=15}"
timeout_seconds=600

# One shortcut per ';'-separated pair; used to check the guest did them all.
expected_count=$(print -r -- "$spec" | tr ';' '\n' | grep -c '=' || true)

log "target: $AVD_VM_NAME ($AVD_RESOURCE_GROUP)"
log "mode: $MODE"
log "shortcuts ($expected_count): $spec"

if (( DRY_RUN )); then
  log "[dry-run] would create run-command '$runcmd_name'"
  log "[dry-run] parameters: Shortcuts=$spec Action=$MODE"
  exit 0
fi

power=$(vm_power_state || true)
[[ "$power" == *running* ]] || { die "VM is '${power:-unknown}' - start it first (./deploy.sh --start starts it)"; exit 1 }

if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
  log "removing stale run-command resource '$runcmd_name'"
  az vm run-command delete -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" --yes -o none
fi

script_body="$(<"$PS_SCRIPT")"

log "dispatching (this is quick - seconds, not minutes)"
az vm run-command create \
  -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" --name "$runcmd_name" \
  --subscription "$AVD_SUBSCRIPTION_ID" \
  --script "$script_body" \
  --parameters "Shortcuts=${spec}" "Action=${MODE}" \
  --timeout-in-seconds "$timeout_seconds" \
  -o none

exec_state=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
               --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" \
               --instance-view --query "instanceView.executionState" -o tsv 2>/dev/null || print -r -- Unknown)
log "execution state: $exec_state"

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

reported=$(print -r -- "$guest_out" | grep -o 'AVD_SHORTCUT_COUNT=[0-9]*' | head -1 | cut -d= -f2)
if [[ "$reported" != "$expected_count" ]]; then
  die "asked for $expected_count shortcut(s) but the guest reported $reported. See $logfile"
  exit 1
fi

log "SUCCESS: $MODE completed for $reported shortcut(s) on $AVD_VM_NAME"
print -r -- "$guest_out" | grep -o 'AVD_SHORTCUT_OK=.*' | while read -r line; do
  log "  ${line#AVD_SHORTCUT_OK=}"
done
