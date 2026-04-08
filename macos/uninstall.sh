#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — macOS Uninstaller
# =============================================================================
#
# Removes the FalconPulsar stack on macOS:
#
#   - Stops and removes containers + the falconpulsar bridge network
#   - Optionally deletes ~/falconpulsar/ (compose.yml, .env, data/) — asks
#
# Does NOT touch the container runtime itself (Docker Desktop / Colima /
# Rancher / OrbStack) or the pulled images (use `docker image prune` if you
# want them gone).
#
# Usage:
#   bash uninstall.sh                # interactive
#   bash uninstall.sh --purge --yes  # delete everything, no prompts
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared/lib/common.sh
. "${REPO_ROOT}/shared/lib/common.sh"

trap 'on_error $LINENO' ERR

FP_HOME="${FP_HOME:-${HOME}/falconpulsar}"
FP_PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --home)   FP_HOME="$2"; shift 2 ;;
        --purge)  FP_PURGE=1; shift ;;
        -y|--yes) FP_ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: uninstall.sh [options]
  --home <path>   Stack directory (default: ~/falconpulsar)
  --purge         Also delete the data directory
  --yes, -y       Assume yes to all prompts
EOF
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done
export FP_ASSUME_YES="${FP_ASSUME_YES:-0}"

require_not_root

if [ ! -d "$FP_HOME" ]; then
    log_warn "${FP_HOME} does not exist — nothing to uninstall"
    exit 0
fi

log_step "stopping the stack"
if [ -f "${FP_HOME}/compose.yml" ]; then
    ( cd "$FP_HOME" && docker compose down --remove-orphans ) || \
        log_warn "docker compose down failed — continuing anyway"
fi

if [ "$FP_PURGE" -eq 1 ] || confirm "delete ${FP_HOME} (including the time-series database)?" default-no; then
    log_step "removing ${FP_HOME}"
    rm -rf "$FP_HOME"
    log_success "deleted ${FP_HOME}"
else
    log_info "${FP_HOME} preserved. Re-run with --purge to delete it."
fi

log_success "uninstall complete"
