#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# bootstrap.sh — Post-install REST API bootstrap.
#
# After core comes up healthy on first run, this helper:
#
#   1. Logs in to /api/v1/auth/login as the admin user (proves the password
#      we just used for first-run init was actually accepted)
#   2. Creates a long-lived service token via /api/v1/tokens with a
#      LIMITED set of permissions — enough for the AI gateway to do data,
#      asset, query, mapping, and chat work, but NOT to manage users,
#      roles, system settings, or other tokens.
#   3. Appends FP_API_KEY=<token> to the .env file (mode 0600).
#
# The admin password is never persisted to disk by the installer. It lives
# in shell memory only — it's used to authenticate this one login call,
# then discarded. Subsequent `docker compose down/up` cycles work because
# the core entrypoint sees the existing config file and skips first-run
# init, so it never needs the password again.
#
# Required environment variables (set by the caller):
#   FP_ADMIN_USER         admin username
#   FP_ADMIN_PASS         admin password (in-memory only, not from .env)
#   FP_REST_PORT          REST API port (defaults to 7433)
#
# Arguments:
#   $1   path to the .env file to append FP_API_KEY to
#
# Exits non-zero on any failure with a clear error message.
# =============================================================================

if [ -n "${__FP_BOOTSTRAP_SH_LOADED:-}" ]; then
    return 0
fi
__FP_BOOTSTRAP_SH_LOADED=1

if [ -z "${__FP_COMMON_SH_LOADED:-}" ]; then
    # shellcheck source=common.sh
    . "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
fi

# ── Permission set granted to the AI gateway service token ──────────────────
# Excludes: USERS_MANAGE, ROLES_MANAGE, SYSTEM_ADMIN, TOKENS_MANAGE,
# SERIES_DELETE, GRANT. A leaked token can read/write data, manage assets
# and mappings, run queries, and use AI chat — it cannot escalate, create
# new users, or wipe data wholesale.
FP_GATEWAY_TOKEN_PERMISSIONS='[
    "DATA_READ",
    "DATA_WRITE",
    "SERIES_CREATE",
    "ASSETS_MANAGE",
    "DATASOURCES_VIEW",
    "MAPPINGS_MANAGE",
    "QUERY_EXECUTE",
    "AI_CHAT"
]'

# ── REST helpers ────────────────────────────────────────────────────────────

# Poll an HTTP endpoint until curl succeeds (2xx/3xx) or the timeout passes.
#   $1 url   $2 timeout_seconds   $3 human message (no trailing punctuation)
# Returns 0 on success, 1 on timeout.
#
# On an interactive terminal (stderr is a TTY) it shows a single live line —
# a rotating spinner plus elapsed seconds, redrawn in place — so a slow wait
# visibly reads as "working", not frozen. When stderr is NOT a TTY (piped,
# `| tee install.log`, CI, non-interactive), a spinner would spew carriage
# returns into the log, so it degrades to a quiet elapsed-time heartbeat
# every 15s. Each probe is capped with --max-time so one hung request can
# never stall the loop past its deadline.
_fp_wait_http() {
    local url="$1" timeout="$2" msg="$3"
    local start now elapsed deadline frame=0 last_beat=0 tty=0
    local -a frames
    # Braille spinner only on a UTF-8 locale; plain ASCII otherwise so a bare
    # server console / SSH session doesn't render mojibake.
    case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
        *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*) frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' ) ;;
        *) frames=( '|' '/' '-' "\\" ) ;;
    esac
    [ -t 2 ] && tty=1
    start=$(date +%s); deadline=$(( start + timeout ))
    while :; do
        if curl -fsS --max-time 5 -o /dev/null "$url" 2>/dev/null; then
            [ "$tty" = "1" ] && printf '\r\033[K' >&2
            return 0
        fi
        now=$(date +%s); elapsed=$(( now - start ))
        [ "$now" -ge "$deadline" ] && break
        if [ "$tty" = "1" ]; then
            printf '\r%s[..]%s %s %s... %ss' "${FP_C_BLUE}" "${FP_C_RESET}" \
                "${frames[$(( frame % ${#frames[@]} ))]}" "$msg" "$elapsed" >&2
            frame=$(( frame + 1 ))
            sleep 0.2
        else
            if [ "$(( elapsed - last_beat ))" -ge 15 ]; then
                log_info "  ${msg}... ${elapsed}s"
                last_beat="$elapsed"
            fi
            sleep 2
        fi
    done
    [ "$tty" = "1" ] && printf '\r\033[K' >&2
    return 1
}

# ── Service-key validation ──────────────────────────────────────────────────
# fp_gateway_token_state <env_file> [rest_port]
#
# Presence is not validity: a well-formed FP_API_KEY line can name a token
# core has no record of (data volume replaced/restored after the mint, token
# revoked in Settings → Tokens). Field incident 2026-08: a fresh customer
# install carried exactly that, booted green, and every Core-data feature
# failed at first use with a bare 401. Probe once with the real credential.
#
# Prints one word on stdout:
#   absent   — no FP_API_KEY line (or empty value)
#   valid    — core accepted the credential (HTTP 200 on /auth/me)
#   invalid  — core REJECTED it (HTTP 401/403) → caller should re-mint
#   unknown  — core unreachable / any other answer → carry forward, never
#              force a re-mint on a transient
fp_gateway_token_state() {
    local env_file="$1" port="${2:-7433}" key code
    [ -f "$env_file" ] || { printf 'absent\n'; return 0; }
    # tail -n1: compose v2's dotenv is last-occurrence-wins for repeated
    # keys, so validate the line the gateway would actually receive.
    key="$(sed -n 's/^FP_API_KEY=//p' "$env_file" 2>/dev/null | tail -n1)" || true
    if [ -z "$key" ]; then
        printf 'absent\n'
        return 0
    fi
    # Header via stdin (-H @-) so the credential never appears in curl's
    # argv — same reason the mint below pipes the admin password. curl has
    # supported @- header files since 7.55 (2017); every supported platform
    # ships newer.
    code=$(printf 'Authorization: Bearer %s\n' "$key" | \
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H @- \
        "http://127.0.0.1:${port}/api/v1/auth/me" 2>/dev/null) || code=000
    case "$code" in
        200)     printf 'valid\n' ;;
        401|403) printf 'invalid\n' ;;
        *)       printf 'unknown\n' ;;
    esac
}

# Wait for /api/v1/health to return 200. Times out after 3 minutes.
fp_wait_for_api_ready() {
    local port="${1:-7433}"
    log_info "waiting for REST API on port ${port} to accept requests..."
    if _fp_wait_http "http://127.0.0.1:${port}/api/v1/health" 180 "starting core"; then
        log_success "REST API is responding"
        return 0
    fi
    die "timed out waiting for REST API on port ${port}"
}

# Wait for the AI Gateway /health endpoint to return 200. Times out after
# 3 minutes. Unlike fp_wait_for_api_ready this returns non-zero instead of
# dying, so the caller can attach its own remediation hint (typically a
# pointer at `docker logs falconpulsar-ai-gateway`). Installers use it as
# a hard gate after `docker compose up -d`; fp_wipe_gateway_seed_defaults
# runs after this gate in the install flow.
fp_wait_for_gateway_ready() {
    local port="${1:-${FP_GATEWAY_PORT:-7436}}"
    log_info "waiting for AI Gateway on port ${port} to accept requests..."
    if _fp_wait_http "http://127.0.0.1:${port}/health" 180 "starting AI Gateway"; then
        log_success "AI Gateway is responding"
        return 0
    fi
    log_error "timed out waiting for the AI Gateway on port ${port}"
    return 1
}

# Extract a quoted string field from a flat JSON object.
# Usage: _fp_json_str '<json>' <field-name>
# Returns the value of "field":"value" or empty string. Not a real JSON
# parser — works for the simple flat responses we get from /auth/login
# and /tokens. Same pattern documented in CLAUDE.md.
_fp_json_str() {
    # `|| true`: grep -o exits 1 when the field is absent. Under errexit+pipefail
    # a bare `x=$(_fp_json_str …)` at the call sites would abort BEFORE the
    # `if [ -z "$x" ]` handlers that are meant to catch a missing token field.
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n1 | cut -d'"' -f4 || true
}

# ── Main bootstrap entry point ──────────────────────────────────────────────
# fp_bootstrap_gateway_token <env-file-path>
fp_bootstrap_gateway_token() {
    local env_file="$1"
    local port="${FP_REST_PORT:-7433}"

    [ -n "${FP_ADMIN_USER:-}" ] || die "FP_ADMIN_USER must be set before bootstrap"
    [ -n "${FP_ADMIN_PASS:-}" ] || die "FP_ADMIN_PASS must be set before bootstrap"
    [ -n "$env_file" ] || die "fp_bootstrap_gateway_token: env file path required"

    require_cmd curl

    fp_wait_for_api_ready "$port"

    log_step "creating AI gateway service token via REST API"

    # ── 1. Login as admin → JWT ─────────────────────────────────────────────
    log_info "logging in as ${FP_ADMIN_USER}..."

    # We use --data-binary @- to feed the JSON body via stdin so the
    # admin password is never visible in the curl process arguments
    # (which would otherwise show up in `ps` while the call is in flight).
    local login_resp
    login_resp=$(printf '{"username":"%s","password":"%s"}' \
        "$FP_ADMIN_USER" "$FP_ADMIN_PASS" | \
        curl -fsS \
            -X POST \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            "http://127.0.0.1:${port}/api/v1/auth/login" 2>&1) || {
        log_error "login failed (HTTP error or network failure)"
        log_error "response: $login_resp"
        die "could not authenticate as admin to create the gateway service token"
    }

    local jwt
    jwt=$(_fp_json_str "$login_resp" "token")
    if [ -z "$jwt" ]; then
        log_error "login response did not contain a token field"
        log_error "response: $login_resp"
        die "could not parse JWT from login response"
    fi
    log_success "admin login successful"

    # ── 2. Create the gateway service token ─────────────────────────────────
    log_info "creating service token with limited permissions..."

    local token_body
    token_body=$(printf '{"name":"ai-gateway-token","expires_days":0,"permissions":%s}' \
        "$FP_GATEWAY_TOKEN_PERMISSIONS")

    local token_resp
    token_resp=$(printf '%s' "$token_body" | \
        curl -fsS \
            -X POST \
            -H 'Content-Type: application/json' \
            -H "Authorization: Bearer ${jwt}" \
            --data-binary @- \
            "http://127.0.0.1:${port}/api/v1/tokens" 2>&1) || {
        log_error "token creation failed"
        log_error "response: $token_resp"
        die "could not create AI gateway service token"
    }

    local token
    token=$(_fp_json_str "$token_resp" "token")
    if [ -z "$token" ]; then
        log_error "tokens response did not contain a token field"
        log_error "response: $token_resp"
        die "could not parse token from tokens response"
    fi
    log_success "service token created"

    # ── 3. Append FP_API_KEY to .env (preserve perms) ───────────────────────
    # Use a temp file + mv to keep this atomic. We preserve BOTH ownership
    # AND mode from the original file rather than hard-coding, because the
    # Linux installer sets .env to 0640 falconpulsar:docker while macOS
    # keeps it 0600 user:staff -- the two platforms must not clobber each
    # other when this helper is shared.
    local env_owner env_group env_mode
    env_owner=$(stat -c '%U' "$env_file" 2>/dev/null || stat -f '%Su' "$env_file" 2>/dev/null || echo "")
    env_group=$(stat -c '%G' "$env_file" 2>/dev/null || stat -f '%Sg' "$env_file" 2>/dev/null || echo "")
    env_mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null || echo "600")
    # stat -f on BSD can emit e.g. "640" without leading zero; guard just in case.
    case "$env_mode" in
        [0-7][0-7][0-7]) ;;
        *) env_mode="600" ;;
    esac

    # SEC-003: generate the provider-key encryption secret alongside the
    # service token (only when absent — never rotate implicitly, since
    # rotating orphans previously-encrypted provider keys).
    local gateway_secret=""
    if ! grep -q '^FP_GATEWAY_SECRET=.' "$env_file" 2>/dev/null; then
        if command -v openssl >/dev/null 2>&1; then
            gateway_secret=$(openssl rand -hex 32)
        else
            gateway_secret=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
        fi
    fi

    umask 077
    {
        # Drop the incomplete-setup marker left by an unattended upgrade
        # that skipped the mint (see fp_try_upgrade_fastpath) — the token
        # appended below is exactly what it was waiting for. Also drop any
        # existing FP_API_KEY line: a re-mint over an INVALID carried-forward
        # key (fp_gateway_token_state=invalid) must replace it, not leave a
        # duplicate line (compose's dotenv is last-wins so the append would
        # still work, but validators and humans reading .env should never
        # meet two keys).
        sed -e '/^FP_AI_SETUP_INCOMPLETE=/d' -e '/^FP_API_KEY=/d' "$env_file"
        printf 'FP_API_KEY=%s\n' "$token"
        if [ -n "$gateway_secret" ]; then
            printf 'FP_GATEWAY_SECRET=%s\n' "$gateway_secret"
        fi
    } > "${env_file}.new"

    if [ -n "$env_owner" ] && [ -n "$env_group" ]; then
        chown "${env_owner}:${env_group}" "${env_file}.new" 2>/dev/null || true
    fi
    chmod "0${env_mode}" "${env_file}.new"
    mv "${env_file}.new" "$env_file"
    umask 022

    log_success "FP_API_KEY appended to ${env_file}"
}

# ── AI Gateway: wipe self-seeded providers + models ─────────────────────────
# fp_wipe_gateway_seed_defaults [container_name] [port]
#
# The AI Gateway image self-seeds 3 default providers (Anthropic, Grok,
# Ollama) and 6 default models (Claude Opus 4.6, Claude Sonnet 4.5, Grok 4,
# Llama 3.1 8B, Mistral 7B, Gemma 2 9B) into its SQLite on first boot.
# This produces a misleading UX where the toolbar shows "Llama 3.1 8B" as
# the active model and the Models page lists 6 entries flagged "Offline"
# even on a clean install where the user has not configured any LLM
# provider. They reasonably assume the installer hardcoded these — it
# didn't (verified: zero model names anywhere in this repo's source).
#
# Until falconpulsar/ai-gateway gates seeding behind an env var (e.g.
# FP_GATEWAY_SEED_DEFAULTS=0) or stops seeding entirely, this helper runs
# AFTER the gateway becomes healthy and DELETEs the self-seeded rows so
# the user starts with a truly empty AI configuration. They then add
# their own providers via the Web UI's AI Configuration page.
#
# `knowledge_documents` is intentionally left alone — those 8 RAG entries
# are domain knowledge about FalconPulsar itself and are useful at install
# time. Only the LLM provider/model catalog gets wiped.
#
# Order of operations:
#   1. Poll http://127.0.0.1:${FP_GATEWAY_PORT}/health until 200 OK
#      (max 90 s). This is the only wait we need: the gateway seeds the
#      provider/model catalog SYNCHRONOUSLY during startup, before it
#      binds the port and answers /health (main.py awaits
#      seed_gateway_from_config well before it yields). So a 200 here
#      guarantees the rows we are about to DELETE already exist — our
#      DELETEs cannot be undone by a later seed INSERT.
#
#      We deliberately do NOT wait for the background knowledge warm-up
#      (the ~1.3GB embedding-model download, components.knowledge ==
#      "warming"). It is unrelated to the provider/model catalog, it can
#      take many minutes on a slow link, and the restart in step 3 is
#      explicitly tolerated mid-warm-up (persistent model cache + top-up
#      seeding make it convergent across restarts). Blocking the install
#      on that download only made a fast install look frozen — the exact
#      symptom users reported.
#   2. docker exec into the container, DELETE FROM both tables.
#   3. docker restart the container — the gateway loads provider/model
#      state into memory at startup, so without a restart the API would
#      keep serving the stale in-memory list. The interrupted model
#      download simply resumes in the background after the restart.
#   4. Re-poll /health so subsequent install steps see a healthy stack.
#
# Non-fatal: any failure logs a warning and returns 0. We never abort an
# otherwise-successful install just because the cosmetic cleanup didn't
# work.
#
# TODO(falconpulsar/ai-gateway): land the upstream fix (skip seeding by
# default, or gate with an env var) and remove this whole function plus
# its call sites (linux + macOS install.sh, shared upgrade fast-path).
fp_wipe_gateway_seed_defaults() {
    local container="${1:-falconpulsar-ai-gateway}"
    local port="${2:-${FP_GATEWAY_PORT:-7436}}"

    # Step 1: /health 200 guarantees the provider/model catalog is seeded
    # (main.py seeds it before binding the port). We do NOT wait for the
    # background embedding-model download — see the note above.
    log_info "waiting for AI Gateway to finish init before wiping seed defaults"
    if ! _fp_wait_http "http://127.0.0.1:${port}/health" 90 "waiting for AI Gateway"; then
        log_warn "AI Gateway did not become healthy in 90s — leaving seed defaults in place"
        return 0
    fi

    # Step 2: DELETE the self-seeded catalog.
    log_info "removing AI Gateway's self-seeded providers and models"
    if ! docker exec "$container" \
            sqlite3 /app/data/ai_config.db \
            "DELETE FROM model_definitions; DELETE FROM provider_configs;" \
            >/dev/null 2>&1; then
        log_warn "could not wipe seed defaults (sqlite3 missing in image, or schema changed?) — install continues"
        return 0
    fi

    # Step 3: restart so the in-memory catalog matches the wiped DB. This may
    # interrupt the background model download; it resumes on the next boot.
    log_info "restarting AI Gateway so in-memory state matches wiped DB"
    docker restart "$container" >/dev/null 2>&1 || true

    # Step 4: re-poll so later install steps see a healthy stack.
    if _fp_wait_http "http://127.0.0.1:${port}/health" 60 "AI Gateway restarting"; then
        log_success "AI Gateway clean: 0 providers, 0 models"
        return 0
    fi
    log_warn "AI Gateway slow to come back after wipe — UI may show stale models for a moment"
    return 0
}
