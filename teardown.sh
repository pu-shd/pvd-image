#!/usr/bin/env zsh
#
# Clean up after an image session.
#
#   ./teardown.sh                 remove the tooling's run-command resources only
#   ./teardown.sh --deallocate    also deallocate the VM (stops compute billing)
#   ./teardown.sh --yes           skip the confirmation prompt
#
# ORDER MATTERS: Azure refuses to modify extensions on a stopped VM, so the
# run-command resource must be deleted while the VM is still running. Running
# this with --deallocate before you shut the VM down does both in the right
# order. If the VM is already deallocated, see the guidance this prints.
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
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *)            die "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

load_config
require_az

# --- work out what there is to do, before asking or acting ------------------
power=$(vm_power_state || true)
log "power state: ${power:-unknown}"

# Every run-command resource the drivers create (deploy, shortcuts, pykx).
typeset -a present
for name in ${(z)$(tooling_runcmd_names)}; do
  if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
       --name "$name" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
    present+=( "$name" )
  fi
done
runcmd_exists=$(( ${#present} > 0 ))
listed="'${(j:', ':)present}'"

if (( ! runcmd_exists )); then
  log "no run-command resources from this tooling - nothing to remove"
fi

# Deleting a managed run command is an extension operation, and Azure rejects
# those on a stopped VM with:
#   (OperationNotAllowed) Cannot modify extensions in the VM when the VM is not running.
# Say so up front rather than prompting and then failing.
if (( runcmd_exists )) && [[ "$power" != *running* ]]; then
  warn "the run-command resource(s) $listed cannot be deleted while the VM is '${power:-unknown}'."
  warn "Azure rejects extension changes on a stopped VM."
  warn ""
  warn "Your options, in the order most people want them:"
  warn "  1. Leave them. A run-command resource costs nothing. It counts against the"
  warn "     limit of 25 per VM, and it disappears when the VM is deleted."
  warn "  2. Delete them later, together with the VM, if the VM is disposable."
  warn "  3. Start the VM, re-run this, then deallocate:"
  warn "         az vm start -g $AVD_RESOURCE_GROUP -n $AVD_VM_NAME --subscription $AVD_SUBSCRIPTION_ID"
  warn "         ./teardown.sh --deallocate"
  warn ""
  warn "Do NOT choose 3 if the VM has been sysprepped by a 'set as image' capture:"
  warn "a generalised VM boots into OOBE and is not the machine you customised."
  warn "Check with: az image show -g <rg> -n <image> --query storageProfile.osDisk.osState -o tsv"
  warn ""
  warn "Next time, run './teardown.sh --deallocate' while the VM is still running"
  warn "so the resources are removed before the VM stops."
  die "cannot remove $listed while the VM is not running"
  exit 1
fi

# --- confirm ----------------------------------------------------------------
if (( ! ASSUME_YES )) && { (( runcmd_exists )) || (( DEALLOCATE )); }; then
  print -n "On $AVD_VM_NAME:"
  (( runcmd_exists )) && print -n " remove run-command(s) $listed"
  (( runcmd_exists )) && (( DEALLOCATE )) && print -n " and"
  (( DEALLOCATE )) && print -n " DEALLOCATE the VM"
  print -n "? [y/N] "
  read -r reply
  [[ "$reply" == [yY]* ]] || { log "aborted"; exit 0 }
fi

# --- act --------------------------------------------------------------------
for name in "${present[@]}"; do
  log "deleting run-command resource '$name'"
  az vm run-command delete -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$name" --subscription "$AVD_SUBSCRIPTION_ID" --yes -o none

  # Verify rather than trusting the call.
  if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
       --name "$name" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
    die "'$name' still exists after the delete call"
    exit 1
  fi
  log "confirmed removed: $name"
done

if (( DEALLOCATE )); then
  if [[ "$power" == *deallocated* ]]; then
    log "VM is already deallocated - nothing to do"
  else
    log "deallocating $AVD_VM_NAME"
    az vm deallocate -g "$AVD_RESOURCE_GROUP" -n "$AVD_VM_NAME" --subscription "$AVD_SUBSCRIPTION_ID" -o none
    log "power state now: $(vm_power_state || print -r -- unknown)"
  fi
fi

log "teardown complete"
