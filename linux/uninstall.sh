#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# FalconPulsar — Linux Uninstaller
# =============================================================================
#
# Removes everything the install.sh put in place:
#
#   - Stops and removes the docker containers (including the optional
#     ai-engine) + the falconpulsar bridge network
#   - Removes the FalconPulsar Docker images (compose-declared, plus any
#     leftover falconpulsar/* from older installs)
#   - Disables the systemd user unit (if installed) and disables linger
#   - Deletes ${FP_HOME} (compose.yml, .env, data/, ai-gateway-data/,
#     ai-engine-data/) and any custom data dirs pointed to by .env that live
#     outside ${FP_HOME} — ONLY when --purge is passed (interactive runs
#     confirm once first)
#   - Removes the falconpulsar system user + group (service-user installs,
#     --purge only)
#
# Does NOT touch:
#   - Docker Engine itself (we don't know if you installed it for FP only)
#
# Usage:
#   sudo bash uninstall.sh                    # keep data (default)
#   sudo bash uninstall.sh --purge            # delete data + user, asks once
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
#
# IMPORTANT: the fallback MUST define is_wsl too. `fp uninstall` copies
# this script to /tmp (where common.sh doesn't live), so without an inline
# is_wsl the WSL-detection block below silently fails, the model falls back
# to service-user, require_root fires, and the user sees "must run as root"
# even though they're on WSL where root isn't needed.
if [ -f "${REPO_ROOT}/shared/lib/common.sh" ]; then
    # shellcheck source=../shared/lib/common.sh
    . "${REPO_ROOT}/shared/lib/common.sh"
    # fpcli.sh defines fp_remove_path_append, used below to strip the
    # `export PATH="$FP_HOME/bin:$PATH"` line we wrote during install.
    # The fallback (uninstaller copied to /tmp) defines an inline stub.
    if [ -f "${REPO_ROOT}/shared/lib/fpcli.sh" ]; then
        # shellcheck source=../shared/lib/fpcli.sh
        . "${REPO_ROOT}/shared/lib/fpcli.sh"
    else
        # Planted ${FP_HOME}/uninstall.sh and the `fp uninstall` /tmp copy run
        # without shared/lib alongside — provide a REAL implementation inline
        # (mirrors fpcli.sh:fp_remove_path_append) so the PATH line the
        # installer appended is actually stripped, not silently skipped.
        fp_remove_path_append() {
            local target_home rc tmp
            for target_home in "$@"; do
                [ -n "$target_home" ] || continue
                for rc in "${target_home}/.bashrc" "${target_home}/.bash_profile" \
                          "${target_home}/.zshrc" "${target_home}/.profile" \
                          "${target_home}/.config/fish/config.fish"; do
                    [ -f "$rc" ] || continue
                    grep -qsF "Added by FalconPulsar installer" "$rc" || continue
                    tmp="${rc}.fp-uninstall.tmp"
                    awk 'BEGIN{skip=0} /^# Added by FalconPulsar installer$/{skip=2;next} skip>0{skip--;next} {print}' \
                        "$rc" > "$tmp" && mv "$tmp" "$rc"
                done
            done
        }
    fi
else
    log_step()    { echo; echo "==> $1"; }
    log_info()    { echo "[info] $1"; }
    log_success() { echo "[ok] $1"; }
    log_warn()    { echo "[warn] $1"; }
    log_error()   { echo "[error] $1" >&2; }
    die()         { log_error "$1"; exit 1; }
    # Standalone fallback — mirrors shared/lib/common.sh confirm(): prompts
    # on /dev/tty and resolves to the STATED DEFAULT when no answer can be
    # read (no tty) or FP_ASSUME_YES=1. Default-no gates the destructive
    # steps below, so this must never auto-answer yes: the planted copy at
    # ${FP_HOME}/uninstall.sh always runs on this fallback, and an earlier
    # `return 0` stub silently purged data on every run.
    confirm() {
        local prompt="$1" default="${2:-default-no}" hint reply
        if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
            [ "$default" = "default-yes" ]
            return
        fi
        if [ "$default" = "default-yes" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
        printf '%s %s ' "$prompt" "$hint" >&2
        reply=''
        # 2>/dev/null before </dev/tty: redirections apply left to right,
        # and a failed /dev/tty open would otherwise print its own error.
        if ! read -r reply 2>/dev/null </dev/tty; then
            [ "$default" = "default-yes" ]
            return
        fi
        if [ -z "$reply" ]; then
            [ "$default" = "default-yes" ]
            return
        fi
        case "$reply" in
            y|Y|yes|YES|Yes) return 0 ;;
            *)               return 1 ;;
        esac
    }
    require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }
    on_error()    { log_error "failed at line $1"; }
    is_wsl() {
        [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] && return 0
        grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
    }
    # Real inline implementation for the standalone case (the planted
    # ${FP_HOME}/uninstall.sh and the `fp uninstall` /tmp copy have no
    # shared/lib alongside). Mirrors fpcli.sh:fp_remove_path_append so the
    # installer-appended PATH line is actually stripped, not silently skipped.
    fp_remove_path_append() {
        local target_home rc tmp
        for target_home in "$@"; do
            [ -n "$target_home" ] || continue
            for rc in "${target_home}/.bashrc" "${target_home}/.bash_profile" \
                      "${target_home}/.zshrc" "${target_home}/.profile" \
                      "${target_home}/.config/fish/config.fish"; do
                [ -f "$rc" ] || continue
                grep -qsF "Added by FalconPulsar installer" "$rc" || continue
                tmp="${rc}.fp-uninstall.tmp"
                awk 'BEGIN{skip=0} /^# Added by FalconPulsar installer$/{skip=2;next} skip>0{skip--;next} {print}' \
                    "$rc" > "$tmp" && mv "$tmp" "$rc"
            done
        done
    }
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
        --keep)   FP_PURGE=0; shift ;;
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
                    (service-user mode: also removes the system user).
                    Data is only ever deleted when this flag is passed.
  --keep          Keep the stack directory and data (default)
  --yes, -y       No prompts. Answers yes to safe prompts only — data
                    deletion still requires an explicit --purge
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
# group active. `-g docker` sets egid to the docker group regardless of
# the current group membership. Always uses sudo (even when already
# running as the right user) because sudo is universally present and
# /usr/bin/sg isn't always (some minimal Ubuntu cloud images strip it
# from the `login` package install).
run_as_fp_user() {
    if [ "$(id -un)" = "$FP_USER" ]; then
        sudo -g docker -H bash -c "$1"
    else
        sudo -u "$FP_USER" -g docker -H bash -c "$1"
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

# Resolve the purge decision up front — several destructive steps below
# (compose down --volumes, volume pruning, the final rm -rf) key off
# FP_PURGE. --purge on an interactive run double-checks once here;
# --purge --yes proceeds without prompting. Without --purge, data is
# ALWAYS kept: deletion is gated strictly on the explicit flag, never on
# a confirm() answer alone.
if [ "$FP_PURGE" -eq 1 ] && \
   ! confirm "delete ${FP_HOME} (including the time-series database and AI Gateway data)?" default-yes; then
    FP_PURGE=0
    log_info "purge declined — keeping data (${FP_HOME} preserved)"
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
# --profile ai --profile engine: a --profile CLI flag REPLACES the .env
# COMPOSE_PROFILES, so BOTH known profiles must be named for their services
# to be in the `down` model — "ai" for legacy pre-mandatory-gateway stacks
# that hid ai-gateway behind it, "engine" for the optional ai-engine.
# Without "engine" the ai-engine container is left Up and keeps the bridge
# network in use. The name-sweep + network fallback below are the backstop.
if [ -f "${FP_HOME}/compose.yml" ]; then
    if [ "$FP_PURGE" -eq 1 ]; then
        # --volumes removes named Docker volumes declared in compose.yml
        run_as_fp_user "cd '${FP_HOME}' && docker compose --profile ai --profile engine down --remove-orphans --volumes" || \
            log_warn "docker compose down failed -- continuing anyway"
    else
        run_as_fp_user "cd '${FP_HOME}' && docker compose --profile ai --profile engine down --remove-orphans" || \
            log_warn "docker compose down failed -- continuing anyway"
    fi
else
    log_info "no compose.yml in ${FP_HOME}, skipping docker compose down"
fi

# Name-sweep backstop: guarantee no falconpulsar-* container survives the
# down. A stale profile, a missing compose.yml, or a container started
# outside compose can all strand one (most often the ai-engine). Do this
# BEFORE image removal so `docker rmi` actually deletes the images instead
# of merely untagging one still referenced by a running container.
run_as_fp_user "docker ps -aq --filter name=falconpulsar- | xargs -r docker rm -f" >/dev/null 2>&1 || true
# Explicit network fallback: `down` leaves the bridge network behind when a
# container blocked its removal. Safe once every container above is gone.
run_as_fp_user "docker network rm falconpulsar" >/dev/null 2>&1 || true

log_step "removing Docker images"
# Wrap in `set +e` -- failing image queries with errexit+pipefail abort the
# whole script. GNU xargs does have -r but we use `while read` for parity.
set +e
FP_IMAGE_RM_FAILED=0
if [ -f "${FP_HOME}/compose.yml" ]; then
    # --profile ai --profile engine: a --profile flag REPLACES the .env
    # COMPOSE_PROFILES, so both must be named to enumerate every gated
    # image — "ai" for a legacy compose.yml that hid the ai-gateway image
    # (~1.6 GB), "engine" for the optional ai-engine image. Without them
    # those images survive the uninstall.
    IMAGES="$(run_as_fp_user "cd '${FP_HOME}' && docker compose --profile ai --profile engine config --images" 2>/dev/null | sort -u)"
    if [ -n "$IMAGES" ]; then
        # Process substitution (not a pipe): a `while` on the right of a
        # pipe runs in a subshell, so FP_IMAGE_RM_FAILED increments would
        # be lost. Reading from < <(...) keeps the counter in this shell.
        while IFS= read -r img; do
            [ -z "$img" ] && continue
            run_as_fp_user "docker rmi -f '$img'" >/dev/null 2>&1 || \
                FP_IMAGE_RM_FAILED=$((FP_IMAGE_RM_FAILED + 1))
        done < <(printf '%s\n' "$IMAGES")
    fi
fi
while IFS= read -r img; do
    [ -z "$img" ] && continue
    run_as_fp_user "docker rmi -f '$img'" >/dev/null 2>&1 || \
        FP_IMAGE_RM_FAILED=$((FP_IMAGE_RM_FAILED + 1))
done < <(run_as_fp_user "docker images --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | grep -E '^falconpulsar/')
set -e
if [ "$FP_IMAGE_RM_FAILED" -eq 0 ]; then
    log_success "Docker images removed"
else
    log_warn "some images could not be removed: ${FP_IMAGE_RM_FAILED} (they may still be in use)"
fi

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

# Strip the "export PATH=" lines we appended to the human user's shell rc
# at install time. We try the home dir of (a) the invoking sudoer
# (SUDO_USER), (b) FP_USER if it's a real human (per-user model), and
# (c) /root for the rare case the installer ran without sudo. The helper
# is idempotent and silent on rc files that don't exist.
_fp_uninstall_rc_homes=()
if [ -n "${SUDO_USER:-}" ]; then
    _h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    [ -n "$_h" ] && _fp_uninstall_rc_homes+=("$_h")
fi
if [ "$FP_INSTALL_MODEL" = "per-user" ] && [ -n "${FP_USER:-}" ] && [ "$FP_USER" != "root" ]; then
    _h="$(getent passwd "$FP_USER" 2>/dev/null | cut -d: -f6)"
    [ -n "$_h" ] && _fp_uninstall_rc_homes+=("$_h")
fi
[ "$(id -u)" -eq 0 ] && _fp_uninstall_rc_homes+=("/root")
if [ ${#_fp_uninstall_rc_homes[@]} -gt 0 ]; then
    fp_remove_path_append "${_fp_uninstall_rc_homes[@]}"
fi

# IMPORTANT: rm -rf $FP_HOME is the LAST filesystem operation below.
# This script may live at $FP_HOME/uninstall.sh; removing $FP_HOME while
# bash is reading it line-by-line would cause premature EOF.
#
# Deletion is gated STRICTLY on --purge (resolved through the confirmation
# up top). A yes from confirm() alone must never stand between the user
# and their database — the copy of this script planted in ${FP_HOME} runs
# on the standalone fallback helpers, and a broken confirm() there used
# to auto-answer yes on every run.
if [ "$FP_PURGE" -eq 1 ]; then
    log_step "removing ${FP_HOME}"

    # Custom data dirs: an operator may have pointed FP_DATA_DIR /
    # FP_GATEWAY_DATA_DIR / FP_ENGINE_DATA_DIR at a location OUTSIDE
    # ${FP_HOME} (e.g. a bigger disk). Those survive `rm -rf ${FP_HOME}`, so
    # read the concrete paths the installer wrote to .env (same sed pattern
    # install.sh uses) and delete any that resolve outside the stack dir.
    # MUST run before .env is removed just below.
    _fp_external_dirs=()
    if [ -f "${FP_HOME}/.env" ]; then
        _fp_home_abs="$(cd "${FP_HOME}" 2>/dev/null && pwd -P || echo "${FP_HOME}")"
        for _fp_dvar in FP_DATA_DIR FP_GATEWAY_DATA_DIR FP_ENGINE_DATA_DIR FP_COPILOT_DATA_DIR; do
            _fp_dval="$(sed -n "s/^${_fp_dvar}=//p" "${FP_HOME}/.env" | tail -n1 | tr -d '\r')"
            [ -n "$_fp_dval" ] || continue
            case "$_fp_dval" in
                /*) ;;            # absolute — evaluate it
                *)  continue ;;   # relative/blank — resolves under the stack dir
            esac
            _fp_dabs="$(cd "$_fp_dval" 2>/dev/null && pwd -P || echo "$_fp_dval")"
            case "$_fp_dabs" in
                "$_fp_home_abs"|"$_fp_home_abs"/*) continue ;;  # inside ${FP_HOME}
                /|"") continue ;;                                # never / or empty
            esac
            _fp_external_dirs+=("$_fp_dabs")
        done
    fi

    # Remove child directories first to shrink what the final rm has to do.
    # :? guards against FP_HOME being unset/empty — would otherwise rm /bin.
    rm -rf "${FP_HOME:?}/bin" "${FP_HOME:?}/.docker" "${FP_HOME:?}/ai-gateway-data" "${FP_HOME:?}/ai-engine-data" 2>/dev/null || true
    rm -f "${FP_HOME:?}/compose.yml" "${FP_HOME:?}/.env" 2>/dev/null || true
    rm -rf "${FP_HOME:?}"
    log_success "deleted ${FP_HOME}"

    # External custom data dirs (if any) live outside ${FP_HOME} and so were
    # untouched by the removals above.
    if [ ${#_fp_external_dirs[@]} -gt 0 ]; then
        for _fp_ext in "${_fp_external_dirs[@]}"; do
            [ -e "$_fp_ext" ] || continue
            if rm -rf "${_fp_ext:?}" 2>/dev/null; then
                log_success "deleted custom data dir ${_fp_ext}"
            else
                log_warn "could not fully remove custom data dir ${_fp_ext}"
            fi
        done
    fi

    if [ "$FP_INSTALL_MODEL" = "service-user" ]; then
        log_step "removing user ${FP_USER}"
        userdel "$FP_USER" 2>/dev/null || true
        # userdel keeps the group when it still has members (install.sh
        # adds the invoking human to it), and a leftover group wedges the
        # next fresh install's useradd with "group falconpulsar exists".
        # Safe once the user is gone: groupdel only refuses to remove a
        # group that is still some user's primary group.
        if getent group "$FP_USER" >/dev/null 2>&1; then
            groupdel "$FP_USER" 2>/dev/null || \
                log_warn "could not remove group ${FP_USER} — remove it manually: sudo groupdel ${FP_USER}"
        fi
        log_success "user ${FP_USER} removed"
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
