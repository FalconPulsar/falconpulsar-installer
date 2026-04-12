#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — Linux Installer
# =============================================================================
#
# End-to-end Linux installer for FalconPulsar. From a fresh box (Ubuntu,
# Debian, RHEL/Rocky/Alma, Fedora, openSUSE Leap) to a running stack in one
# command.
#
# What this script does (in order):
#
#   1. Pre-flight: OS, arch, RAM, disk, ports, kernel
#   2. Install Docker Engine if missing (via https://get.docker.com)
#   3. Create the falconpulsar system user + home directory
#   4. Add falconpulsar to the docker group
#   5. Generate compose.yml + .env in /home/falconpulsar/
#   6. Pull images and start the stack as the falconpulsar user
#   7. Optionally register a systemd unit for lifecycle management
#   8. Wait for the core healthcheck and print connection details
#
# Two install modes (chosen interactively or via --mode):
#
#   docker   — pure docker compose, no system service. The user has to run
#              `docker compose up -d` manually after a reboot. Simplest.
#
#   systemd  — installs a systemd user unit (with `loginctl enable-linger`)
#              so the stack starts at boot and can be managed with
#              `systemctl --user start/stop/restart falconpulsar`.
#
# Usage:
#
#   sudo bash install.sh                       # interactive
#   sudo bash install.sh --mode systemd        # non-interactive mode pick
#   sudo FP_ADMIN_PASS=hunter2 bash install.sh --mode docker --yes
#
# Re-running this script is safe: it detects existing installs and offers to
# upgrade in-place (re-pulls images, restarts services).
#
# Uninstall: sudo bash uninstall.sh
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

# Resolve script directory (works whether invoked directly or via curl|sh)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
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

trap 'on_error $LINENO' ERR

# ── Defaults ────────────────────────────────────────────────────────────────
FP_USER="${FP_USER:-falconpulsar}"
FP_HOME="${FP_HOME:-/home/${FP_USER}}"
FP_DATA_DIR="${FP_DATA_DIR:-${FP_HOME}/data}"
FP_INSTALL_MODE="${FP_INSTALL_MODE:-}"        # docker | systemd
FP_REST_PORT="${FP_REST_PORT:-7433}"
FP_WS_PORT="${FP_WS_PORT:-7434}"
FP_PUBSUB_PORT="${FP_PUBSUB_PORT:-7435}"
FP_GATEWAY_PORT="${FP_GATEWAY_PORT:-7436}"
FP_UI_PORT="${FP_UI_PORT:-8080}"
FP_LOG_LEVEL="${FP_LOG_LEVEL:-info}"

# ── Argument parsing ────────────────────────────────────────────────────────
print_help() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --mode <docker|systemd>   Install mode (default: ask interactively)
  --user <name>             System user to create (default: falconpulsar)
  --data-dir <path>         Database directory (default: ~falconpulsar/data)
  --rest-port <n>           REST API port (default: 7433)
  --ui-port <n>             Web UI port (default: 8080)
  --yes, -y                 Assume yes to all prompts (FP_ASSUME_YES=1)
  --debug                   Verbose debug output
  --help, -h                This help

Environment variables override defaults. See REQUIREMENTS.md for prerequisites.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)        FP_INSTALL_MODE="$2"; shift 2 ;;
        --user)        FP_USER="$2"; FP_HOME="/home/${FP_USER}"; shift 2 ;;
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

# ── Banner ──────────────────────────────────────────────────────────────────
cat >&2 <<EOF
${FP_C_BOLD}${FP_C_CYAN}
╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar — Linux Installer                 ║
╚═══════════════════════════════════════════════════════════════╝
${FP_C_RESET}
EOF

require_root

# ── Legal acknowledgement (must come before any system change) ──────────────
prompt_legal_acknowledgement

# ── Step 1: Pre-flight checks ───────────────────────────────────────────────
log_step "step 1/8 — pre-flight checks"
check_supported_os
check_arch
check_kernel
check_ram
check_disk "$(dirname "$FP_HOME")"
check_ports "$FP_REST_PORT" "$FP_WS_PORT" "$FP_PUBSUB_PORT" "$FP_GATEWAY_PORT" "$FP_UI_PORT"

# ── Step 2: Install Docker if missing ───────────────────────────────────────
log_step "step 2/8 — Docker Engine"
if check_docker_installed && check_compose_v2; then
    log_success "Docker Engine + compose v2 already installed"
else
    if ! confirm "Docker Engine is not installed. Install it now via get.docker.com?" default-yes; then
        die "Docker is required. Aborting."
    fi
    install_docker_linux
    check_compose_v2 || die "Docker installed but compose v2 plugin is missing"
fi

if ! check_docker_daemon; then
    log_info "starting Docker daemon"
    systemctl enable --now docker || die "failed to start Docker daemon"
fi

# Verify we can pull images from the configured registry. If the registry
# requires authentication, fp_registry_ensure_access prompts the user for
# credentials (or a different registry) and runs `docker login`. Whatever
# configuration ends up in root's ~/.docker/config.json here is copied into
# the falconpulsar user's home in step 6 so the unprivileged user can pull.
fp_registry_ensure_access

# ── Step 3: Create the falconpulsar user ────────────────────────────────────
# Handles all re-install scenarios defensively:
#   - User exists, home dir exists: nothing to do
#   - User exists, home dir missing: recreate the directory
#   - User missing, home dir exists: create user with existing home
#   - User missing, home dir missing: create user + home (fresh install)
#   - Home dir exists but wrong ownership: fix it
#   - Data dir missing: create it
#   - .docker dir missing: create it (for credential copy in step 6)
log_step "step 3/8 — system user '${FP_USER}'"
if id "$FP_USER" >/dev/null 2>&1; then
    log_success "user ${FP_USER} already exists"
else
    useradd \
        --system \
        --create-home \
        --home-dir "$FP_HOME" \
        --shell /bin/bash \
        --comment "FalconPulsar service account" \
        "$FP_USER"
    log_success "created ${FP_USER} (home: ${FP_HOME})"
fi

# Ensure all required directories exist with correct ownership.
# A previous uninstall may have deleted some but not all.
for dir in "$FP_HOME" "$FP_DATA_DIR" "${FP_HOME}/.docker"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_info "created missing directory: ${dir}"
    fi
done
chown -R "${FP_USER}:${FP_USER}" "$FP_HOME"
chmod 0750 "$FP_DATA_DIR"
chmod 0700 "${FP_HOME}/.docker"
log_success "home directory ready: ${FP_HOME}"

FP_UID="$(id -u "$FP_USER")"
FP_GID="$(id -g "$FP_USER")"
export FP_UID FP_GID

# Stop any stale containers from a previous install before proceeding.
# This prevents port conflicts and ensures a clean state.
if run_as_user "$FP_USER" docker compose -f "${FP_HOME}/compose.yml" ps -q 2>/dev/null | grep -q .; then
    log_info "stopping stale containers from previous install..."
    run_as_user "$FP_USER" docker compose -f "${FP_HOME}/compose.yml" down --remove-orphans 2>/dev/null || true
    log_info "stale containers stopped"
fi

# ── Step 4: Docker group membership ─────────────────────────────────────────
log_step "step 4/8 — docker group"
add_user_to_docker_group "$FP_USER"

# ── Step 5: Install mode selection ──────────────────────────────────────────
log_step "step 5/8 — install mode"
if [ -z "$FP_INSTALL_MODE" ]; then
    cat >&2 <<EOF

Choose how FalconPulsar should be managed:

  ${FP_C_BOLD}1) docker${FP_C_RESET}    Pure docker-compose. Manage with:
                  cd ${FP_HOME} && docker compose up -d / down
              You restart the stack manually after a reboot.

  ${FP_C_BOLD}2) systemd${FP_C_RESET}   Register a systemd user unit so the stack
              starts at boot and can be managed with:
                  systemctl --user start/stop/status falconpulsar

EOF
    while :; do
        printf '%schoose [1/2]:%s ' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        read -r choice || choice=''
        case "$choice" in
            1) FP_INSTALL_MODE=docker;  break ;;
            2) FP_INSTALL_MODE=systemd; break ;;
            *) log_warn "please answer 1 or 2" ;;
        esac
    done
fi

case "$FP_INSTALL_MODE" in
    docker)  log_info "install mode: docker" ;;
    systemd) check_systemd; log_info "install mode: systemd" ;;
    *)       die "invalid install mode: ${FP_INSTALL_MODE} (must be 'docker' or 'systemd')" ;;
esac

# ── Step 6: Generate compose.yml + .env + (optional) init.json ──────────────
log_step "step 6/8 — stack files in ${FP_HOME}"

prompt_admin_credentials

install -m 0644 -o "$FP_USER" -g "$FP_USER" \
    "${REPO_ROOT}/shared/compose.yml" \
    "${FP_HOME}/compose.yml"

install -d -m 0750 -o "$FP_USER" -g "$FP_USER" "$FP_DATA_DIR"

# Copy root's Docker Hub credentials into the falconpulsar user's home so
# `sg docker -c 'docker compose pull'` (which runs as falconpulsar) can pull
# the private images. Pre-release only — once images are public this can go.
ROOT_DOCKER_CFG="${DOCKER_CONFIG:-/root/.docker}/config.json"
if [ -f "$ROOT_DOCKER_CFG" ]; then
    install -d -m 0700 -o "$FP_USER" -g "$FP_USER" "${FP_HOME}/.docker"
    install -m 0600 -o "$FP_USER" -g "$FP_USER" \
        "$ROOT_DOCKER_CFG" "${FP_HOME}/.docker/config.json"
    log_success "Docker Hub credentials propagated to ${FP_HOME}/.docker"
fi

# .env — note 0600 perms even though there is NO password in here.
# The admin password is held only in shell memory and passed via the
# parent environment to `docker compose up -d core` for the first-run
# init. After that, FP_API_KEY (the AI gateway service token) is the
# only secret in this file, and the installer appends it via
# bootstrap.sh after the API comes up.
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
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
XAI_API_KEY=${XAI_API_KEY:-}
EOF
chown "${FP_USER}:${FP_USER}" "${FP_HOME}/.env"
chmod 0600 "${FP_HOME}/.env"
umask 022

log_success "wrote ${FP_HOME}/compose.yml and ${FP_HOME}/.env (admin password NOT stored)"

# ── Step 7: Pull, start core, bootstrap token, start the rest ──────────────
log_step "step 7/8 — pulling images and starting stack"

# We use sg here because the falconpulsar user was just added to the docker
# group in this same session and the new GID isn't in their existing process
# table yet. `sg docker -c ...` gives us a fresh group context immediately.
sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose pull"

# ── 7a. Start core only with FP_ADMIN_PASS injected from this shell ────────
# We deliberately do NOT write FP_ADMIN_PASS to .env. Instead we pass it
# via the per-call environment. compose.yml has `${FP_ADMIN_PASS:-}` so
# the value comes from whatever env we set here. Once first-run init
# completes, the password is hashed in the database and we never need
# the plaintext again.
#
# We escape any single quotes in the password (replace ' with '\'') so
# arbitrary user-supplied passwords don't break the inner shell parsing
# of `sg docker -c "..."`. Auto-generated passwords are alphanumeric and
# don't need this, but a user-supplied one might.
log_info "starting core (first-run init may take 60-90s)"
FP_ADMIN_PASS_ESC="${FP_ADMIN_PASS//\'/\'\\\'\'}"
sudo -u "$FP_USER" -H sg docker -c \
    "cd '${FP_HOME}' && FP_ADMIN_PASS='${FP_ADMIN_PASS_ESC}' docker compose up -d core"
unset FP_ADMIN_PASS_ESC

# Wait for core healthcheck — up to 3 minutes for first-run init.
log_info "waiting for core to become healthy"
deadline=$(( $(date +%s) + 180 ))
while :; do
    health=$(sudo -u "$FP_USER" -H sg docker -c "docker inspect -f '{{.State.Health.Status}}' falconpulsar-core 2>/dev/null" || echo unknown)
    case "$health" in
        healthy) log_success "core is healthy"; break ;;
        unhealthy) die "core became unhealthy. Check: docker logs falconpulsar-core" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
        die "timed out waiting for core healthcheck. Check: docker logs falconpulsar-core"
    fi
    sleep 3
done

# ── 7b. Create the AI gateway service token via REST API ──────────────────
# This appends FP_API_KEY=<token> to .env. The admin password is consumed
# by the login call here and then we drop it from our shell variables.
fp_bootstrap_gateway_token "${FP_HOME}/.env"

# ── 7c. Start the rest of the stack (ui + ai-gateway) ─────────────────────
# At this point .env contains FP_API_KEY but NOT FP_ADMIN_PASS. The
# ai-gateway will pick up the token from .env on startup.
log_info "starting ui and ai-gateway"
sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose up -d"

# ── Step 8: systemd registration (optional) ─────────────────────────────────
log_step "step 8/8 — lifecycle registration"
if [ "$FP_INSTALL_MODE" = "systemd" ]; then
    UNIT_DIR="${FP_HOME}/.config/systemd/user"
    install -d -m 0755 -o "$FP_USER" -g "$FP_USER" "$UNIT_DIR"

    sed -e "s|@@FP_HOME@@|${FP_HOME}|g" \
        "${SCRIPT_DIR}/systemd/falconpulsar.service.template" \
        > "${UNIT_DIR}/falconpulsar.service"
    chown "${FP_USER}:${FP_USER}" "${UNIT_DIR}/falconpulsar.service"

    # Enable lingering so the user unit survives logout / starts at boot.
    loginctl enable-linger "$FP_USER"

    sudo -u "$FP_USER" -H XDG_RUNTIME_DIR="/run/user/${FP_UID}" \
        systemctl --user daemon-reload
    sudo -u "$FP_USER" -H XDG_RUNTIME_DIR="/run/user/${FP_UID}" \
        systemctl --user enable falconpulsar.service

    log_success "systemd user unit installed and enabled"
    log_info "manage with: sudo -u ${FP_USER} XDG_RUNTIME_DIR=/run/user/${FP_UID} systemctl --user <cmd> falconpulsar"
else
    log_info "no systemd unit installed (mode: docker)"
    log_info "to start/stop manually: sudo -u ${FP_USER} -H sg docker -c 'cd ${FP_HOME} && docker compose <up -d|down>'"
fi

# ── Done ────────────────────────────────────────────────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$HOST_IP" ] && HOST_IP="localhost"

cat >&2 <<EOF

${FP_C_GREEN}${FP_C_BOLD}╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar is up and running                 ║
╚═══════════════════════════════════════════════════════════════╝${FP_C_RESET}

  Web UI:    ${FP_C_CYAN}http://${HOST_IP}:${FP_UI_PORT}${FP_C_RESET}
  REST API:  ${FP_C_CYAN}http://${HOST_IP}:${FP_REST_PORT}${FP_C_RESET}
  WebSocket: ${FP_C_CYAN}ws://${HOST_IP}:${FP_WS_PORT}${FP_C_RESET}

  Username:  ${FP_C_BOLD}${FP_ADMIN_USER}${FP_C_RESET}
  Password:  ${FP_C_BOLD}${FP_C_YELLOW}the one you saved earlier${FP_C_RESET}
             ${FP_C_DIM}(it is NOT stored anywhere on disk —${FP_C_RESET}
             ${FP_C_DIM} the installer used it once for first-run init)${FP_C_RESET}

  Data dir:  ${FP_DATA_DIR}
  Stack dir: ${FP_HOME}

  To uninstall: sudo bash ${SCRIPT_DIR}/uninstall.sh

EOF
