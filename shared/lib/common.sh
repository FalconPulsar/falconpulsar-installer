#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared bash helpers for the FalconPulsar installers.
#
# Provides:
#   - Coloured logging (info / warn / error / success / step)
#   - die / require_cmd / on_error trap helpers
#   - confirm()           — yes/no prompt
#   - run_as_user()       — re-exec a command as another user (linux only)
#   - random_password()   — generate a strong default admin password
#   - is_root / require_root / require_not_root
#   - source_guard        — prevents double-sourcing
#
# This file is sourced by linux/install.sh, macos/install.sh and their
# uninstall counterparts. It MUST remain POSIX-bash-4-compatible (no bash 5
# features) because RHEL 9 still ships bash 4.x.
# =============================================================================

# Source guard
if [ -n "${__FP_COMMON_SH_LOADED:-}" ]; then
    return 0
fi
__FP_COMMON_SH_LOADED=1

# Strict mode (callers may relax this if needed)
set -o errexit
set -o nounset
set -o pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
# Disable colours when stdout is not a TTY or when NO_COLOR is set
# (https://no-color.org/).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    FP_C_RESET=$'\033[0m'
    FP_C_BOLD=$'\033[1m'
    FP_C_DIM=$'\033[2m'
    FP_C_RED=$'\033[31m'
    FP_C_GREEN=$'\033[32m'
    FP_C_YELLOW=$'\033[33m'
    FP_C_BLUE=$'\033[34m'
    FP_C_CYAN=$'\033[36m'
else
    FP_C_RESET=''
    FP_C_BOLD=''
    FP_C_DIM=''
    FP_C_RED=''
    FP_C_GREEN=''
    FP_C_YELLOW=''
    FP_C_BLUE=''
    FP_C_CYAN=''
fi

# ── Logging ──────────────────────────────────────────────────────────────────
# All log output goes to stderr so that scripts using stdout for data
# (e.g. echo a generated password) still work.

log_info()    { printf '%s[info]%s %s\n'    "${FP_C_BLUE}"   "${FP_C_RESET}" "$*" >&2; }
log_warn()    { printf '%s[warn]%s %s\n'    "${FP_C_YELLOW}" "${FP_C_RESET}" "$*" >&2; }
log_error()   { printf '%s[error]%s %s\n'   "${FP_C_RED}"    "${FP_C_RESET}" "$*" >&2; }
log_success() { printf '%s[ok]%s %s\n'      "${FP_C_GREEN}"  "${FP_C_RESET}" "$*" >&2; }
log_step()    { printf '\n%s==>%s %s%s%s\n' "${FP_C_CYAN}"   "${FP_C_RESET}" "${FP_C_BOLD}" "$*" "${FP_C_RESET}" >&2; }
log_debug() {
    if [ "${FP_DEBUG:-0}" = "1" ]; then
        printf '%s[debug]%s %s\n' "${FP_C_DIM}" "${FP_C_RESET}" "$*" >&2
    fi
}

# ── Error handling ───────────────────────────────────────────────────────────
die() {
    log_error "$*"
    exit 1
}

# Trap helper — install with: trap 'on_error $LINENO' ERR
on_error() {
    local line="${1:-?}"
    log_error "installer failed at line ${line} (exit $?)"
    log_error "see the lines above for details. To re-run with verbose output:"
    log_error "    FP_DEBUG=1 bash $0"
    exit 1
}

# ── Command / privilege checks ──────────────────────────────────────────────
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command not found: ${cmd}"
    fi
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

require_root() {
    is_root || die "this step must run as root (try: sudo bash $0)"
}

require_not_root() {
    if is_root; then
        die "do not run this as root — the installer will use sudo where needed"
    fi
}

# ── User interaction ─────────────────────────────────────────────────────────
# confirm "question" [default-yes|default-no]
# Returns 0 for yes, 1 for no. Honours FP_ASSUME_YES=1 (CI / unattended).
confirm() {
    local prompt="$1"
    local default="${2:-default-no}"
    local hint reply

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        log_debug "confirm: '${prompt}' → yes (FP_ASSUME_YES=1)"
        return 0
    fi

    case "$default" in
        default-yes) hint="[Y/n]" ;;
        *)           hint="[y/N]" ;;
    esac

    printf '%s%s %s%s ' "${FP_C_BOLD}" "${prompt}" "${hint}" "${FP_C_RESET}" >&2
    read -r reply || reply=''

    if [ -z "$reply" ]; then
        [ "$default" = "default-yes" ]
        return $?
    fi

    case "$reply" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)               return 1 ;;
    esac
}

# ── Privilege re-execution ───────────────────────────────────────────────────
# run_as_user <user> <cmd> [args...]
# Re-exec a command as another local user. Used to drop from root to the
# falconpulsar user when issuing `docker compose` calls.
run_as_user() {
    local target="$1"
    shift
    if [ "$(id -un)" = "$target" ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "$target" -H -- "$@"
    else
        su - "$target" -c "$(printf '%q ' "$@")"
    fi
}

# ── Password / token generation ─────────────────────────────────────────────
# random_password [length]
# Defaults to 24 characters. URL-safe base64 alphabet, avoids confusing chars.
random_password() {
    local len="${1:-24}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 \
            | tr -d '/+=\n' \
            | head -c "$len"
        echo
    elif [ -r /dev/urandom ]; then
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom \
            | head -c "$len"
        echo
    else
        die "no random source available (need openssl or /dev/urandom)"
    fi
}

# ── Path / OS helpers ────────────────────────────────────────────────────────
script_dir() {
    # Resolve the directory of the *calling* script (not this lib).
    cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd
}

# Detect host OS family. Echoes one of: linux, macos, wsl, unknown.
detect_os() {
    case "$(uname -s 2>/dev/null)" in
        Linux)
            if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
                echo wsl
            else
                echo linux
            fi
            ;;
        Darwin)  echo macos ;;
        *)       echo unknown ;;
    esac
}
