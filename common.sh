#!/usr/bin/env zsh
# Shared helpers for the AVD image scripts. Sourced, not executed.

emulate -L zsh
setopt err_return no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"

log()  { print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO]  $*" }
warn() { print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN]  $*" >&2 }
die()  { print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) [ERROR] $*" >&2; return 1 }

load_config() {
  local cfg="${AVD_CONFIG:-$SCRIPT_DIR/config.env}"
  if [[ ! -f "$cfg" ]]; then
    die "config not found: $cfg
  Create it from the template and fill in your own values:
      cp $SCRIPT_DIR/config.env.example $SCRIPT_DIR/config.env"
    return 1
  fi
  set -a; source "$cfg"; set +a

  local v
  for v in AVD_SUBSCRIPTION_ID AVD_RESOURCE_GROUP AVD_VM_NAME VS_EXPECTED_VERSION; do
    [[ -n "${(P)v:-}" ]] || { die "config is missing $v (see config.env.example)"; return 1 }
  done

  # A copied-but-unedited template is a common first-run mistake, and the error
  # from Azure would otherwise be an opaque "resource not found".
  for v in AVD_SUBSCRIPTION_ID AVD_RESOURCE_GROUP AVD_VM_NAME; do
    if [[ "${(P)v}" == REPLACE_WITH_* ]]; then
      die "$v is still the placeholder from config.env.example - set it to your own value in $cfg"
      return 1
    fi
  done
}

require_az() {
  command -v az >/dev/null 2>&1 || { die "az CLI not found on PATH"; return 1 }
  az account show >/dev/null 2>&1 || { die "not logged in to Azure - run: az login"; return 1 }
}

az_vm() { az "$@" --subscription "$AVD_SUBSCRIPTION_ID" }

vm_power_state() {
  az vm get-instance-view -g "$AVD_RESOURCE_GROUP" -n "$AVD_VM_NAME" \
     --subscription "$AVD_SUBSCRIPTION_ID" \
     --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null
}

# Azure needs the guest agent up, not just the VM powered on, or run-command
# silently sits in "Pending" forever.
wait_for_agent() {
  local deadline=$(( $(date +%s) + ${1:-300} )) state
  while (( $(date +%s) < deadline )); do
    state=$(az vm get-instance-view -g "$AVD_RESOURCE_GROUP" -n "$AVD_VM_NAME" \
              --subscription "$AVD_SUBSCRIPTION_ID" \
              --query "instanceView.vmAgent.statuses[0].displayStatus | [0]" -o tsv 2>/dev/null || true)
    [[ "$state" == *Ready* ]] && { log "guest agent ready"; return 0 }
    log "waiting for guest agent (currently: ${state:-unknown})"
    sleep 15
  done
  die "guest agent did not become ready in time"
}
