#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

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
    printf 'How will users connect to FalconPulsar?\n\n' >&2
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

# Rebuild COMPOSE_PROFILES from optional-module flags (comma-separated).
# Call after any change to FP_AI_ENGINE_ENABLED / FP_COPILOT_ENABLED.
fp_refresh_compose_profiles() {
    # AI Engine is a standard service (no compose profile). Command Center is
    # the only profile-gated optional module.
    local profiles=""
    if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
        profiles="copilot"
    fi
    COMPOSE_PROFILES="$profiles"
    export COMPOSE_PROFILES
}

# DEPRECATED / INTENTIONALLY UNCALLED. The AI Engine is a STANDARD service
# now: it has no compose profile and every installer force-sets
# FP_AI_ENGINE_ENABLED=true. This function is kept only for reference (and
# for a possible future re-opt-in) — do NOT wire it back in without also
# restoring the "engine" profile in shared/compose.yml, or it will set the
# flag false while compose starts the container anyway. Command Center
# (prompt_copilot) is the only optional module.
#
# Ask the operator whether to install the optional AI Engine — the agent
# runtime used to author, simulate and deploy agents. It runs as one extra
# container behind the "engine" compose profile, and its config + agent
# state live in the SAME main folder as Core/Gateway.
#
# Sets FP_AI_ENGINE_ENABLED to "true" or "false" and refreshes
# COMPOSE_PROFILES (may also include "copilot" if already enabled).
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

    export FP_AI_ENGINE_ENABLED
    fp_refresh_compose_profiles
}

# Optional Command Center (ops workspace: Investigate / Channels / Approve / Watch).
# Profile "copilot". The published image is always CLEAN (empty workspace) —
# data mode is baked at build time (VITE_CC_DATA_MODE), not switchable at
# install time, and no demo image is published. An operator who builds their
# own demo image points FP_COPILOT_IMAGE_TAG at it; there is deliberately no
# FP_COPILOT_MODE knob, because a setting nothing reads only misleads.
prompt_copilot() {
    FP_COPILOT_PORT="${FP_COPILOT_PORT:-8090}"

    if [ "${FP_COPILOT_ENABLED_EXPLICIT:-}" = "1" ]; then
        FP_COPILOT_ENABLED="${FP_COPILOT_ENABLED:-false}"
        log_info "Command Center install: ${FP_COPILOT_ENABLED} (FP_COPILOT_ENABLED pre-set)"
    elif [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        FP_COPILOT_ENABLED="${FP_COPILOT_ENABLED:-false}"
        log_info "FP_ASSUME_YES=1 — Command Center install: ${FP_COPILOT_ENABLED}"
    else
        printf '\n%sOptional Command Center%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        printf 'Command Center is an optional ops workspace for incidents, multiplayer\n' >&2
        printf 'channels, safety-gated approvals, and line watch. It runs as one extra\n' >&2
        printf 'container on the shared network (default port 8090). Standard installs use\n' >&2
        printf 'empty (clean) data — not the demo story. Enable later via\n' >&2
        printf 'FP_COPILOT_ENABLED=true in .env and "docker compose up -d".\n\n' >&2
        local cc_default="default-no"
        if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
            cc_default="default-yes"
        fi
        if confirm "Install the optional Command Center?" "$cc_default"; then
            FP_COPILOT_ENABLED=true
        else
            FP_COPILOT_ENABLED=false
        fi
    fi

    export FP_COPILOT_ENABLED FP_COPILOT_PORT
    fp_refresh_compose_profiles
}

# Interactive auth policy for the deployment.
# Always creates a local break-glass admin (prompt_admin_credentials).
# Mode is recorded in .env + auth-policy.json for Config Hub / apps.
#
#   local      — local users only (default, non-IT friendly)
#   sso_later  — local now; configure SSO in Web UI Config Hub later
#   sso_now    — pick provider + optional issuer/client id (details finish in UI)
prompt_auth_mode() {
    FP_AUTH_MODE="${FP_AUTH_MODE:-local}"
    FP_SSO_PROVIDER="${FP_SSO_PROVIDER:-none}"
    FP_SSO_ISSUER="${FP_SSO_ISSUER:-}"
    FP_SSO_CLIENT_ID="${FP_SSO_CLIENT_ID:-}"

    if [ "${FP_AUTH_MODE_EXPLICIT:-}" = "1" ]; then
        log_info "Auth mode: ${FP_AUTH_MODE} (FP_AUTH_MODE pre-set)"
    elif [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        FP_AUTH_MODE="${FP_AUTH_MODE:-local}"
        log_info "FP_ASSUME_YES=1 — auth mode: ${FP_AUTH_MODE}"
    else
        printf '\n%sSign-in security%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        printf 'How will users sign in to FalconPulsar?\n\n' >&2
        printf '  %s1)%s Local users only (recommended for first install)\n' \
            "${FP_C_CYAN}" "${FP_C_RESET}" >&2
        printf '       Manage users in the Web UI. Works offline / air-gapped.\n' >&2
        printf '  %s2)%s SSO later\n' "${FP_C_CYAN}" "${FP_C_RESET}" >&2
        printf '       Start with local admin now; connect Entra / Okta / OIDC in Config Hub.\n' >&2
        printf '  %s3)%s SSO now (advanced / IT)\n' "${FP_C_CYAN}" "${FP_C_RESET}" >&2
        printf '       Choose a provider and record connection hints; finish mapping in Config Hub.\n\n' >&2
        printf 'A local break-glass admin is ALWAYS created so the system stays reachable\n' >&2
        printf 'if the identity provider is down.\n\n' >&2

        local choice=""
        local default_choice=1
        case "${FP_AUTH_MODE}" in
            sso_later) default_choice=2 ;;
            sso_now)   default_choice=3 ;;
            *)         default_choice=1 ;;
        esac
        printf 'Choice [1/2/3] (default %s): ' "$default_choice" >&2
        read -r choice || true
        choice="${choice:-$default_choice}"
        case "$choice" in
            2|sso_later|later) FP_AUTH_MODE=sso_later ;;
            3|sso_now|sso|now) FP_AUTH_MODE=sso_now ;;
            *)                 FP_AUTH_MODE=local ;;
        esac
    fi

    case "${FP_AUTH_MODE}" in
        local|sso_later|sso_now) ;;
        *) FP_AUTH_MODE=local ;;
    esac

    if [ "${FP_AUTH_MODE}" = "sso_now" ]; then
        if [ "${FP_SSO_PROVIDER_EXPLICIT:-}" = "1" ] || [ "${FP_ASSUME_YES:-0}" = "1" ]; then
            FP_SSO_PROVIDER="${FP_SSO_PROVIDER:-oidc}"
        else
            printf '\n%sSSO provider%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
            printf '  1) Microsoft Entra ID (Azure AD)\n' >&2
            printf '  2) Okta\n' >&2
            printf '  3) Generic OIDC (Keycloak, Auth0, …)\n' >&2
            printf 'Provider [1/2/3] (default 1): ' >&2
            local pchoice=""
            read -r pchoice || true
            pchoice="${pchoice:-1}"
            case "$pchoice" in
                2|okta|Okta) FP_SSO_PROVIDER=okta ;;
                3|oidc|OIDC|generic) FP_SSO_PROVIDER=oidc ;;
                *) FP_SSO_PROVIDER=entra ;;
            esac
            printf 'Issuer URL (optional, blank = configure later): ' >&2
            read -r FP_SSO_ISSUER || true
            printf 'Client ID (optional, blank = configure later): ' >&2
            read -r FP_SSO_CLIENT_ID || true
        fi
        case "${FP_SSO_PROVIDER}" in
            entra|okta|oidc) ;;
            none|"") FP_SSO_PROVIDER=oidc ;;
            *) FP_SSO_PROVIDER=oidc ;;
        esac
    else
        if [ "${FP_AUTH_MODE}" = "local" ]; then
            FP_SSO_PROVIDER=none
        fi
        # sso_later keeps provider as none until Config Hub
        if [ "${FP_AUTH_MODE}" = "sso_later" ] && [ "${FP_SSO_PROVIDER}" = "none" ]; then
            FP_SSO_PROVIDER=none
        fi
    fi

    export FP_AUTH_MODE FP_SSO_PROVIDER FP_SSO_ISSUER FP_SSO_CLIENT_ID
    log_info "Auth mode: ${FP_AUTH_MODE} (SSO provider: ${FP_SSO_PROVIDER:-none})"
}

# Write $FP_HOME/auth-policy.json for UI / Command Center first-run.
# Call after stack dir exists. Does not store secrets.
fp_write_auth_policy() {
    local dest="${1:-${FP_HOME}/auth-policy.json}"
    local mode="${FP_AUTH_MODE:-local}"
    local provider="${FP_SSO_PROVIDER:-none}"
    local issuer="${FP_SSO_ISSUER:-}"
    local client_id="${FP_SSO_CLIENT_ID:-}"
    # Escape for JSON (minimal)
    issuer="${issuer//\\/\\\\}"
    issuer="${issuer//\"/\\\"}"
    client_id="${client_id//\\/\\\\}"
    client_id="${client_id//\"/\\\"}"
    cat >"$dest" <<JSON
{
  "version": 1,
  "authMode": "${mode}",
  "ssoProvider": "${provider}",
  "ssoIssuer": "${issuer}",
  "ssoClientId": "${client_id}",
  "breakGlassLocalAdmin": true,
  "notes": "Local break-glass admin always exists. Finish SSO mapping in Web UI Config Hub when ready."
}
JSON
    if [ -n "${FP_USER:-}" ]; then
        chown "${FP_USER}:${FP_USER}" "$dest" 2>/dev/null || true
    fi
    chmod 0644 "$dest" 2>/dev/null || true
    log_info "wrote auth policy: ${dest}"
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
