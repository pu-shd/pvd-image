#!/usr/bin/env zsh
#
# Clean up after an image session.
#
#   ./teardown.sh                 remove the run-command resource only
#   ./teardown.sh --deallocate    also deallocate the VM (stops billing for compute)
#   ./teardown.sh --yes           skip the confirmation prompt
#
# This never deletes the VM, its disks, or the image. Deallocating an image VM
# is the normal resting state between image sessions.

emulate -L zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/common.sh"

DEALLOCATE=0 ASSUME_YES=0
while (( $# )); do
  case "$1" in
    --deallocate) DEALLOCATE=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,11p' "$0"; exit 0 ;;
    *)            die "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

load_config
require_az
: "${AVD_RUNCMD_NAME:=install-vs-cpp}"

if (( ! ASSUME_YES )); then
  print -n "Remove run-command '$AVD_RUNCMD_NAME'"
  (( DEALLOCATE )) && print -n " and DEALLOCATE $AVD_VM_NAME"
  print -n "? [y/N] "
  read -r reply
  [[ "$reply" == [yY]* ]] || { log "aborted"; exit 0 }
fi

if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
  log "deleting run-command resource '$AVD_RUNCMD_NAME'"
  az vm run-command delete -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$AVD_RUNCMD_NAME" --subscription "$AVD_SUBSCRIPTION_ID" --yes -o none
else
  log "no run-command resource named '$AVD_RUNCMD_NAME' - nothing to remove"
fi

if (( DEALLOCATE )); then
  log "deallocating $AVD_VM_NAME"
  az vm deallocate -g "$AVD_RESOURCE_GROUP" -n "$AVD_VM_NAME" --subscription "$AVD_SUBSCRIPTION_ID" -o none
  log "power state now: $(vm_power_state || print -r -- unknown)"
fi

log "teardown complete"
