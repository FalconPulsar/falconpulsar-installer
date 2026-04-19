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

# Defaults and install-model inference -- mirror linux/install.sh.
FP_INSTALL_MODEL="${FP_INSTALL_MODEL:-}"
if [ -z "${FP_USER:-}" ] && [ -z "${FP_HOME:-}" ]; then
    if command -v is_wsl >/dev/null 2>&1 && is_wsl; then
        FP_INSTALL_MODEL="per-user"
        # Prefer a real human user: not root.
        _fp_default_user="${FP_INVOKING_USER:-${SUDO_USER:-$(id -un)}}"
        if [ -z "$_fp_default_user" ] || [ "$_fp_default_user" = "root" ]; then
            _fp_default_user="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
        fi
        FP_USER="${_fp_default_user:-}"
        [ -n "$FP_USER" ] && FP_HOME="/home/${FP_USER}/falconpulsar"
    else
        FP_INSTALL_MODEL="service-user"
        FP_USER="falconpulsar"
        FP_HOME="/home/${FP_USER}"
    fi
else
    FP_USER="${FP_USER:-falconpulsar}"
    if [ "$FP_USER" = "falconpulsar" ] && [ -z "${FP_HOME:-}" ]; then
        FP_INSTALL_MODEL="${FP_INSTALL_MODEL:-service-user}"
        FP_HOME="/home/${FP_USER}"
    else
        FP_INSTALL_MODEL="${FP_INSTALL_MODEL:-per-user}"
        FP_HOME="${FP_HOME:-/home/${FP_USER}/falconpulsar}"
    fi
fi
FP_PURGE=0
FP_FORCE=0
FP_LOG_FILE="${FP_LOG_FILE:-/tmp/falconpulsar-install.log}"

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            FP_USER="$2"
            if [ "$FP_INSTALL_MODEL" = "per-user" ]; then
                FP_HOME="/home/${FP_USER}/falconpulsar"
            else
                FP_HOME="/home/${FP_USER}"
            fi
            shift 2 ;;
        --home)   FP_HOME="$2"; shift 2 ;;
        --purge)  FP_PURGE=1; shift ;;
        -y|--yes) FP_ASSUME_YES=1; shift ;;
        --force)  FP_FORCE=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: uninstall.sh [options]
  --user <name>   User who owns the stack
                    Native Linux default: falconpulsar (system user -- also removed)
                    WSL default:          the invoking human user (NOT removed)
  --home <path>   Stack directory (default derived from --user)
  --purge         Also delete the stack directory and its database
                    (service-user mode: also removes the system user)
  --yes, -y       Assume yes to all prompts
  --force         Skip admin authentication (emergency use only)
EOF
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done
export FP_ASSUME_YES="${FP_ASSUME_YES:-0}"

# Per-user install: no root needed -- the invoking user owns everything
# and is in the docker group. Service-user install: root is required
# because we're stopping another user's containers + deleting their home +
# possibly calling userdel.
if [ "$FP_INSTALL_MODEL" = "service-user" ]; then
    require_root
elif ! id "$FP_USER" >/dev/null 2>&1; then
    log_warn "user ${FP_USER} does not exist -- nothing to uninstall"
    exit 0
fi

# run_as_fp_user: run a shell command as the stack owner with the docker
# group active. When we're already that user (per-user mode without root),
# skip sudo and just use sg docker.
run_as_fp_user() {
    if [ "$(id -un)" = "$FP_USER" ]; then
        sg docker -c "$1"
    else
        sudo -u "$FP_USER" -H sg docker -c "$1"
    fi
}

if ! id "$FP_USER" >/dev/null 2>&1; then
    log_warn "user ${FP_USER} does not exist -- nothing to uninstall"
    exit 0
fi

# Admin authentication gate — require the FalconPulsar admin password before
# any destructive action. --force bypasses for emergencies (broken Core).
if [ "$FP_FORCE" = "1" ]; then
    log_warn "--force supplied: skipping admin authentication"
else
    AUTH_SH=""
    for candidate in \
        "${SCRIPT_DIR}/auth.sh" \
        "${REPO_ROOT}/shared/lib/auth.sh"; do
        if [ -f "$candidate" ]; then AUTH_SH="$candidate"; break; fi
    done
    if [ -n "$AUTH_SH" ]; then
        # shellcheck disable=SC1090
        . "$AUTH_SH"
        auth_rc=0
        fp_authenticate_admin 3 || auth_rc=$?
        case "$auth_rc" in
            0) ;;
            2)
                # Core not reachable — fall back to explicit confirmation
                # (or accept --yes as implicit bypass for automation).
                if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
                    log_warn "Core unreachable — proceeding because --yes was supplied."
                else
                    printf '\n' >&2
                    printf 'FalconPulsar Core is not running, so the admin password cannot be verified.\n' >&2
                    printf 'To authorize this uninstall anyway, type exactly YES (uppercase): ' >&2
                    confirm=''
                    read -r confirm </dev/tty 2>/dev/null || confirm=''
                    if [ "$confirm" != 'YES' ]; then
                        printf '[error] Confirmation not received — aborting.\n' >&2
                        exit 1
                    fi
                fi
                ;;
            *) exit 1 ;;
        esac
    else
        log_warn "auth.sh not found — proceeding without admin auth"
    fi
fi

# Append a run marker to the install log (best-effort). Earlier versions
# redirected all stdout through tee via `exec > >(tee -a …)`, but if tee
# couldn't open the log file SIGPIPE + errexit silently aborted the rest
# of the uninstall (image/volume cleanup never ran). Keep it simple.
if declare -f fp_rotate_log >/dev/null 2>&1; then
    fp_rotate_log "$FP_LOG_FILE"
fi
{
    printf '\n=== %s  uninstall (platform=linux, pid=%d, mode=%s) ===\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$$" \
        "$([ "$FP_PURGE" -eq 1 ] && echo purge || echo keep)"
} >> "$FP_LOG_FILE" 2>/dev/null || true

FP_UID="$(id -u "$FP_USER")"

# Make sure our cwd is not inside $FP_HOME before rm happens — guards
# against deleting-script-while-reading if bash was invoked from there.
cd / 2>/dev/null

log_step "stopping the stack"
if [ -f "${FP_HOME}/compose.yml" ]; then
    if [ "$FP_PURGE" -eq 1 ]; then
        # --volumes removes named Docker volumes declared in compose.yml
        run_as_fp_user "cd '${FP_HOME}' && docker compose --profile ai down --remove-orphans --volumes" || \
            log_warn "docker compose down failed -- continuing anyway"
    else
        run_as_fp_user "cd '${FP_HOME}' && docker compose --profile ai down --remove-orphans" || \
            log_warn "docker compose down failed -- continuing anyway"
    fi
else
    log_info "no compose.yml in ${FP_HOME}, skipping docker compose down"
fi

log_step "removing Docker images"
# Wrap in `set +e` -- failing image queries with errexit+pipefail abort the
# whole script. GNU xargs does have -r but we use `while read` for parity.
set +e
if [ -f "${FP_HOME}/compose.yml" ]; then
    IMAGES="$(run_as_fp_user "cd '${FP_HOME}' && docker compose config --images" 2>/dev/null | sort -u)"
    if [ -n "$IMAGES" ]; then
        echo "$IMAGES" | while IFS= read -r img; do
            [ -n "$img" ] && run_as_fp_user "docker rmi -f '$img'" >/dev/null 2>&1
        done
    fi
fi
run_as_fp_user "docker images --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | \
    grep -E '^falconpulsar/' | while IFS= read -r img; do
    [ -n "$img" ] && run_as_fp_user "docker rmi -f '$img'" >/dev/null 2>&1
done
set -e

if [ "$FP_PURGE" -eq 1 ]; then
    log_step "pruning orphan volumes"
    set +e
    run_as_fp_user "docker volume ls --format '{{.Name}}'" 2>/dev/null | \
        grep -E '^falconpulsar' | while IFS= read -r vol; do
        [ -n "$vol" ] && run_as_fp_user "docker volume rm -f '$vol'" >/dev/null 2>&1
    done
    set -e
fi

log_step "removing systemd user unit (if any)"
UNIT_FILE="${FP_HOME}/.config/systemd/user/falconpulsar.service"
if [ -f "$UNIT_FILE" ] && [ "$FP_INSTALL_MODEL" = "service-user" ]; then
    sudo -u "$FP_USER" -H XDG_RUNTIME_DIR="/run/user/${FP_UID}" \
        systemctl --user disable --now falconpulsar.service 2>/dev/null || true
    rm -f "$UNIT_FILE"
    loginctl disable-linger "$FP_USER" 2>/dev/null || true
    log_success "systemd unit removed"
else
    log_info "no systemd unit found"
fi

# Remove the /etc/profile.d PATH snippet if we planted one. Needs root;
# only attempt it when we have root (service-user mode always does;
# per-user mode may not, so we silently skip).
if [ -w /etc/profile.d ] || [ "$(id -u)" -eq 0 ]; then
    rm -f /etc/profile.d/falconpulsar.sh 2>/dev/null || true
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

    if [ "$FP_INSTALL_MODEL" = "service-user" ]; then
        if [ "$FP_PURGE" -eq 1 ] || confirm "remove the ${FP_USER} system user?" default-no; then
            log_step "removing user ${FP_USER}"
            userdel "$FP_USER" 2>/dev/null || true
            log_success "user ${FP_USER} removed"
        fi
    else
        log_info "per-user install -- leaving the human user '${FP_USER}' in place"
    fi
else
    log_info "${FP_HOME} preserved. Re-run with --purge to delete it."
fi

log_success "uninstall complete"

# Close the run marker and surface the full install log so the user has a
# single record of everything that happened (install → uninstall).
printf '=== end ===\n' >> "$FP_LOG_FILE" 2>/dev/null || true
echo ""
echo "  Full log: $FP_LOG_FILE"

# Best-effort: open the log for the user. Prefer xdg-open (graphical session)
# then fall back to printing the tail. Skipped under --yes (non-interactive).
if [ "${FP_ASSUME_YES:-0}" != "1" ] && [ -f "$FP_LOG_FILE" ]; then
    if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        xdg-open "$FP_LOG_FILE" >/dev/null 2>&1 &
    else
        echo ""
        echo "  (no graphical session detected — run 'less $FP_LOG_FILE' to review)"
    fi
fi
