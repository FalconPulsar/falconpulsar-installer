# =============================================================================
# registry_auth.sh — container registry detection and authentication.
#
# FalconPulsar images can be pulled from any OCI-compliant registry: Docker
# Hub (default), GHCR, Quay, Harbor, GitLab, self-hosted, AWS ECR, GCR,
# Azure ACR. The installer does not care which one — it just needs to be
# able to pull `${FP_REGISTRY}/core:${FP_VERSION}`.
#
# This library implements the "probe, then prompt if needed" flow:
#
#   1. fp_registry_probe — try `docker manifest inspect` against the
#      configured registry. No credentials required; succeeds for public
#      images and pre-authenticated users.
#
#   2. fp_registry_prompt — if the probe fails with an auth error,
#      interactively ask the user for credentials or a different registry.
#
#   3. fp_registry_login — wrap `docker login --password-stdin` with
#      proper error detection and hostname extraction.
#
#   4. fp_registry_ensure_access — top-level orchestrator. Call this from
#      linux/install.sh or macos/install.sh after the Docker daemon check
#      and before `docker compose pull`.
#
# All authentication goes through `docker login --password-stdin` so the
# password never touches argv. Docker stores the credential in the user's
# config.json (optionally backed by the OS keychain if a credential helper
# is configured).
#
# Honoured environment variables for unattended / CI use:
#
#   FP_REGISTRY         Registry URL prefix (default: docker.io/falconpulsar)
#   FP_VERSION          Image tag to probe (default: latest)
#   FP_REGISTRY_USER    Pre-provided username
#   FP_REGISTRY_PASS    Pre-provided password / token
#   FP_REGISTRY_SKIP    Set to 1 to skip the probe entirely (air-gapped /
#                       pre-pulled images / private mirror)
#
# In FP_ASSUME_YES=1 mode with no env credentials and a private registry,
# this library fails fast with a clear error instead of hanging on a
# prompt.
# =============================================================================

[ "${FP_REGISTRY_AUTH_SH_LOADED:-0}" = "1" ] && return 0
FP_REGISTRY_AUTH_SH_LOADED=1

# Default registry if the user hasn't overridden it.
: "${FP_REGISTRY:=docker.io/falconpulsar}"
: "${FP_VERSION:=latest}"

# The sentinel image used for the probe. Picking `core` because it exists in
# every FalconPulsar distribution; probing a smaller image would be faster
# but would require a separate small image to always exist.
: "${FP_REGISTRY_SENTINEL:=core}"

# Maximum number of credential retries before giving up and letting the user
# pick a different registry or cancel.
: "${FP_REGISTRY_MAX_RETRIES:=3}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# fp_registry_hostname <registry-prefix>
# Extract the hostname portion from a registry prefix for use with
# `docker login`. Examples:
#   docker.io/falconpulsar          -> docker.io
#   ghcr.io/falconpulsar            -> ghcr.io
#   123.dkr.ecr.us-east-1.amazonaws.com/fp -> 123.dkr.ecr.us-east-1.amazonaws.com
#   myregistry.corp.example.com:5000/fp    -> myregistry.corp.example.com:5000
fp_registry_hostname() {
    local reg="$1"
    printf '%s\n' "${reg%%/*}"
}

# fp_registry_image_path <registry-prefix> <image-name> <tag>
# Build the full image reference used by docker commands.
fp_registry_image_path() {
    printf '%s/%s:%s\n' "$1" "$2" "$3"
}

# fp_registry_is_public_hostname <hostname>
# Heuristic: returns 0 if the hostname is commonly used for public anonymous
# pulls. Used for nicer error messages; not security-critical.
fp_registry_is_public_hostname() {
    case "$1" in
        docker.io|index.docker.io|registry-1.docker.io) return 0 ;;
        ghcr.io|quay.io|public.ecr.aws) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Probe ───────────────────────────────────────────────────────────────────

# fp_registry_probe [registry] [image] [tag]
# Returns:
#   0 — the image is pullable (public or user already authenticated)
#   1 — authentication required (private registry, no valid creds)
#   2 — other error (network, DNS, rate limit, not found, etc.)
#
# Uses `docker manifest inspect`, which does a HEAD-ish request on the
# manifest without actually pulling layers. Fast and cheap.
fp_registry_probe() {
    local reg="${1:-$FP_REGISTRY}"
    local image="${2:-$FP_REGISTRY_SENTINEL}"
    local tag="${3:-$FP_VERSION}"
    local ref
    ref="$(fp_registry_image_path "$reg" "$image" "$tag")"

    log_info "probing ${ref} ..."

    # Capture stderr so we can classify the error. stdout would be the
    # manifest JSON, which we don't care about.
    local err
    if err="$(DOCKER_CLI_HINTS=false docker manifest inspect "$ref" 2>&1 >/dev/null)"; then
        log_success "registry probe: OK (${ref} is pullable)"
        return 0
    fi

    # Classify the error. Docker's wording is regrettably not stable across
    # versions, so we match multiple phrasings.
    case "$err" in
        *"unauthorized"*|*"authentication required"*|*"requested access"*denied*|*"pull access denied"*)
            log_warn "registry probe: authentication required"
            log_debug "docker error: ${err}"
            return 1
            ;;
        *"no such host"*|*"dial tcp"*|*"TLS handshake timeout"*|*"connection refused"*)
            log_error "registry probe: network error"
            log_error "${err}"
            return 2
            ;;
        *"manifest unknown"*|*"not found"*|*"NAME_UNKNOWN"*|*"MANIFEST_UNKNOWN"*)
            log_error "registry probe: image ${ref} does not exist on the registry"
            log_error "${err}"
            return 2
            ;;
        *"toomanyrequests"*|*"rate limit"*)
            log_error "registry probe: rate-limited by the registry"
            log_error "If using Docker Hub anonymously, log in first to raise the rate limit."
            log_error "${err}"
            return 2
            ;;
        *)
            log_error "registry probe: unexpected error"
            log_error "${err}"
            return 2
            ;;
    esac
}

# ─── Login ───────────────────────────────────────────────────────────────────

# fp_registry_login <registry-prefix> <username> <password>
# Runs `docker login <hostname> -u <user> --password-stdin`. The password
# is piped to docker via stdin so it never appears in argv or process
# listings. Returns 0 on success, 1 on auth failure, 2 on other error.
fp_registry_login() {
    local reg="$1"
    local user="$2"
    local pass="$3"
    local host
    host="$(fp_registry_hostname "$reg")"

    log_info "logging in to ${host} as ${user} ..."

    local err
    if err="$(printf '%s' "$pass" | docker login "$host" --username "$user" --password-stdin 2>&1)"; then
        log_success "docker login ${host}: OK"
        return 0
    fi

    case "$err" in
        *"unauthorized"*|*"incorrect"*|*"denied"*|*"401"*)
            log_error "credentials rejected by ${host}"
            log_debug "docker error: ${err}"
            return 1
            ;;
        *)
            log_error "docker login failed: ${err}"
            return 2
            ;;
    esac
}

# ─── Interactive prompt ──────────────────────────────────────────────────────

# fp_registry_prompt_credentials <registry-prefix>
# Read username and password from the terminal, filling FP_REGISTRY_USER
# and FP_REGISTRY_PASS. Password entry is silent (stty -echo).
fp_registry_prompt_credentials() {
    local reg="$1"
    local host
    host="$(fp_registry_hostname "$reg")"

    printf '\n'
    printf '    Registry: %s\n' "$host"
    printf '    Username: '
    IFS= read -r FP_REGISTRY_USER || return 1
    printf '    Password (input hidden): '
    stty -echo 2>/dev/null || true
    IFS= read -r FP_REGISTRY_PASS || { stty echo 2>/dev/null || true; return 1; }
    stty echo 2>/dev/null || true
    printf '\n'

    if [ -z "$FP_REGISTRY_USER" ] || [ -z "$FP_REGISTRY_PASS" ]; then
        log_error "username and password are required"
        return 1
    fi
    return 0
}

# fp_registry_prompt_registry
# Ask the user for an alternative registry URL and update FP_REGISTRY.
fp_registry_prompt_registry() {
    printf '\n    Current registry: %s\n' "$FP_REGISTRY"
    printf '    New registry (hostname/namespace): '
    local new_reg
    IFS= read -r new_reg || return 1
    if [ -z "$new_reg" ]; then
        log_error "registry URL cannot be empty"
        return 1
    fi
    FP_REGISTRY="$new_reg"
    # Invalidate any previously-provided credentials — they likely don't
    # apply to the new registry.
    FP_REGISTRY_USER=""
    FP_REGISTRY_PASS=""
    log_info "registry updated to ${FP_REGISTRY}"
    return 0
}

# fp_registry_prompt_menu
# Show the "what do you want to do?" menu when a probe fails with auth.
# Returns the user's choice via stdout: "creds" | "different" | "cancel".
fp_registry_prompt_menu() {
    printf '\n' >&2
    printf '    The registry at %s requires authentication.\n' "$(fp_registry_hostname "$FP_REGISTRY")" >&2
    printf '\n' >&2
    printf '        1) I have credentials for this registry\n' >&2
    printf '        2) Use a different registry\n' >&2
    printf '        3) Cancel installation\n' >&2
    printf '\n' >&2
    printf '    Your choice [1]: ' >&2
    local choice
    IFS= read -r choice || { printf 'cancel\n'; return; }
    case "${choice:-1}" in
        1) printf 'creds\n' ;;
        2) printf 'different\n' ;;
        3|q|Q|cancel) printf 'cancel\n' ;;
        *) printf 'creds\n' ;;
    esac
}

# ─── Top-level orchestrator ──────────────────────────────────────────────────

# fp_registry_ensure_access
# Guarantees that `docker pull ${FP_REGISTRY}/...` will work when the
# installer gets there. Probes, prompts, logs in, re-probes, retries.
# Honours FP_REGISTRY_SKIP, FP_REGISTRY_USER, FP_REGISTRY_PASS, and
# FP_ASSUME_YES for unattended installs.
fp_registry_ensure_access() {
    if [ "${FP_REGISTRY_SKIP:-0}" = "1" ]; then
        log_warn "registry probe skipped (FP_REGISTRY_SKIP=1)"
        log_warn "make sure images at ${FP_REGISTRY} are already available or pre-pulled"
        return 0
    fi

    log_step "verifying access to ${FP_REGISTRY}"

    # If credentials were pre-provided via env vars, log in up front.
    if [ -n "${FP_REGISTRY_USER:-}" ] && [ -n "${FP_REGISTRY_PASS:-}" ]; then
        log_info "using pre-provided registry credentials from environment"
        if ! fp_registry_login "$FP_REGISTRY" "$FP_REGISTRY_USER" "$FP_REGISTRY_PASS"; then
            die "registry login failed with the provided credentials"
        fi
    fi

    local attempts=0
    while : ; do
        fp_registry_probe
        local rc=$?
        case $rc in
            0) return 0 ;;
            1)
                # Auth required. If we're non-interactive and have no
                # credentials left to try, fail fast.
                if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
                    log_error ""
                    log_error "Registry ${FP_REGISTRY} requires authentication but running"
                    log_error "in non-interactive mode (FP_ASSUME_YES=1) and no valid"
                    log_error "credentials were provided."
                    log_error ""
                    log_error "Set FP_REGISTRY_USER and FP_REGISTRY_PASS in the environment"
                    log_error "and re-run, or set FP_REGISTRY to a public mirror."
                    die "registry authentication required (non-interactive)"
                fi
                ;;
            2) die "cannot reach registry ${FP_REGISTRY}" ;;
        esac

        # Interactive: show menu, collect input, retry.
        local choice
        choice="$(fp_registry_prompt_menu)"
        case "$choice" in
            cancel)
                log_error "installation cancelled by user"
                exit 1
                ;;
            different)
                if ! fp_registry_prompt_registry; then
                    continue
                fi
                attempts=0
                continue
                ;;
            creds)
                if ! fp_registry_prompt_credentials "$FP_REGISTRY"; then
                    continue
                fi
                if fp_registry_login "$FP_REGISTRY" "$FP_REGISTRY_USER" "$FP_REGISTRY_PASS"; then
                    # Wipe the password from shell env now that docker has it.
                    FP_REGISTRY_PASS=""
                    attempts=0
                    continue
                else
                    attempts=$((attempts + 1))
                    if [ "$attempts" -ge "$FP_REGISTRY_MAX_RETRIES" ]; then
                        log_error ""
                        log_error "Too many failed login attempts ($attempts)."
                        log_error "Need access? Email security@falconpulsar.com."
                        die "registry authentication failed"
                    fi
                    log_warn "retrying ($attempts/$FP_REGISTRY_MAX_RETRIES)"
                    continue
                fi
                ;;
        esac
    done
}
