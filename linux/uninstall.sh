#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — Linux Uninstaller
# =============================================================================
#
# Removes everything the install.sh put in place:
#
#   - Stops and removes the docker containers + the falconpulsar bridge network
#   - Disables the systemd user unit (if installed) and disables linger
#   - Optionally deletes ${FP_HOME} (compose.yml, .env, data/) — asks first
#   - Optionally removes the falconpulsar system user — asks first
#
# Does NOT touch:
#   - Docker Engine itself (we don't know if you installed it for FP only)
#   - Pulled images on disk (use `docker image prune` if you want them gone)
#
# Usage:
#   sudo bash uninstall.sh                    # interactive
#   sudo bash uninstall.sh --purge --yes      # delete data + user, no prompts
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared/lib/common.sh
. "${REPO_ROOT}/shared/lib/common.sh"

trap 'on_error $LINENO' ERR

FP_USER="${FP_USER:-falconpulsar}"
FP_HOME="${FP_HOME:-/home/${FP_USER}}"
FP_PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --user)   FP_USER="$2"; FP_HOME="/home/${FP_USER}"; shift 2 ;;
        --purge)  FP_PURGE=1; shift ;;
        -y|--yes) FP_ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: uninstall.sh [options]
  --user <name>   System user to remove (default: falconpulsar)
  --purge         Also delete data directory and the system user
  --yes, -y       Assume yes to all prompts
EOF
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done
export FP_ASSUME_YES="${FP_ASSUME_YES:-0}"

require_root

if ! id "$FP_USER" >/dev/null 2>&1; then
    log_warn "user ${FP_USER} does not exist — nothing to uninstall"
    exit 0
fi

FP_UID="$(id -u "$FP_USER")"

log_step "stopping the stack"
if [ -f "${FP_HOME}/compose.yml" ]; then
    sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose down --remove-orphans" || \
        log_warn "docker compose down failed — continuing anyway"
else
    log_info "no compose.yml in ${FP_HOME}, skipping docker compose down"
fi

log_step "removing systemd user unit (if any)"
UNIT_FILE="${FP_HOME}/.config/systemd/user/falconpulsar.service"
if [ -f "$UNIT_FILE" ]; then
    sudo -u "$FP_USER" -H XDG_RUNTIME_DIR="/run/user/${FP_UID}" \
        systemctl --user disable --now falconpulsar.service 2>/dev/null || true
    rm -f "$UNIT_FILE"
    loginctl disable-linger "$FP_USER" 2>/dev/null || true
    log_success "systemd unit removed"
else
    log_info "no systemd unit found"
fi

if [ "$FP_PURGE" -eq 1 ] || confirm "delete ${FP_HOME} (including the time-series database)?" default-no; then
    log_step "removing ${FP_HOME}"
    rm -rf "${FP_HOME}"
    log_success "deleted ${FP_HOME}"

    if [ "$FP_PURGE" -eq 1 ] || confirm "remove the ${FP_USER} system user?" default-no; then
        log_step "removing user ${FP_USER}"
        userdel "$FP_USER" 2>/dev/null || true
        log_success "user ${FP_USER} removed"
    fi
else
    log_info "${FP_HOME} preserved. Re-run with --purge to delete it."
fi

log_success "uninstall complete"
