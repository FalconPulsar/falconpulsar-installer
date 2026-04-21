# shellcheck shell=bash
# =============================================================================
# FalconPulsar — shared admin-auth helper
# =============================================================================
#
# Exposes:
#   fp_authenticate_admin [max_attempts]
#     Prompt for admin username + password on stderr. Verify against the
#     running Core REST API (login + /auth/me role check). Retries up to
#     max_attempts (default 3).
#
#     Exit codes:
#       0  authenticated as admin
#       1  failed (wrong password, not admin, user cancelled, curl missing)
#       2  Core REST API is not reachable — caller should decide whether to
#          bypass auth (e.g. prompt user) or abort.
#
# Requires: curl. Reads FP_REST_PORT from env (default 7433).
# Writes the authenticated username to stderr on success.
# =============================================================================

fp_authenticate_admin() {
    local max_attempts="${1:-3}"
    local port="${FP_REST_PORT:-7433}"
    local base="http://127.0.0.1:${port}"
    local attempt=0
    local user pass login_resp jwt me_resp role http_code

    if ! command -v curl >/dev/null 2>&1; then
        printf '[error] curl is required for admin authentication\n' >&2
        return 1
    fi

    # Fast fail if Core is not reachable at all.
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
                  "${base}/api/v1/auth/login" \
                  -X OPTIONS 2>/dev/null || echo '000')
    if [ "$http_code" = '000' ]; then
        printf '[warn] Cannot reach FalconPulsar Core at %s.\n' "$base" >&2
        return 2
    fi

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        printf '\n' >&2
        printf 'Admin username [admin]: ' >&2
        read -r user </dev/tty || user=''
        [ -z "$user" ] && user='admin'

        printf 'Admin password: ' >&2
        # Disable terminal echo while reading the password.
        if [ -t 0 ] || [ -r /dev/tty ]; then
            stty -echo </dev/tty 2>/dev/null || true
            read -r pass </dev/tty || pass=''
            stty echo </dev/tty 2>/dev/null || true
        else
            read -r pass || pass=''
        fi
        printf '\n' >&2

        if [ -z "$pass" ]; then
            printf '[warn] Password is empty. Try again.\n' >&2
            continue
        fi

        # Login (via stdin so the password never appears in `ps`).
        login_resp=$(printf '{"username":"%s","password":"%s"}' "$user" "$pass" | \
            curl -fsS -X POST \
                -H 'Content-Type: application/json' \
                --data-binary @- \
                "${base}/api/v1/auth/login" 2>/dev/null || true)

        jwt=$(printf '%s' "$login_resp" | \
              sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)

        if [ -z "$jwt" ]; then
            printf '[error] Incorrect username or password.\n' >&2
            continue
        fi

        me_resp=$(curl -fsS -H "Authorization: Bearer ${jwt}" \
                    "${base}/api/v1/auth/me" 2>/dev/null || true)
        role=$(printf '%s' "$me_resp" | \
               sed -nE 's/.*"role"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
        if [ -z "$role" ]; then
            role=$(printf '%s' "$me_resp" | \
                   sed -nE 's/.*"roles"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
        fi

        if [ "$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" = 'admin' ]; then
            printf '[ok] Authenticated as %s (admin).\n' "$user" >&2
            return 0
        fi

        printf '[error] This account is not an administrator.\n' >&2
    done

    printf '\n[error] Too many failed attempts. Aborting.\n' >&2
    return 1
}

# fp_verify_admin_credentials <user> <password>
#   One-shot, non-interactive verification. Used by the SwiftUI / Inno Setup
#   installers which collect credentials in their own UI and pass them through
#   via env vars. No prompts, no retries.
#
#   Exit codes: same as fp_authenticate_admin (0 ok, 1 failed, 2 unreachable).
fp_verify_admin_credentials() {
    local user="$1"
    local pass="$2"
    local port="${FP_REST_PORT:-7433}"
    local base="http://127.0.0.1:${port}"
    local http_code login_resp jwt me_resp role

    if ! command -v curl >/dev/null 2>&1; then
        printf '[error] curl is required for admin authentication\n' >&2
        return 1
    fi
    if [ -z "$user" ] || [ -z "$pass" ]; then
        printf '[error] fp_verify_admin_credentials: username and password required\n' >&2
        return 1
    fi

    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
                  "${base}/api/v1/auth/login" -X OPTIONS 2>/dev/null || echo '000')
    if [ "$http_code" = '000' ]; then
        printf '[warn] Cannot reach FalconPulsar Core at %s.\n' "$base" >&2
        return 2
    fi

    login_resp=$(printf '{"username":"%s","password":"%s"}' "$user" "$pass" | \
        curl -fsS -X POST \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            "${base}/api/v1/auth/login" 2>/dev/null || true)
    jwt=$(printf '%s' "$login_resp" | \
          sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    if [ -z "$jwt" ]; then
        printf '[error] Incorrect username or password.\n' >&2
        return 1
    fi

    me_resp=$(curl -fsS -H "Authorization: Bearer ${jwt}" \
                "${base}/api/v1/auth/me" 2>/dev/null || true)
    role=$(printf '%s' "$me_resp" | \
           sed -nE 's/.*"role"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    if [ -z "$role" ]; then
        role=$(printf '%s' "$me_resp" | \
               sed -nE 's/.*"roles"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    fi

    if [ "$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" = 'admin' ]; then
        printf '[ok] Admin credentials verified.\n' >&2
        return 0
    fi
    printf '[error] This account is not an administrator.\n' >&2
    return 1
}
