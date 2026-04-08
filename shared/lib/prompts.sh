#!/usr/bin/env bash
# =============================================================================
# prompts.sh — Interactive prompts for the FalconPulsar installers.
#
# Provides:
#   - prompt_password "label" var  — read with confirmation, no echo
#   - prompt_string   "label" var [default]
#   - prompt_path     "label" var [default]
#   - prompt_admin_credentials     — fills FP_ADMIN_USER + FP_ADMIN_PASS
#
# All functions honour FP_ASSUME_YES=1 (unattended) and look at corresponding
# FP_* environment variables first so the installer can be driven from a
# config file or CI without prompting.
#
# Sourced by linux/install.sh and macos/install.sh. Depends on common.sh.
# =============================================================================

if [ -n "${__FP_PROMPTS_SH_LOADED:-}" ]; then
    return 0
fi
__FP_PROMPTS_SH_LOADED=1

if [ -z "${__FP_COMMON_SH_LOADED:-}" ]; then
    # shellcheck source=common.sh
    . "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
fi

# Minimum admin password length. Industrial-friendly but not insulting.
FP_MIN_PASSWORD_LEN=10

# ── Generic string prompt ────────────────────────────────────────────────────
# prompt_string "label" var_name [default]
prompt_string() {
    local label="$1"
    local var="$2"
    local default="${3:-}"
    local current reply

    # Already set in env?
    eval "current=\${${var}:-}"
    if [ -n "$current" ]; then
        log_debug "${var} already set in environment, skipping prompt"
        return 0
    fi

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        if [ -z "$default" ]; then
            die "FP_ASSUME_YES=1 but no default for '${label}' (set ${var} in environment)"
        fi
        eval "${var}=\"\$default\""
        return 0
    fi

    if [ -n "$default" ]; then
        printf '%s%s%s [%s]: ' "${FP_C_BOLD}" "$label" "${FP_C_RESET}" "$default" >&2
    else
        printf '%s%s%s: ' "${FP_C_BOLD}" "$label" "${FP_C_RESET}" >&2
    fi
    read -r reply || reply=''
    [ -z "$reply" ] && reply="$default"

    if [ -z "$reply" ]; then
        die "${label} cannot be empty"
    fi
    eval "${var}=\"\$reply\""
}

# prompt_path — like prompt_string but expands ~ and verifies the parent dir
prompt_path() {
    local label="$1"
    local var="$2"
    local default="${3:-}"

    prompt_string "$label" "$var" "$default"

    # Expand a leading ~ to $HOME (manual — tilde does not expand inside quotes)
    local val
    eval "val=\${${var}}"
    if [ "${val:0:1}" = "~" ]; then
        if [ "$val" = "~" ]; then
            val="$HOME"
        elif [ "${val:0:2}" = "~/" ]; then
            val="${HOME}/${val:2}"
        fi
    fi
    eval "${var}=\"\$val\""
}

# ── Password prompt with confirmation ───────────────────────────────────────
# prompt_password "label" var_name
#
# Reads twice with no echo. Re-prompts on mismatch or too-short input. If the
# variable is already set in the environment (e.g. from .env or CI), the
# prompt is skipped — but the value is still validated against the minimum
# length and rejected if too weak.
prompt_password() {
    local label="$1"
    local var="$2"
    local current p1 p2

    eval "current=\${${var}:-}"
    if [ -n "$current" ]; then
        if [ "${#current}" -lt "$FP_MIN_PASSWORD_LEN" ]; then
            die "${var} is set in environment but is shorter than ${FP_MIN_PASSWORD_LEN} characters"
        fi
        log_debug "${var} already set in environment, skipping prompt"
        return 0
    fi

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        die "FP_ASSUME_YES=1 but ${var} is not set in environment — cannot prompt for password unattended"
    fi

    while :; do
        printf '%s%s%s: ' "${FP_C_BOLD}" "$label" "${FP_C_RESET}" >&2
        stty -echo 2>/dev/null || true
        read -r p1 || p1=''
        stty echo 2>/dev/null || true
        printf '\n' >&2

        if [ "${#p1}" -lt "$FP_MIN_PASSWORD_LEN" ]; then
            log_warn "password must be at least ${FP_MIN_PASSWORD_LEN} characters; try again"
            continue
        fi

        printf '%sconfirm %s%s: ' "${FP_C_BOLD}" "$label" "${FP_C_RESET}" >&2
        stty -echo 2>/dev/null || true
        read -r p2 || p2=''
        stty echo 2>/dev/null || true
        printf '\n' >&2

        if [ "$p1" != "$p2" ]; then
            log_warn "passwords do not match; try again"
            continue
        fi

        eval "${var}=\"\$p1\""
        return 0
    done
}

# ── Admin credentials helper ────────────────────────────────────────────────
# Fills FP_ADMIN_USER + FP_ADMIN_PASS. Used by both linux/install.sh and
# macos/install.sh.
#
# Behaviour:
#   - FP_ADMIN_USER:  prompts with default 'admin'
#   - FP_ADMIN_PASS:  prompts with confirmation. If the user just hits enter
#                     on an unattended-but-not-FP_ASSUME_YES run, we offer to
#                     generate a strong password and print it for the user
#                     to copy down.
prompt_admin_credentials() {
    prompt_string "admin username" FP_ADMIN_USER "admin"

    # If already set, validate-and-go.
    if [ -n "${FP_ADMIN_PASS:-}" ]; then
        if [ "${#FP_ADMIN_PASS}" -lt "$FP_MIN_PASSWORD_LEN" ]; then
            die "FP_ADMIN_PASS in environment is shorter than ${FP_MIN_PASSWORD_LEN} characters"
        fi
        return 0
    fi

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        FP_ADMIN_PASS="$(random_password 24)"
        export FP_ADMIN_PASS
        log_warn "FP_ASSUME_YES=1 — generated random admin password"
        printf '%sgenerated admin password:%s %s\n' \
            "${FP_C_YELLOW}" "${FP_C_RESET}" "$FP_ADMIN_PASS" >&2
        log_warn "WRITE THIS DOWN — it will not be shown again"
        return 0
    fi

    if confirm "generate a strong random admin password automatically?" default-yes; then
        FP_ADMIN_PASS="$(random_password 24)"
        export FP_ADMIN_PASS
        printf '\n%sgenerated admin password:%s %s%s%s\n\n' \
            "${FP_C_YELLOW}" "${FP_C_RESET}" \
            "${FP_C_BOLD}" "$FP_ADMIN_PASS" "${FP_C_RESET}" >&2
        log_warn "WRITE THIS DOWN — it will not be shown again, only stored in .env"
        if ! confirm "have you saved the password somewhere safe?" default-no; then
            die "aborting — please re-run when you are ready to save the password"
        fi
    else
        prompt_password "admin password" FP_ADMIN_PASS
    fi

    export FP_ADMIN_USER FP_ADMIN_PASS
}
