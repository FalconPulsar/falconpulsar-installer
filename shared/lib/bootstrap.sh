#!/usr/bin/env bash
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

# Wait for /api/v1/health to return 200. Times out after 3 minutes.
fp_wait_for_api_ready() {
    local port="${1:-7433}"
    local deadline=$(( $(date +%s) + 180 ))

    log_info "waiting for REST API on port ${port} to accept requests..."
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS -o /dev/null "http://127.0.0.1:${port}/api/v1/health" 2>/dev/null; then
            log_success "REST API is responding"
            return 0
        fi
        sleep 2
    done
    die "timed out waiting for REST API on port ${port}"
}

# Extract a quoted string field from a flat JSON object.
# Usage: _fp_json_str '<json>' <field-name>
# Returns the value of "field":"value" or empty string. Not a real JSON
# parser — works for the simple flat responses we get from /auth/login
# and /tokens. Same pattern documented in CLAUDE.md.
_fp_json_str() {
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n1 | cut -d'"' -f4
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

    umask 077
    {
        cat "$env_file"
        printf 'FP_API_KEY=%s\n' "$token"
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
# fp_wipe_gateway_seed_defaults [container_name]
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
#      (max 90 s). Without the wait, the gateway's seed INSERTs would
#      run AFTER our DELETEs and undo them.
#   2. docker exec into the container, DELETE FROM both tables.
#   3. docker restart the container — the gateway loads provider/model
#      state into memory at startup, so without a restart the API would
#      keep serving the stale in-memory list.
#   4. Re-poll /health so subsequent install steps see a healthy stack.
#
# Non-fatal: any failure logs a warning and returns 0. We never abort an
# otherwise-successful install just because the cosmetic cleanup didn't
# work.
#
# TODO(falconpulsar/ai-gateway): land the upstream fix (skip seeding by
# default, or gate with an env var) and remove this whole function plus
# its 5 call sites (linux + macOS install.sh, fp CLI ai enable, macOS
# menu-bar EnableAI, Windows tray EnableAI).
fp_wipe_gateway_seed_defaults() {
    local container="${1:-falconpulsar-ai-gateway}"
    local port="${FP_GATEWAY_PORT:-7436}"
    local deadline

    deadline=$(( $(date +%s) + 90 ))
    log_info "waiting for AI Gateway to finish init before wiping seed defaults"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS -o /dev/null "http://127.0.0.1:${port}/health" 2>/dev/null; then
            break
        fi
        sleep 2
    done
    if ! curl -fsS -o /dev/null "http://127.0.0.1:${port}/health" 2>/dev/null; then
        log_warn "AI Gateway did not become healthy in 90s — leaving seed defaults in place"
        return 0
    fi

    log_info "removing AI Gateway's self-seeded providers and models"
    if ! docker exec "$container" \
            sqlite3 /app/data/ai_config.db \
            "DELETE FROM model_definitions; DELETE FROM provider_configs;" \
            >/dev/null 2>&1; then
        log_warn "could not wipe seed defaults (sqlite3 missing in image, or schema changed?) — install continues"
        return 0
    fi

    log_info "restarting AI Gateway so in-memory state matches wiped DB"
    docker restart "$container" >/dev/null 2>&1 || true

    deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS -o /dev/null "http://127.0.0.1:${port}/health" 2>/dev/null; then
            log_success "AI Gateway clean: 0 providers, 0 models"
            return 0
        fi
        sleep 2
    done
    log_warn "AI Gateway slow to come back after wipe — UI may show stale models for a moment"
    return 0
}
