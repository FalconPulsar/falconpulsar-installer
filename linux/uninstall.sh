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

# Prefer the shared library; fall back to inline helpers if the script is
# running standalone (e.g. copied to /tmp by `fp` before running, so the
# stack-dir delete doesn't yank bash's own source file).
if [ -f "${REPO_ROOT}/shared/lib/common.sh" ]; then
    # shellcheck source=../shared/lib/common.sh
    . "${REPO_ROOT}/shared/lib/common.sh"
else
    log_step()    { echo; echo "==> $1"; }
    log_info()    { echo "[info] $1"; }
    log_success() { echo "[ok] $1"; }
    log_warn()    { echo "[warn] $1"; }
    log_error()   { echo "[error] $1" >&2; }
    die()         { log_error "$1"; exit 1; }
    confirm()     { return 0; }
    require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }
    on_error()    { log_error "failed at line $1"; }
fi

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

# Make sure our cwd is not inside $FP_HOME before rm happens — guards
# against deleting-script-while-reading if bash was invoked from there.
cd / 2>/dev/null

log_step "stopping the stack"
if [ -f "${FP_HOME}/compose.yml" ]; then
    if [ "$FP_PURGE" -eq 1 ]; then
        # --volumes removes named Docker volumes declared in compose.yml
        sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose --profile ai down --remove-orphans --volumes" || \
            log_warn "docker compose down failed — continuing anyway"
    else
        sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose --profile ai down --remove-orphans" || \
            log_warn "docker compose down failed — continuing anyway"
    fi
else
    log_info "no compose.yml in ${FP_HOME}, skipping docker compose down"
fi

log_step "removing Docker images"
# Wrap in `set +e` — failing image queries with errexit+pipefail abort the
# whole script. GNU xargs does have -r but we use `while read` for parity.
set +e
if [ -f "${FP_HOME}/compose.yml" ]; then
    IMAGES="$(sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose config --images" 2>/dev/null | sort -u)"
    if [ -n "$IMAGES" ]; then
        echo "$IMAGES" | while IFS= read -r img; do
            [ -n "$img" ] && sudo -u "$FP_USER" -H sg docker -c "docker rmi -f '$img'" >/dev/null 2>&1
        done
    fi
fi
sudo -u "$FP_USER" -H sg docker -c \
    "docker images --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | \
    grep -E '^falconpulsar/' | while IFS= read -r img; do
    [ -n "$img" ] && sudo -u "$FP_USER" -H sg docker -c "docker rmi -f '$img'" >/dev/null 2>&1
done
set -e

if [ "$FP_PURGE" -eq 1 ]; then
    log_step "pruning orphan volumes"
    set +e
    sudo -u "$FP_USER" -H sg docker -c "docker volume ls --format '{{.Name}}'" 2>/dev/null | \
        grep -E '^falconpulsar' | while IFS= read -r vol; do
        [ -n "$vol" ] && sudo -u "$FP_USER" -H sg docker -c "docker volume rm -f '$vol'" >/dev/null 2>&1
    done
    set -e
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

# IMPORTANT: rm -rf $FP_HOME is the LAST filesystem operation below.
# This script may live at $FP_HOME/uninstall.sh; removing $FP_HOME while
# bash is reading it line-by-line would cause premature EOF.
if [ "$FP_PURGE" -eq 1 ] || confirm "delete ${FP_HOME} (including the time-series database)?" default-no; then
    log_step "removing ${FP_HOME}"
    # Remove child directories first to shrink what the final rm has to do.
    # :? guards against FP_HOME being unset/empty — would otherwise rm /bin.
    rm -rf "${FP_HOME:?}/bin" "${FP_HOME:?}/.docker" "${FP_HOME:?}/ai-gateway-data" 2>/dev/null || true
    rm -f "${FP_HOME:?}/compose.yml" "${FP_HOME:?}/.env" 2>/dev/null || true
    rm -rf "${FP_HOME:?}"
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
