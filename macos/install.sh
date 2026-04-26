#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — macOS Installer
# =============================================================================
#
# End-to-end installer for macOS 14 Sonoma+ on Apple Silicon or Intel.
#
# Unlike the Linux installer, this script does NOT install a container
# runtime — macOS users must already have one of:
#
#   - Docker Desktop (commercial-use licensing applies)
#   - Colima         (free, recommended for businesses)
#   - Rancher Desktop (free)
#   - OrbStack       (paid for commercial use)
#
# It also does NOT create a separate `falconpulsar` user (macOS strongly
# discourages headless service accounts). Instead, the stack lives in
# ~/falconpulsar/ owned by the current user, and lifecycle is managed by
# Docker's `restart: unless-stopped` flag.
#
# What this script does:
#
#   1. Pre-flight: macOS version, arch, RAM, disk, ports
#   2. Detect which container runtime is present
#   3. Create ~/falconpulsar/ + ~/falconpulsar/data/
#   4. Generate compose.yml + .env
#   5. Pull images and start the stack
#   6. Wait for the core healthcheck and print connection details
#
# Usage:
#   bash install.sh                      # interactive
#   FP_ADMIN_PASS=hunter2 bash install.sh --yes
#
# Re-running this script is safe — it detects the existing install and
# offers to upgrade in place.
#
# Uninstall: bash uninstall.sh
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared/lib/common.sh
. "${REPO_ROOT}/shared/lib/common.sh"
# shellcheck source=../shared/lib/checks.sh
. "${REPO_ROOT}/shared/lib/checks.sh"
# shellcheck source=../shared/lib/prompts.sh
. "${REPO_ROOT}/shared/lib/prompts.sh"
# shellcheck source=../shared/lib/bootstrap.sh
. "${REPO_ROOT}/shared/lib/bootstrap.sh"
# shellcheck source=../shared/lib/registry_auth.sh
. "${REPO_ROOT}/shared/lib/registry_auth.sh"
# shellcheck source=../shared/lib/fpcli.sh
. "${REPO_ROOT}/shared/lib/fpcli.sh"
# shellcheck source=../shared/lib/existing.sh
. "${REPO_ROOT}/shared/lib/existing.sh"

trap 'on_error $LINENO' ERR

# ── Defaults ────────────────────────────────────────────────────────────────
FP_HOME="${FP_HOME:-${HOME}/falconpulsar}"
FP_DATA_DIR="${FP_DATA_DIR:-${FP_HOME}/data}"
FP_GATEWAY_DATA_DIR="${FP_GATEWAY_DATA_DIR:-${FP_HOME}/ai-gateway-data}"
FP_REST_PORT="${FP_REST_PORT:-7433}"
FP_WS_PORT="${FP_WS_PORT:-7434}"
FP_PUBSUB_PORT="${FP_PUBSUB_PORT:-7435}"
FP_GATEWAY_PORT="${FP_GATEWAY_PORT:-7436}"
FP_UI_PORT="${FP_UI_PORT:-8080}"
FP_LOG_LEVEL="${FP_LOG_LEVEL:-info}"

print_help() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --home <path>     Stack directory (default: ~/falconpulsar)
  --data-dir <path> Database directory (default: ~/falconpulsar/data)
  --rest-port <n>   REST API port (default: 7433)
  --ui-port <n>     Web UI port (default: 8080)
  --yes, -y         Assume yes to all prompts
  --debug           Verbose debug output
  --help, -h        This help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --home)        FP_HOME="$2"; FP_DATA_DIR="${FP_HOME}/data"; shift 2 ;;
        --data-dir)    FP_DATA_DIR="$2"; shift 2 ;;
        --rest-port)   FP_REST_PORT="$2"; shift 2 ;;
        --ui-port)     FP_UI_PORT="$2"; shift 2 ;;
        -y|--yes)      FP_ASSUME_YES=1; shift ;;
        --debug)       FP_DEBUG=1; shift ;;
        -h|--help)     print_help; exit 0 ;;
        *)             die "unknown argument: $1 (try --help)" ;;
    esac
done

export FP_ASSUME_YES="${FP_ASSUME_YES:-0}"
export FP_DEBUG="${FP_DEBUG:-0}"

require_not_root

cat >&2 <<EOF
${FP_C_BOLD}${FP_C_CYAN}
╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar — macOS Installer                 ║
╚═══════════════════════════════════════════════════════════════╝
${FP_C_RESET}
EOF

# ── Legal acknowledgement (must come before any system change) ──────────────
prompt_legal_acknowledgement

# ── Step 1: Pre-flight ──────────────────────────────────────────────────────
log_step "step 1/6 — pre-flight checks"
check_supported_os
check_arch
check_ram
check_disk "$HOME"
check_ports "$FP_REST_PORT" "$FP_WS_PORT" "$FP_PUBSUB_PORT" "$FP_GATEWAY_PORT" "$FP_UI_PORT"

# ── Step 2: Detect container runtime ────────────────────────────────────────
log_step "step 2/6 — container runtime"

detect_mac_runtime() {
    # Echo the runtime name and return 0 if found, else return 1.

    if ! command -v docker >/dev/null 2>&1; then
        log_info "docker CLI not found in PATH" >&2
        # Skip the daemon probe entirely — fall through to the
        # what-is-installed report below.
        :
    else
        log_info "probing docker daemon (docker info, may take a few seconds)..." >&2

        # `docker info` will hang for ~30s talking to /var/run/docker.sock
        # if no daemon is listening. Wrap it in a 5s timeout when GNU
        # `timeout` (or BSD `gtimeout` from coreutils) is available so a
        # dead socket doesn't stall the installer. If neither is present,
        # fall back to the unbounded call.
        local docker_ok=1
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 docker info >/dev/null 2>&1 || docker_ok=0
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 5 docker info >/dev/null 2>&1 || docker_ok=0
        else
            docker info >/dev/null 2>&1 || docker_ok=0
        fi

        if [ "$docker_ok" = "1" ]; then
            local ctx
            ctx="$(docker context show 2>/dev/null || echo default)"
            case "$ctx" in
                colima*)         echo "Colima";          return 0 ;;
                desktop-linux)   echo "Docker Desktop";  return 0 ;;
                rancher-desktop) echo "Rancher Desktop"; return 0 ;;
                orbstack)        echo "OrbStack";        return 0 ;;
                *)               echo "Docker (${ctx})"; return 0 ;;
            esac
        fi
    fi

    # Daemon not reachable — try to identify what's installed even so, so
    # the user gets a "start X" message instead of a generic "install one".
    if [ -d "/Applications/OrbStack.app" ]; then
        echo "OrbStack (not running)"; return 1
    fi
    if [ -d "/Applications/Docker.app" ]; then
        echo "Docker Desktop (not running)"; return 1
    fi
    if [ -d "/Applications/Rancher Desktop.app" ]; then
        echo "Rancher Desktop (not running)"; return 1
    fi
    if command -v colima >/dev/null 2>&1; then
        echo "Colima (not running)"; return 1
    fi
    return 2
}

if runtime="$(detect_mac_runtime)"; then
    log_success "container runtime detected: ${runtime}"
else
    rc=$?
    if [ "$rc" = "1" ]; then
        log_error "${runtime} is installed but not running"
        log_error "start it from your Applications folder (or 'colima start') and re-run this installer"
    else
        log_error "no container runtime found. Install one of:"
        log_error "  - Colima:          brew install colima docker docker-compose"
        log_error "  - Docker Desktop:  https://www.docker.com/products/docker-desktop/"
        log_error "  - Rancher Desktop: https://rancherdesktop.io/"
        log_error "  - OrbStack:        https://orbstack.dev/"
    fi
    die "container runtime is required"
fi

check_compose_v2 || die "docker compose v2 plugin not available — your runtime is too old or misconfigured"

# ── Existing installation detection + Upgrade/Reinstall/Fresh choice ──
log_step "checking for existing installation"
fp_detect_existing_install "$FP_HOME"
if fp_has_existing_install; then
    fp_prompt_existing_action "$FP_HOME"

    # Admin authentication gate — upgrades and reinstalls can overwrite a
    # running production stack, so require the existing admin's password
    # first. FP_FORCE=1 in the parent env skips this for automation.
    #
    # Preconditions for the gate to fire:
    #   * Action is upgrade or reinstall
    #   * compose.yml actually exists (so there's a real stack to auth
    #     against — otherwise this is effectively a fresh install with a
    #     pre-created home dir, and there's no Core to verify the password)
    #   * auth.sh is available
    #
    # Two modes:
    #   * Non-interactive (GUI installer or CI passed FP_ADMIN_PASS):
    #     verify once against Core REST API. FP_ADMIN_USER defaults to
    #     "admin" if unset.
    #   * Interactive (plain `bash install.sh`): prompt for admin password,
    #     3 attempts.
    # Both paths treat Core-unreachable as "fall back to YES confirmation"
    # (or automatic pass when --yes / FP_ASSUME_YES=1).
    if [ "${FP_FORCE:-0}" != "1" ] && \
       { [ "${FP_INSTALL_ACTION:-}" = "upgrade" ] || [ "${FP_INSTALL_ACTION:-}" = "reinstall" ]; } && \
       [ -f "${FP_HOME}/compose.yml" ] && \
       [ -f "${REPO_ROOT}/shared/lib/auth.sh" ]; then
        log_step "authorizing ${FP_INSTALL_ACTION}"
        # shellcheck source=../shared/lib/auth.sh
        . "${REPO_ROOT}/shared/lib/auth.sh"
        auth_rc=0
        if [ -n "${FP_ADMIN_PASS:-}" ]; then
            fp_verify_admin_credentials "${FP_ADMIN_USER:-admin}" "$FP_ADMIN_PASS" || auth_rc=$?
        else
            fp_authenticate_admin 3 || auth_rc=$?
        fi
        case "$auth_rc" in
            0) ;;  # authenticated
            2)
                # Core unreachable — can't verify. Accept an explicit YES.
                if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
                    log_warn "Core unreachable — proceeding because --yes (or FP_ASSUME_YES=1) was supplied."
                else
                    printf '\nFalconPulsar Core is not running, so the admin password cannot be verified.\n' >&2
                    printf 'To authorize this %s anyway, type exactly YES (uppercase): ' "${FP_INSTALL_ACTION}" >&2
                    confirm=''
                    read -r confirm </dev/tty 2>/dev/null || confirm=''
                    if [ "$confirm" != 'YES' ]; then
                        die "confirmation not received — aborting ${FP_INSTALL_ACTION}"
                    fi
                fi
                ;;
            *) die "admin authentication failed — aborting ${FP_INSTALL_ACTION}" ;;
        esac
    fi

    fp_apply_existing_action "$FP_HOME"

    # Refresh uninstall.sh + auth.sh BEFORE the fast-path. Otherwise every
    # upgrade keeps the user's old (potentially broken) uninstaller on disk.
    if [ -f "${SCRIPT_DIR}/uninstall.sh" ] && [ -d "${FP_HOME}" ]; then
        cp "${SCRIPT_DIR}/uninstall.sh" "${FP_HOME}/uninstall.sh" 2>/dev/null || true
        chmod +x "${FP_HOME}/uninstall.sh" 2>/dev/null || true
        if [ -f "${REPO_ROOT}/shared/lib/auth.sh" ]; then
            cp "${REPO_ROOT}/shared/lib/auth.sh" "${FP_HOME}/auth.sh" 2>/dev/null || true
        fi
    fi

    # Fast-path: if the user picked Upgrade and the stack dir is intact,
    # skip everything else and just pull+recreate.
    if fp_try_upgrade_fastpath "$FP_HOME"; then
        log_success "Upgrade complete."
        fp_install_cli "$FP_HOME" "${FP_VERSION:-0.1.0}"
        exit 0
    fi
else
    log_info "no existing install detected — proceeding with fresh install"
fi

# Verify we can pull images from the configured registry. If the registry
# requires authentication, fp_registry_ensure_access prompts the user for
# credentials (or a different registry) and runs `docker login`.
fp_registry_ensure_access

# ── Step 3: Stack directory ─────────────────────────────────────────────────
log_step "step 3/6 — stack directory"
mkdir -p "$FP_HOME" "$FP_DATA_DIR" "$FP_GATEWAY_DATA_DIR"
log_success "${FP_HOME} ready"

# ── Step 4: compose.yml + .env ──────────────────────────────────────────────
log_step "step 4/6 — stack files"

prompt_ai_gateway
prompt_admin_credentials

cp "${REPO_ROOT}/shared/compose.yml" "${FP_HOME}/compose.yml"
cp "${REPO_ROOT}/shared/nginx.conf" "${FP_HOME}/nginx.conf"

# Copy the AI Gateway config if it doesn't already exist (skip if gateway disabled)
if [ "${FP_AI_GATEWAY_ENABLED}" = "true" ]; then
    if [ ! -f "${FP_HOME}/gateway.yaml" ] && [ -f "${REPO_ROOT}/shared/gateway.yaml" ]; then
        cp "${REPO_ROOT}/shared/gateway.yaml" "${FP_HOME}/gateway.yaml"
        log_info "copied default gateway.yaml"
    fi
fi

# On macOS, FP_UID = the current user's UID. The compose.yml uses this to set
# the container's process UID so bind-mounted files are owned correctly on
# the host side.
FP_UID="$(id -u)"
FP_GID="$(id -g)"

# .env — note that the admin password is INTENTIONALLY not stored here.
# It is held in shell memory and passed via the parent environment to
# `docker compose up -d core` for the first-run init only. After that
# the FP_API_KEY (AI gateway service token) is the only secret in here,
# and bootstrap.sh appends it after the API comes up.
umask 077
cat >"${FP_HOME}/.env" <<EOF
# Generated by FalconPulsar installer on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do NOT commit this file anywhere.
#
# The admin password is intentionally NOT stored here. It was used once,
# in shell memory only, to bootstrap the admin user during first-run init.
# It is now hashed inside the database and never exits the core process.
FP_ADMIN_USER=${FP_ADMIN_USER}
FP_DATA_DIR=${FP_DATA_DIR}
FP_GATEWAY_DATA_DIR=${FP_GATEWAY_DATA_DIR}
FP_UID=${FP_UID}
FP_GID=${FP_GID}
FP_REGISTRY=${FP_REGISTRY}
FP_VERSION=${FP_VERSION}
FP_REST_PORT=${FP_REST_PORT}
FP_WS_PORT=${FP_WS_PORT}
FP_PUBSUB_PORT=${FP_PUBSUB_PORT}
FP_GATEWAY_PORT=${FP_GATEWAY_PORT}
FP_UI_PORT=${FP_UI_PORT}
FP_LOG_LEVEL=${FP_LOG_LEVEL}
FP_AI_GATEWAY_ENABLED=${FP_AI_GATEWAY_ENABLED:-false}
EOF
chmod 0600 "${FP_HOME}/.env"
umask 022

# Copy uninstall script to the stack directory for easy access.
# auth.sh ships alongside so the uninstaller can require admin credentials
# even when run standalone (not from the installer repo).
if [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then
    cp "${SCRIPT_DIR}/uninstall.sh" "${FP_HOME}/uninstall.sh"
    chmod +x "${FP_HOME}/uninstall.sh"
    if [ -f "${REPO_ROOT}/shared/lib/auth.sh" ]; then
        cp "${REPO_ROOT}/shared/lib/auth.sh" "${FP_HOME}/auth.sh"
    fi
fi

log_success "wrote ${FP_HOME}/compose.yml and ${FP_HOME}/.env (admin password NOT stored)"

# ── Step 5: Pull, start core, bootstrap token, start the rest ──────────────
log_step "step 5/6 — pulling images and starting stack"
fp_compose_pull_with_retry "$FP_HOME"

# 5a. Start core only with FP_ADMIN_PASS injected from this shell.
# We do NOT write FP_ADMIN_PASS to .env. compose.yml has `${FP_ADMIN_PASS:-}`
# so the value comes from whatever env we set here. After first-run init
# the password is hashed in the database and never needed again.
log_info "starting core (first-run init may take 60-90s)"
( cd "$FP_HOME" && FP_ADMIN_PASS="${FP_ADMIN_PASS}" docker compose up -d core )

log_info "waiting for core to become healthy"
deadline=$(( $(date +%s) + 180 ))
while :; do
    health=$(docker inspect -f '{{.State.Health.Status}}' falconpulsar-core 2>/dev/null || echo unknown)
    case "$health" in
        healthy) log_success "core is healthy"; break ;;
        unhealthy) die "core became unhealthy. Check: docker logs falconpulsar-core" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
        die "timed out waiting for core healthcheck. Check: docker logs falconpulsar-core"
    fi
    sleep 3
done

# 5b. Create the AI gateway service token via REST API (skip if gateway disabled).
if [ "${FP_AI_GATEWAY_ENABLED}" = "true" ]; then
    fp_bootstrap_gateway_token "${FP_HOME}/.env"
else
    log_info "AI Gateway disabled — skipping token bootstrap"
fi

# 5c. Start the rest of the stack.
if [ "${FP_AI_GATEWAY_ENABLED}" = "true" ]; then
    log_info "starting ui and ai-gateway"
    ( cd "$FP_HOME" && docker compose --profile ai up -d )
    # Wipe the gateway's self-seeded provider/model catalog so the user
    # lands on a clean AI configuration page. See bootstrap.sh for the
    # full rationale + the upstream fix this stops being necessary after.
    fp_wipe_gateway_seed_defaults
else
    log_info "starting ui (AI Gateway disabled)"
    ( cd "$FP_HOME" && docker compose up -d )
fi

# 5d. Install the fp CLI into ${FP_HOME}/bin/ and optionally add to PATH.
fp_install_cli "$FP_HOME" "${FP_VERSION:-0.1.0}"
fp_offer_path_append "$FP_HOME"

# ── Step 6: Done ────────────────────────────────────────────────────────────
log_step "verifying installation health"
HEALTH_OK=true
HEALTH_SVCS="falconpulsar-core falconpulsar-ui"
[ "${FP_AI_GATEWAY_ENABLED}" = "true" ] && HEALTH_SVCS="${HEALTH_SVCS} falconpulsar-ai-gateway"
for svc in $HEALTH_SVCS; do
    if docker ps --filter "name=$svc" --filter "status=running" -q 2>/dev/null | grep -q .; then
        log_success "$svc: running"
    else
        log_warn "$svc: not running yet (may still be starting)"
        HEALTH_OK=false
    fi
done

if curl -sf "http://localhost:${FP_REST_PORT}/api/v1/health" >/dev/null 2>&1; then
    log_success "REST API: responding on port ${FP_REST_PORT}"
else
    log_warn "REST API: not responding yet (core may still be initializing)"
fi

if [ "$HEALTH_OK" = "false" ]; then
    log_warn "some containers are still starting — they may need a few more seconds"
fi

log_step "all done"

cat >&2 <<EOF

${FP_C_GREEN}${FP_C_BOLD}╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar is up and running                 ║
╚═══════════════════════════════════════════════════════════════╝${FP_C_RESET}

  Web UI:    ${FP_C_CYAN}http://localhost:${FP_UI_PORT}${FP_C_RESET}
  REST API:  ${FP_C_CYAN}http://localhost:${FP_REST_PORT}${FP_C_RESET}
  WebSocket: ${FP_C_CYAN}ws://localhost:${FP_WS_PORT}${FP_C_RESET}

  Username:  ${FP_C_BOLD}${FP_ADMIN_USER}${FP_C_RESET}
  Password:  ${FP_C_BOLD}${FP_C_YELLOW}the one you saved earlier${FP_C_RESET}
             ${FP_C_DIM}(it is NOT stored anywhere on disk —${FP_C_RESET}
             ${FP_C_DIM} the installer used it once for first-run init)${FP_C_RESET}

  Stack dir: ${FP_HOME}
  Data dir:  ${FP_DATA_DIR}

  Manage with the fp CLI (installed at ${FP_HOME}/bin/fp):
    fp                          # interactive console (TUI)
    fp status                   # stack status
    fp start | stop | restart   # control the stack
    fp logs [service]           # tail logs
    fp config export <file>     # admin-only encrypted backup
    fp config import <file>     # admin-only restore

  Or use docker compose directly:
    cd ${FP_HOME}
    docker compose ps | logs -f | restart | down

  The stack will auto-restart whenever your container runtime starts
  (because of \`restart: unless-stopped\` in compose.yml). To disable
  auto-restart, run \`docker compose down\`.

  To uninstall: bash ${SCRIPT_DIR}/uninstall.sh

EOF
