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

# Returns one of: weak | medium | strong. Same heuristic as the macOS GUI.
fp_password_strength() {
    local p="$1"
    [ "${#p}" -lt 10 ] && { echo "weak"; return; }
    local classes=0
    [[ "$p" =~ [A-Z] ]]        && classes=$((classes+1))
    [[ "$p" =~ [a-z] ]]        && classes=$((classes+1))
    [[ "$p" =~ [0-9] ]]        && classes=$((classes+1))
    [[ "$p" =~ [^A-Za-z0-9] ]] && classes=$((classes+1))
    if [ "${#p}" -ge 12 ] && [ "$classes" -ge 3 ]; then
        echo "strong"
    elif [ "$classes" -ge 2 ]; then
        echo "medium"
    else
        echo "weak"
    fi
}

# Render "[XXXXXXXX    ] label" for the given strength/length.
fp_password_strength_bar() {
    local p="$1"
    local strength color label width=14
    strength="$(fp_password_strength "$p")"
    case "$strength" in
        strong) color="${FP_C_GREEN}";  label="Strong";  ;;
        medium) color="${FP_C_YELLOW}"; label="Medium";  ;;
        *)      color="${FP_C_RED}";    label="Weak";    ;;
    esac
    local filled=$(( ${#p} * width / 20 ))
    [ "$filled" -gt "$width" ] && filled="$width"
    local bar=""
    local i=0
    while [ "$i" -lt "$filled" ]; do bar="${bar}#"; i=$((i+1)); done
    while [ "$i" -lt "$width" ]; do bar="${bar} "; i=$((i+1)); done
    printf '  %s[%s]%s %s%s%s  (%s chars)\n' \
        "${color}" "$bar" "${FP_C_RESET}" \
        "${color}" "$label" "${FP_C_RESET}" "${#p}"
}

# Best-effort clipboard copy (pbcopy on macOS, xclip/xsel/wl-copy on Linux).
# Returns 0 if something wrote to the clipboard, 1 otherwise.
fp_clipboard_copy() {
    local text="$1"
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$text" | pbcopy; return 0
    fi
    if command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$text" | wl-copy; return 0
    fi
    if command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | xclip -selection clipboard; return 0
    fi
    if command -v xsel >/dev/null 2>&1; then
        printf '%s' "$text" | xsel --clipboard --input; return 0
    fi
    return 1
}

# ── Legal acknowledgement ───────────────────────────────────────────────────
# Shows the four legal documents (Terms, Privacy, AUP, Security) as
# clickable URLs and asks the user to confirm they have read and agree.
# Refusing exits the installer with a non-zero status. Honours
# FP_ASSUME_YES=1 (CI / unattended) and FP_LEGAL_ACCEPTED=1 (already
# accepted via env var, e.g. when re-launched by a parent installer).
prompt_legal_acknowledgement() {
    if [ "${FP_LEGAL_ACCEPTED:-0}" = "1" ]; then
        log_debug "FP_LEGAL_ACCEPTED=1 — skipping legal prompt"
        return 0
    fi

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        log_warn "FP_ASSUME_YES=1 — accepting FalconPulsar legal terms on your behalf"
        log_warn "By continuing, you confirm you have read and agree to:"
        log_warn "  https://falconpulsar.com/terms/"
        log_warn "  https://falconpulsar.com/privacy/"
        log_warn "  https://falconpulsar.com/aup/"
        log_warn "  https://falconpulsar.com/security/"
        export FP_LEGAL_ACCEPTED=1
        return 0
    fi

    cat >&2 <<EOF

${FP_C_BOLD}Before you install${FP_C_RESET}

By installing FalconPulsar you agree to the following documents.
Please open each link in a browser and read it before continuing:

  ${FP_C_CYAN}1. Terms of Service${FP_C_RESET}      https://falconpulsar.com/terms/
  ${FP_C_CYAN}2. Privacy Policy${FP_C_RESET}        https://falconpulsar.com/privacy/
  ${FP_C_CYAN}3. Acceptable Use Policy${FP_C_RESET} https://falconpulsar.com/aup/
  ${FP_C_CYAN}4. Security Policy${FP_C_RESET}       https://falconpulsar.com/security/

EOF

    if ! confirm "I have read and agree to all four documents" default-no; then
        die "Installation cancelled — you must accept the legal terms to continue."
    fi

    export FP_LEGAL_ACCEPTED=1
}

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

    # Expand a leading ~ to $HOME (manual — bash does not perform tilde
    # expansion on values that come from `read`). We use a single-char
    # variable to keep shellcheck happy about literal tildes in strings.
    local val tilde='~'
    eval "val=\${${var}}"
    if [ "${val:0:1}" = "$tilde" ]; then
        if [ "$val" = "$tilde" ]; then
            val="$HOME"
        elif [ "${val:0:2}" = "${tilde}/" ]; then
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
# Ask the operator whether the deployment will run behind HTTPS (the
# recommended posture) or HTTP-only (acceptable on trusted LANs).
# Sets FP_COOKIE_SECURE to "true" or "false".
#
# This drives the Secure flag and __Host- prefix on session cookies.
# Browsers refuse to send Secure cookies over plain HTTP, so a
# mismatch between this choice and the actual deployment topology
# silently breaks login. The default ("yes, HTTPS") matches the
# secure-by-default posture; the operator must explicitly opt out.
#
# Honors FP_COOKIE_SECURE in the environment so wizards / non-
# interactive scripts can pre-set without prompting. Honors
# FP_ASSUME_YES=1 by defaulting to HTTPS.
prompt_transport_mode() {
    if [ -n "${FP_COOKIE_SECURE:-}" ]; then
        export FP_COOKIE_SECURE
        return 0
    fi
    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        FP_COOKIE_SECURE=true
        export FP_COOKIE_SECURE
        return 0
    fi
    printf '\n%sFront-door HTTPS%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
    printf 'How will operators connect to FalconPulsar?\n\n' >&2
    printf '  %sHTTPS%s — recommended. Session cookies get the Secure flag and\n' \
        "${FP_C_CYAN}" "${FP_C_RESET}" >&2
    printf '          the __Host- prefix. Required for cloud / public deploys\n' >&2
    printf '          and on-prem deploys with a corporate cert.\n\n' >&2
    printf '  %sHTTP%s  — acceptable only for air-gapped LAN installs accessed\n' \
        "${FP_C_YELLOW}" "${FP_C_RESET}" >&2
    printf '          by IP address. Session cookies are NOT marked Secure;\n' >&2
    printf '          anyone with packet capture on the LAN can steal them.\n' >&2
    printf '          Use only on trusted networks.\n\n' >&2
    if confirm "Will the deployment be reachable via HTTPS?" default-yes; then
        FP_COOKIE_SECURE=true
    else
        FP_COOKIE_SECURE=false
        log_warn "HTTP-only mode selected. Session cookies will NOT have the Secure flag."
        log_warn "Sessions are vulnerable to LAN sniffing; only use on trusted networks."
    fi
    export FP_COOKIE_SECURE
}

# Ask the operator whether to install the optional AI Engine — the agent
# runtime used to author, simulate and deploy agents. It runs as one extra
# container behind the "engine" compose profile, and its config + agent
# state live in the SAME main folder as Core/Gateway.
#
# Sets FP_AI_ENGINE_ENABLED to "true" or "false" and derives
# COMPOSE_PROFILES from it ("engine" or empty). The engine is the only
# profiled service, so overwriting COMPOSE_PROFILES here is safe.
#
# Honors FP_AI_ENGINE_ENABLED pre-set in the environment (or via installer
# flags) — the installers record that in FP_AI_ENGINE_ENABLED_EXPLICIT
# before their defaults / .env carry-forward fill the variable in, and an
# explicit choice skips the prompt entirely. A value merely carried
# forward from a surviving .env (reinstall) only flips the prompt's
# default, so the previous choice is sticky but still overridable.
# Honors FP_ASSUME_YES=1 by keeping the current value without prompting.
prompt_ai_engine() {
    if [ "${FP_AI_ENGINE_ENABLED_EXPLICIT:-}" = "1" ]; then
        FP_AI_ENGINE_ENABLED="${FP_AI_ENGINE_ENABLED:-false}"
        log_info "AI Engine install: ${FP_AI_ENGINE_ENABLED} (FP_AI_ENGINE_ENABLED pre-set in environment)"
    elif [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        FP_AI_ENGINE_ENABLED="${FP_AI_ENGINE_ENABLED:-false}"
        log_info "FP_ASSUME_YES=1 — AI Engine install: ${FP_AI_ENGINE_ENABLED}"
    else
        printf '\n%sOptional AI Engine%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        printf 'The AI Engine is an optional add-on: the agent runtime used to author,\n' >&2
        printf 'simulate and deploy agents. It runs as one extra container, and its\n' >&2
        printf 'configuration and agent state live in the shared stack folder alongside\n' >&2
        printf 'Core and the AI Gateway. You can enable it later by setting\n' >&2
        printf 'FP_AI_ENGINE_ENABLED=true in .env and re-running "docker compose up -d".\n\n' >&2
        local engine_default="default-no"
        # Sticky reinstall: a previous install's choice (carried forward
        # from the surviving .env) becomes the prompt default.
        if [ "${FP_AI_ENGINE_ENABLED:-false}" = "true" ]; then
            engine_default="default-yes"
        fi
        if confirm "Install the optional AI Engine?" "$engine_default"; then
            FP_AI_ENGINE_ENABLED=true
        else
            FP_AI_ENGINE_ENABLED=false
        fi
    fi

    # Derive the compose profile from the choice — downstream consumers
    # (engine data dir creation, the .env write) read both variables.
    if [ "${FP_AI_ENGINE_ENABLED}" = "true" ]; then
        COMPOSE_PROFILES="engine"
    else
        COMPOSE_PROFILES=""
    fi
    export FP_AI_ENGINE_ENABLED COMPOSE_PROFILES
}

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
        printf '\n%sgenerated admin password:%s %s%s%s\n' \
            "${FP_C_YELLOW}" "${FP_C_RESET}" \
            "${FP_C_BOLD}" "$FP_ADMIN_PASS" "${FP_C_RESET}" >&2
        fp_password_strength_bar "$FP_ADMIN_PASS" >&2
        if fp_clipboard_copy "$FP_ADMIN_PASS" 2>/dev/null; then
            printf '  %s✓ copied to clipboard%s\n\n' "${FP_C_GREEN}" "${FP_C_RESET}" >&2
        else
            printf '\n' >&2
        fi
        log_warn "WRITE THIS DOWN — it will not be shown again, only stored in .env"
        if ! confirm "have you saved the password somewhere safe?" default-no; then
            die "aborting — please re-run when you are ready to save the password"
        fi
    else
        prompt_password "admin password" FP_ADMIN_PASS
        fp_password_strength_bar "$FP_ADMIN_PASS" >&2
    fi

    export FP_ADMIN_USER FP_ADMIN_PASS
}
