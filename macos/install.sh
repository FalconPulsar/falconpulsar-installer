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

trap 'on_error $LINENO' ERR

# ── Defaults ────────────────────────────────────────────────────────────────
FP_HOME="${FP_HOME:-${HOME}/falconpulsar}"
FP_DATA_DIR="${FP_DATA_DIR:-${FP_HOME}/data}"
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

# Pre-release: images are private. Verify Docker Hub login before we go any
# further so the user doesn't get a "pull access denied" failure at step 5.
check_dockerhub_login

# ── Step 3: Stack directory ─────────────────────────────────────────────────
log_step "step 3/6 — stack directory"
mkdir -p "$FP_HOME" "$FP_DATA_DIR"
log_success "${FP_HOME} ready"

# ── Step 4: compose.yml + .env ──────────────────────────────────────────────
log_step "step 4/6 — stack files"

prompt_admin_credentials

cp "${REPO_ROOT}/shared/compose.yml" "${FP_HOME}/compose.yml"

# On macOS, FP_UID = the current user's UID. The compose.yml uses this to set
# the container's process UID so bind-mounted files are owned correctly on
# the host side.
FP_UID="$(id -u)"
FP_GID="$(id -g)"

umask 077
cat >"${FP_HOME}/.env" <<EOF
# Generated by FalconPulsar installer on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do NOT commit this file anywhere.
FP_ADMIN_USER=${FP_ADMIN_USER}
FP_ADMIN_PASS=${FP_ADMIN_PASS}
FP_DATA_DIR=${FP_DATA_DIR}
FP_UID=${FP_UID}
FP_GID=${FP_GID}
FP_REST_PORT=${FP_REST_PORT}
FP_WS_PORT=${FP_WS_PORT}
FP_PUBSUB_PORT=${FP_PUBSUB_PORT}
FP_GATEWAY_PORT=${FP_GATEWAY_PORT}
FP_UI_PORT=${FP_UI_PORT}
FP_LOG_LEVEL=${FP_LOG_LEVEL}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
XAI_API_KEY=${XAI_API_KEY:-}
EOF
chmod 0600 "${FP_HOME}/.env"
umask 022

log_success "wrote ${FP_HOME}/compose.yml and ${FP_HOME}/.env"

# ── Step 5: Pull and start ──────────────────────────────────────────────────
log_step "step 5/6 — pulling images and starting stack"
( cd "$FP_HOME" && docker compose pull )
( cd "$FP_HOME" && docker compose up -d )

log_info "waiting for core to become healthy (this may take up to 90s on first run)"
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

# ── Step 6: Done ────────────────────────────────────────────────────────────
log_step "step 6/6 — all done"

cat >&2 <<EOF

${FP_C_GREEN}${FP_C_BOLD}╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar is up and running                 ║
╚═══════════════════════════════════════════════════════════════╝${FP_C_RESET}

  Web UI:    ${FP_C_CYAN}http://localhost:${FP_UI_PORT}${FP_C_RESET}
  REST API:  ${FP_C_CYAN}http://localhost:${FP_REST_PORT}${FP_C_RESET}
  WebSocket: ${FP_C_CYAN}ws://localhost:${FP_WS_PORT}${FP_C_RESET}

  Username:  ${FP_C_BOLD}${FP_ADMIN_USER}${FP_C_RESET}
  Password:  (the one you saved earlier — stored in ${FP_HOME}/.env, mode 0600)

  Stack dir: ${FP_HOME}
  Data dir:  ${FP_DATA_DIR}

  Manage with:
    cd ${FP_HOME}
    docker compose ps           # status
    docker compose logs -f core # follow logs
    docker compose restart      # restart the stack
    docker compose down         # stop the stack

  The stack will auto-restart whenever your container runtime starts
  (because of \`restart: unless-stopped\` in compose.yml). To disable
  auto-restart, run \`docker compose down\`.

  To uninstall: bash ${SCRIPT_DIR}/uninstall.sh

EOF
