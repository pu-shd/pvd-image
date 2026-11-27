#!/usr/bin/env zsh
#
# Install a PyKX query client for every user of the AVD image VM, so students
# can query a kdb+/q server without installing anything themselves.
#
#   ./pykx.sh [--start] [--skip-check] [--dry-run]
#   ./pykx.sh --remove
#
# --start       start the VM if it is deallocated
# --skip-check  do not query PYKX_CHECK_HOST:PYKX_CHECK_PORT after installing
# --remove      remove the client, its PATH entry and the desktop file
# --dry-run     print what would run, change nothing
#
# Versions come from config.env (PYKX_*). Exits non-zero unless the guest
# reports success, the versions it reports match config.env, and, when a check
# host is configured, a query to it succeeded.

emulate -L zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/common.sh"

START_VM=0 SKIP_CHECK=0 DRY_RUN=0 MODE="install"
while (( $# )); do
  case "$1" in
    --start)      START_VM=1 ;;
    --skip-check) SKIP_CHECK=1 ;;
    --remove)     MODE="remove" ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    sed -n '2,17p' "$0"; exit 0 ;;
    *)            die "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

if [[ "$MODE" == install ]]; then
  load_config PYKX_VERSION PYKX_PYTHON_VERSION PYKX_UV_VERSION PYKX_UV_SHA256
else
  load_config
fi
require_az

: "${PYKX_INSTALL_PATH:=C:\\Program Files\\PyKX}"
: "${PYKX_COMMAND_PREFIX:=pykx}"
: "${PYKX_EXTRA_PACKAGES:=}"
: "${PYKX_CHECK_HOST:=}"
: "${PYKX_CHECK_PORT:=}"
: "${PYKX_LICENSE_FOLDER:=kx}"
: "${PYKX_DESKTOP_README:=}"
: "${AVD_POLL_INTERVAL_SECONDS:=15}"
(( SKIP_CHECK )) && PYKX_CHECK_HOST="" PYKX_CHECK_PORT=""

# The guest validates these too; checking here fails faster and keeps odd
# values out of the run-command resource altogether.
if [[ "$MODE" == install ]]; then
  [[ "$PYKX_VERSION" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]]        || { die "PYKX_VERSION '$PYKX_VERSION' is not a version like 4.2.0"; exit 2 }
  [[ "$PYKX_PYTHON_VERSION" =~ '^3\.[0-9]+(\.[0-9]+)?$' ]]  || { die "PYKX_PYTHON_VERSION '$PYKX_PYTHON_VERSION' is not a version like 3.12"; exit 2 }
  [[ "$PYKX_UV_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]    || { die "PYKX_UV_VERSION '$PYKX_UV_VERSION' is not a version like 0.8.0"; exit 2 }
  [[ "$PYKX_UV_SHA256" =~ '^[0-9a-fA-F]{64}$' ]]            || { die "PYKX_UV_SHA256 is not a 64-character hex SHA-256"; exit 2 }
  [[ "$PYKX_COMMAND_PREFIX" =~ '^[A-Za-z][A-Za-z0-9_-]{0,31}$' ]] || { die "PYKX_COMMAND_PREFIX '$PYKX_COMMAND_PREFIX' must be letters, digits, '-' or '_'"; exit 2 }
  [[ "$PYKX_LICENSE_FOLDER" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' && "$PYKX_LICENSE_FOLDER" != *..* ]] \
    || { die "PYKX_LICENSE_FOLDER '$PYKX_LICENSE_FOLDER' must be one folder name"; exit 2 }
  if [[ -n "$PYKX_CHECK_HOST" || -n "$PYKX_CHECK_PORT" ]]; then
    [[ "$PYKX_CHECK_HOST" =~ '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$' ]] || { die "PYKX_CHECK_HOST '$PYKX_CHECK_HOST' is not a host name"; exit 2 }
    [[ "$PYKX_CHECK_PORT" =~ '^[0-9]{1,5}$' ]] && (( PYKX_CHECK_PORT >= 1 && PYKX_CHECK_PORT <= 65535 )) \
      || { die "PYKX_CHECK_PORT '$PYKX_CHECK_PORT' is not a port number"; exit 2 }
  fi
fi

# The desktop text file: a path in the config repo, relative to config.env.
# Sent as base64, so quotes and backticks in its examples survive run-command
# parameter passing.
readme_name="" readme_b64=""
if [[ -n "$PYKX_DESKTOP_README" ]]; then
  cfg_dir="${${AVD_CONFIG:-$SCRIPT_DIR/config.env}:A:h}"
  readme_path="$PYKX_DESKTOP_README"
  [[ "$readme_path" == /* ]] || readme_path="$cfg_dir/$readme_path"
  [[ -f "$readme_path" ]] || { die "PYKX_DESKTOP_README not found: $readme_path"; exit 2 }
  readme_name="${readme_path:t}"
  [[ "$readme_name" =~ '^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,79}\.txt$' ]] \
    || { die "desktop file name '$readme_name' must be a plain .txt name"; exit 2 }
  (( $(wc -c < "$readme_path") <= 65536 )) || { die "$readme_path is larger than 64 KB"; exit 2 }
  readme_b64="$(base64 < "$readme_path" | tr -d '\n')"
fi

PS_SCRIPT="$SCRIPT_DIR/scripts/Install-PyKXClient.ps1"
[[ -f "$PS_SCRIPT" ]] || { die "missing $PS_SCRIPT"; exit 1 }

runcmd_name="install-pykx-client"
timeout_seconds=1800

typeset -a runcmd_params
runcmd_params=( "Action=$MODE" "InstallPath=$PYKX_INSTALL_PATH" )
[[ -n "$readme_name" ]] && runcmd_params+=( "DesktopReadme=$readme_name" )
if [[ "$MODE" == install ]]; then
  runcmd_params+=(
    "PykxVersion=$PYKX_VERSION" "PythonVersion=$PYKX_PYTHON_VERSION"
    "UvVersion=$PYKX_UV_VERSION" "UvSha256=$PYKX_UV_SHA256"
    "CommandPrefix=$PYKX_COMMAND_PREFIX" "LicenseFolder=$PYKX_LICENSE_FOLDER"
  )
  [[ -n "$readme_b64" ]] && runcmd_params+=( "DesktopReadmeBase64=$readme_b64" )
  [[ -n "$PYKX_EXTRA_PACKAGES" ]] && runcmd_params+=( "ExtraPackages=$PYKX_EXTRA_PACKAGES" )
  [[ -n "$PYKX_CHECK_HOST" ]] && runcmd_params+=( "CheckHost=$PYKX_CHECK_HOST" "CheckPort=$PYKX_CHECK_PORT" )
fi

log "target: $AVD_VM_NAME ($AVD_RESOURCE_GROUP)"
log "mode: $MODE, into $PYKX_INSTALL_PATH"
if [[ "$MODE" == install ]]; then
  log "PyKX $PYKX_VERSION, Python $PYKX_PYTHON_VERSION, uv $PYKX_UV_VERSION${PYKX_EXTRA_PACKAGES:+, plus $PYKX_EXTRA_PACKAGES}"
  if [[ -n "$PYKX_CHECK_HOST" ]]; then log "check: $PYKX_CHECK_HOST:$PYKX_CHECK_PORT"; else log "check: none"; fi
  log "user licences: OneDrive\\$PYKX_LICENSE_FOLDER or %USERPROFILE%\\$PYKX_LICENSE_FOLDER"
  log "desktop file: ${readme_name:-none}"
fi

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
  elif (( DRY_RUN )); then
    warn "[dry-run] VM is '${power:-unknown}'; a real run needs it running (start it from Nerdio, or pass --start)"
  else
    die "VM is '${power:-unknown}'. Start it from Nerdio (preferred) or pass --start."
    exit 1
  fi
fi

if (( DRY_RUN )); then
  log "[dry-run] would create run-command '$runcmd_name' (timeout ${timeout_seconds}s)"
  typeset -a shown=()
  for p in "${runcmd_params[@]}"; do
    [[ "$p" == DesktopReadmeBase64=* ]] && p="DesktopReadmeBase64=<${#readme_b64} chars>"
    shown+=( "$p" )
  done
  log "[dry-run] parameters: ${shown[*]}"
  exit 0
fi

if az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" -o none 2>/dev/null; then
  log "removing stale run-command resource '$runcmd_name'"
  az vm run-command delete -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
     --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" --yes -o none
fi

script_body="$(<"$PS_SCRIPT")"

log "dispatching (usually one to three minutes)"
az vm run-command create \
  -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" --name "$runcmd_name" \
  --subscription "$AVD_SUBSCRIPTION_ID" \
  --script "$script_body" \
  --parameters "${runcmd_params[@]}" \
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

# Markers from the guest's stdout alone, never the full resource JSON, which
# echoes this script's own marker strings back in source.script.
guest_out=$(az vm run-command show -g "$AVD_RESOURCE_GROUP" --vm-name "$AVD_VM_NAME" \
              --name "$runcmd_name" --subscription "$AVD_SUBSCRIPTION_ID" \
              --instance-view --query "instanceView.output" -o tsv 2>/dev/null || true)

marker() { print -r -- "$guest_out" | grep -o "^$1=.*" | head -1 | cut -d= -f2- | tr -d '\r' }

if [[ "$exec_state" != "Succeeded" ]]; then
  die "run-command execution state was '$exec_state'. See $logfile"
  exit 1
fi
if ! print -r -- "$guest_out" | grep -q 'AVD_STATUS='; then
  die "guest produced no AVD_STATUS marker - treating as FAILURE. See $logfile"
  exit 1
fi
if [[ "$(marker AVD_STATUS)" != success ]]; then
  die "guest reported failure. $(marker AVD_REASON) See $logfile"
  exit 1
fi

if [[ "$MODE" == remove ]]; then
  log "SUCCESS: PyKX client removed from $AVD_VM_NAME"
  exit 0
fi

got_pykx=$(marker AVD_PYKX_VERSION)
got_python=$(marker AVD_PYTHON_VERSION)
got_check=$(marker AVD_CHECK)
if [[ "$got_pykx" != "$PYKX_VERSION" ]]; then
  die "guest reports PyKX '${got_pykx}' but config expects $PYKX_VERSION. See $logfile"
  exit 1
fi
if [[ "$got_python" != "$PYKX_PYTHON_VERSION" && "$got_python" != "$PYKX_PYTHON_VERSION".* ]]; then
  die "guest reports Python '${got_python}' but config expects $PYKX_PYTHON_VERSION. See $logfile"
  exit 1
fi
if [[ -n "$readme_name" && "$(marker AVD_README)" != "$readme_name" ]]; then
  die "asked for the desktop file '$readme_name', but the guest reports '$(marker AVD_README)'. See $logfile"
  exit 1
fi
if [[ -n "$PYKX_CHECK_HOST" && "$got_check" != ok ]]; then
  die "a check against $PYKX_CHECK_HOST:$PYKX_CHECK_PORT was asked for, but the guest reports '${got_check}'. See $logfile"
  exit 1
fi

log "SUCCESS: PyKX $got_pykx on Python $got_python installed and verified on $AVD_VM_NAME"
if [[ "$got_check" == ok ]]; then
  log "queried $PYKX_CHECK_HOST:$PYKX_CHECK_PORT from the VM"
fi
log "users run: ${PYKX_COMMAND_PREFIX}-python${PYKX_CHECK_HOST:+, ${PYKX_COMMAND_PREFIX}-test}"
[[ -n "$readme_name" ]] && log "desktop file: $readme_name"
log "next: ./teardown.sh --deallocate while the VM is running, then seal in Nerdio"
