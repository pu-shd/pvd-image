#!/usr/bin/env zsh
#
# Re-run the installer against the image VM to pick up a newer Stable release,
# or to repair a partial install.
#
#   ./update.sh --to 18.11.0     bump the expected version, then install/verify
#   ./update.sh                  re-run against the version already in config.env
#
# The guest script is idempotent: if the requested version is already present
# with a working C++ toolchain it exits success without touching anything.
# Otherwise it runs the installer in 'modify' mode against the existing install.

emulate -L zsh
setopt err_exit no_unset pipe_fail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/common.sh"

TARGET_VERSION=""
PASSTHRU=()
while (( $# )); do
  case "$1" in
    --to)      shift; TARGET_VERSION="$1" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *)         PASSTHRU+=("$1") ;;
  esac
  shift
done

load_config VS_EXPECTED_VERSION

if [[ -n "$TARGET_VERSION" ]]; then
  [[ "$TARGET_VERSION" == <->.<->.<-> ]] || { die "--to expects a version like 18.11.0"; exit 2 }
  log "bumping VS_EXPECTED_VERSION: $VS_EXPECTED_VERSION -> $TARGET_VERSION"

  # Keep config.env as the single source of truth so the next deploy agrees.
  cp "$SCRIPT_DIR/config.env" "$SCRIPT_DIR/config.env.bak"
  sed -i '' -e "s/^VS_EXPECTED_VERSION=.*/VS_EXPECTED_VERSION=\"$TARGET_VERSION\"/" "$SCRIPT_DIR/config.env"
  log "config.env updated (previous saved as config.env.bak)"
fi

log "handing off to deploy.sh"
exec "$SCRIPT_DIR/deploy.sh" --start "${PASSTHRU[@]}"
