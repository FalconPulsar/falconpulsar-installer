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
# shellcheck source=../shared/lib/fpcli.sh
. "${REPO_ROOT}/shared/lib/fpcli.sh"
# shellcheck source=../shared/lib/existing.sh
. "${REPO_ROOT}/shared/lib/existing.sh"

trap 'on_error $LINENO' ERR

# ── Defaults ────────────────────────────────────────────────────────────────
# Install model (set by arg-parsing / WSL detection below):
#   service-user   Native Linux. Dedicated `falconpulsar` system user owns
#                  the stack at /home/falconpulsar. Install + uninstall both
#                  require root (useradd/userdel, docker group, etc.).
#   per-user       WSL + future per-user Linux. The invoking human owns the
#                  stack at /home/<user>/falconpulsar. Install still needs
#                  root to add the user to the docker group and drop a
#                  profile.d snippet, but uninstall is entirely user-owned.
FP_INSTALL_MODEL="${FP_INSTALL_MODEL:-}"

# Compute the default FP_USER + FP_HOME from the install model. If the caller
# didn't pre-set anything, WSL -> per-user (using the invoking human), native
# Linux -> service-user (falconpulsar:/home/falconpulsar). Explicit FP_USER or
# --user overrides this below.
if [ -z "${FP_USER:-}" ] && [ -z "${FP_HOME:-}" ]; then
    if is_wsl; then
        FP_INSTALL_MODEL="per-user"
        # The invoking human is passed in from the PowerShell side via
        # FP_INVOKING_USER. If that's missing we fall back to $SUDO_USER, then
        # to the first real user at UID 1000. As a last resort we give up and
        # ask for --user explicitly -- installing as root with no human owner
        # would just recreate the problem we're trying to fix.
        _fp_default_user="${FP_INVOKING_USER:-${SUDO_USER:-}}"
        if [ -z "$_fp_default_user" ] || [ "$_fp_default_user" = "root" ]; then
            _fp_default_user="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
        fi
        FP_USER="${_fp_default_user:-}"
        if [ -n "$FP_USER" ]; then
            FP_HOME="/home/${FP_USER}/falconpulsar"
        fi
    else
        FP_INSTALL_MODEL="service-user"
        FP_USER="falconpulsar"
        FP_HOME="/home/${FP_USER}"
    fi
else
    # Caller pre-set FP_USER and/or FP_HOME. Infer model from FP_USER:
    # if it's the real falconpulsar system user we treat as service-user.
    FP_USER="${FP_USER:-falconpulsar}"
    if [ "$FP_USER" = "falconpulsar" ] && [ -z "${FP_HOME:-}" ]; then
        FP_INSTALL_MODEL="${FP_INSTALL_MODEL:-service-user}"
        FP_HOME="/home/${FP_USER}"
    else
        # Non-default user -> per-user install under that user's home.
        FP_INSTALL_MODEL="${FP_INSTALL_MODEL:-per-user}"
        FP_HOME="${FP_HOME:-/home/${FP_USER}/falconpulsar}"
    fi
fi
FP_DATA_DIR="${FP_DATA_DIR:-${FP_HOME}/data}"
FP_GATEWAY_DATA_DIR="${FP_GATEWAY_DATA_DIR:-${FP_HOME}/ai-gateway-data}"
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
  --user <name>             User who will own the stack.
                              Native Linux default: falconpulsar (system user).
                              WSL default: the invoking human user (no
                              system user is created; stack lives in that
                              user's home directory).
  --home <path>             Override the stack directory.
                              Defaults:
                                service-user: /home/falconpulsar
                                per-user:     /home/<user>/falconpulsar
  --data-dir <path>         Database directory (default: <home>/data)
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
        --user)
            FP_USER="$2"
            # Keep whichever model was picked above. Only re-derive FP_HOME
            # if it wasn't explicitly set by the caller.
            if [ -z "${FP_HOME_EXPLICIT:-}" ]; then
                if [ "$FP_INSTALL_MODEL" = "per-user" ]; then
                    FP_HOME="/home/${FP_USER}/falconpulsar"
                else
                    FP_HOME="/home/${FP_USER}"
                fi
            fi
            FP_DATA_DIR="${FP_HOME}/data"
            FP_GATEWAY_DATA_DIR="${FP_HOME}/ai-gateway-data"
            shift 2
            ;;
        --home)        FP_HOME="$2"; FP_HOME_EXPLICIT=1; FP_DATA_DIR="${FP_HOME}/data"; FP_GATEWAY_DATA_DIR="${FP_HOME}/ai-gateway-data"; shift 2 ;;
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

# If we're in per-user mode we must know which human user to install under.
# Failing fast here beats chowning the stack to some half-resolved value.
if [ "$FP_INSTALL_MODEL" = "per-user" ]; then
    if [ -z "${FP_USER:-}" ] || [ "$FP_USER" = "root" ]; then
        die "per-user install requires --user <name> (could not infer the invoking user)"
    fi
    if ! id "$FP_USER" >/dev/null 2>&1; then
        die "per-user install target '${FP_USER}' does not exist in this system"
    fi
fi

# ── Banner ──────────────────────────────────────────────────────────────────
cat >&2 <<EOF
${FP_C_BOLD}${FP_C_CYAN}
╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar — Linux Installer                 ║
╚═══════════════════════════════════════════════════════════════╝
${FP_C_RESET}
EOF

require_root

# ── Preflight: install missing base tools (curl, sg, hostname, useradd, …) ──
# Minimal Ubuntu / Debian / RHEL / openSUSE cloud images don't ship the
# tools the installer treats as universal. Without this step, the install
# silently fails partway through (e.g. curl missing → can't download
# Docker, or sg missing → docker compose calls return "command not found"
# in the middle of the stack startup).
#
# Runs FIRST after require_root because every subsequent check_*, prompt_*,
# and registry_* call depends on at least one of these tools. Idempotent —
# no-op when everything is already present (which it will be on most
# established workstations).
fp_preflight_packages

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

# ── Existing installation detection + Upgrade/Reinstall/Fresh choice ──
log_step "checking for existing installation"
fp_detect_existing_install "$FP_HOME"
if fp_has_existing_install; then
    fp_prompt_existing_action "$FP_HOME"

    # Admin authentication gate — upgrades and reinstalls can overwrite a
    # running production stack, so require the existing admin's password.
    # Skipped when there's no compose.yml (no real stack to auth against —
    # e.g. CI workflows pre-create the user's home dir).
    # Non-interactive path: if FP_ADMIN_PASS is in env, verify once
    # (FP_ADMIN_USER defaults to "admin"). Otherwise prompt interactively.
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
            0) ;;
            2)
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
    # Mirrors the same fix in macos/install.sh.
    if [ -f "${SCRIPT_DIR}/uninstall.sh" ] && [ -d "${FP_HOME}" ]; then
        install -m 0755 -o "${FP_USER}" -g "${FP_USER}" \
            "${SCRIPT_DIR}/uninstall.sh" "${FP_HOME}/uninstall.sh" 2>/dev/null || \
            cp "${SCRIPT_DIR}/uninstall.sh" "${FP_HOME}/uninstall.sh" 2>/dev/null || true
        if [ -f "${REPO_ROOT}/shared/lib/auth.sh" ]; then
            install -m 0644 -o "${FP_USER}" -g "${FP_USER}" \
                "${REPO_ROOT}/shared/lib/auth.sh" "${FP_HOME}/auth.sh" 2>/dev/null || \
                cp "${REPO_ROOT}/shared/lib/auth.sh" "${FP_HOME}/auth.sh" 2>/dev/null || true
        fi
    fi

    if fp_try_upgrade_fastpath "$FP_HOME"; then
        log_success "Upgrade complete."
        fp_install_cli "$FP_HOME" "${FP_VERSION:-0.1.0}"
        chown -R "${FP_USER}:${FP_USER}" "${FP_HOME}/bin" 2>/dev/null || true
        exit 0
    fi
else
    log_info "no existing install detected — proceeding with fresh install"
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
elif [ "$FP_INSTALL_MODEL" = "per-user" ]; then
    # Per-user installs never create a user -- the invoking human must
    # already exist (we validated this up top).
    die "user ${FP_USER} does not exist (per-user install cannot create it)"
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
for dir in "$FP_HOME" "$FP_DATA_DIR" "$FP_GATEWAY_DATA_DIR" "${FP_HOME}/.docker"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_info "created missing directory: ${dir}"
    fi
done
chown -R "${FP_USER}:${FP_USER}" "$FP_HOME"
chmod 0755 "$FP_HOME"
chmod 0755 "$FP_DATA_DIR"
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

prompt_ai_gateway
prompt_transport_mode
prompt_admin_credentials

install -m 0644 -o "$FP_USER" -g "$FP_USER" \
    "${REPO_ROOT}/shared/compose.yml" \
    "${FP_HOME}/compose.yml"
install -m 0644 -o "$FP_USER" -g "$FP_USER" \
    "${REPO_ROOT}/shared/nginx.conf" \
    "${FP_HOME}/nginx.conf"

# Copy the AI Gateway config if it doesn't already exist (skip if disabled).
if [ "${FP_AI_GATEWAY_ENABLED}" = "true" ]; then
    if [ ! -f "${FP_HOME}/gateway.yaml" ] && [ -f "${REPO_ROOT}/shared/gateway.yaml" ]; then
        install -m 0644 -o "$FP_USER" -g "$FP_USER" \
            "${REPO_ROOT}/shared/gateway.yaml" \
            "${FP_HOME}/gateway.yaml"
        log_info "copied default gateway.yaml"
    fi
    # Defensive: strip Windows CRLF from gateway.yaml even if it already
    # existed from a prior (pre-fix) Windows install. The Python YAML
    # loader in the ai-gateway container raises ReaderError on \r bytes,
    # causing a crash-loop on every container start.
    if [ -f "${FP_HOME}/gateway.yaml" ]; then
        sed -i 's/\r$//' "${FP_HOME}/gateway.yaml" 2>/dev/null || true
    fi
fi

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
# Front-door HTTPS declaration. Read by core's --init-auto on first
# start and persisted to falconpulsar.toml; the env var stays here
# afterwards as a record of the operator's choice. Flip with care:
# changing this value alone won't update an existing deployment;
# edit falconpulsar.toml inside the data volume to take effect.
FP_COOKIE_SECURE=${FP_COOKIE_SECURE:-true}
# Update mode for the tray apps' "Check for updates" feature.
#   manual — default. Tray notifies but never applies automatically;
#            operator clicks "Apply now" when ready. Required for
#            industrial deployments where unattended restarts are
#            unsafe (process running mid-cycle, etc.).
#   auto   — when the tray app is open and detects an update, it
#            applies after a 30-second cancellable countdown. v1
#            limitation: no background daemon, so updates only fire
#            while a tray app is actually running.
# Operators flip this via the tray's settings UI or 'fp update mode'.
FP_UPDATE_MODE=${FP_UPDATE_MODE:-manual}
EOF
# .env holds FP_API_KEY (gateway service token). We want it readable by the
# invoking human user too -- on native Linux the user runs `fp` from their
# own shell, not as the `falconpulsar` system user. Gate read access via
# the `docker` group: the installer adds the invoking user to it in step 4,
# so membership already mirrors "can manage FalconPulsar". Writes stay
# restricted to the falconpulsar user (0640 = owner rw, group r).
#
# If the `docker` group somehow doesn't exist (shouldn't happen -- we rely
# on it in step 4), fall back to falconpulsar:falconpulsar to avoid a
# `chown` error bringing the install down.
if getent group docker >/dev/null 2>&1; then
    chown "${FP_USER}:docker" "${FP_HOME}/.env"
else
    chown "${FP_USER}:${FP_USER}" "${FP_HOME}/.env"
fi
chmod 0640 "${FP_HOME}/.env"
umask 022

log_success "wrote ${FP_HOME}/compose.yml and ${FP_HOME}/.env (admin password NOT stored)"

# ── Step 7: Pull, start core, bootstrap token, start the rest ──────────────
log_step "step 7/8 — pulling images and starting stack"

# We use sg here because the falconpulsar user was just added to the docker
# group in this same session and the new GID isn't in their existing process
# table yet. `sg docker -c ...` gives us a fresh group context immediately.
fp_compose_pull_with_retry "$FP_HOME" 3 "$FP_USER"

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
if [ "${FP_AI_GATEWAY_ENABLED}" = "true" ]; then
    fp_bootstrap_gateway_token "${FP_HOME}/.env"
else
    log_info "AI Gateway disabled — skipping token bootstrap"
fi

# ── 7c. Start the rest of the stack ───────────────────────────────────────
if [ "${FP_AI_GATEWAY_ENABLED}" = "true" ]; then
    log_info "starting ui and ai-gateway"
    sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose --profile ai up -d"
    # Wipe the gateway's self-seeded provider/model catalog so the user
    # lands on a clean AI configuration page. See bootstrap.sh for the
    # full rationale + the upstream fix this stops being necessary after.
    fp_wipe_gateway_seed_defaults
else
    log_info "starting ui (AI Gateway disabled)"
    sudo -u "$FP_USER" -H sg docker -c "cd '${FP_HOME}' && docker compose up -d"
fi

# ── 7d. Install the fp CLI under ${FP_HOME}/bin/ (self-contained stack) ───
fp_install_cli "$FP_HOME" "${FP_VERSION:-0.1.0}"
# Fix ownership (install.sh runs as root via sudo on Linux). Group is
# `docker` so any docker-group user can exec fp directly (matches .env).
if getent group docker >/dev/null 2>&1; then
    chown -R "${FP_USER}:docker" "${FP_HOME}/bin" 2>/dev/null || true
else
    chown -R "${FP_USER}:${FP_USER}" "${FP_HOME}/bin" 2>/dev/null || true
fi
chmod 0755 "${FP_HOME}/bin" "${FP_HOME}/bin/fp" 2>/dev/null || true
# PATH append targets the invoking human's shell rc, not root's. Pick the
# right target: per-user install means FP_USER is the human; SUDO_USER is
# the fallback for native Linux server installs run via `sudo install.sh`.
_fp_path_user=""
if [ "$FP_INSTALL_MODEL" = "per-user" ] && [ -n "${FP_USER:-}" ] && [ "$FP_USER" != "root" ]; then
    _fp_path_user="$FP_USER"
elif [ -n "${SUDO_USER:-}" ]; then
    _fp_path_user="$SUDO_USER"
fi
if [ -n "$_fp_path_user" ]; then
    sudo -u "$_fp_path_user" -H bash -c "
        export HOME=\"\$(getent passwd $_fp_path_user | cut -d: -f6)\"
        source '${REPO_ROOT}/shared/lib/common.sh'
        source '${REPO_ROOT}/shared/lib/fpcli.sh'
        FP_ASSUME_YES='${FP_ASSUME_YES:-0}' FP_ADD_TO_PATH='${FP_ADD_TO_PATH:-}' \
            fp_offer_path_append '$FP_HOME'
    " || true
else
    fp_offer_path_append "$FP_HOME"
fi
# Also drop a system-wide profile.d snippet so `fp` is on the PATH of every
# shell in the distro, for every user (useful on WSL where the default user
# might not be the one who ran the installer). Idempotent; no-ops on systems
# that don't source /etc/profile.d.
if [ -d /etc/profile.d ]; then
    cat > /etc/profile.d/falconpulsar.sh <<SNIPPET
# Added by FalconPulsar installer -- puts the fp CLI on PATH for every shell.
case ":\$PATH:" in
    *":${FP_HOME}/bin:"*) ;;
    *) PATH="\$PATH:${FP_HOME}/bin" ;;
esac
export PATH
SNIPPET
    chmod 0644 /etc/profile.d/falconpulsar.sh
    log_info "PATH snippet: /etc/profile.d/falconpulsar.sh (new shells will pick up fp)"
fi

# Also write an activation script INSIDE the stack folder. This is the
# memorable one-liner we show the user: `source ~/falconpulsar/activate.sh`.
# Living inside $FP_HOME keeps "everything in the stack folder" — matches
# what users expect when they look in there. Same effect as the profile.d
# snippet, but the user can keep it in muscle memory and it follows the
# stack wherever it moves.
cat > "${FP_HOME}/activate.sh" <<SNIPPET
# FalconPulsar — activate 'fp' on PATH for the current shell.
# Usage:  source ${FP_HOME}/activate.sh
case ":\$PATH:" in
    *":${FP_HOME}/bin:"*) ;;
    *) PATH="${FP_HOME}/bin:\$PATH" ;;
esac
export PATH
SNIPPET
chown "${FP_USER}:${FP_USER}" "${FP_HOME}/activate.sh" 2>/dev/null \
    || chown "${FP_USER}:docker" "${FP_HOME}/activate.sh" 2>/dev/null \
    || true
chmod 0644 "${FP_HOME}/activate.sh"

# ── Step 8: systemd registration (optional) ─────────────────────────────────
log_step "step 8/8 — lifecycle registration"
if [ "$FP_INSTALL_MODE" = "systemd" ] && is_wsl; then
    log_warn "WSL doesn't run user-level systemd by default -- falling back to docker mode"
    FP_INSTALL_MODE="docker"
fi
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

# ── Final reconciliation: uninstall.sh + .env ownership ────────────────────
# The block at step 2 copies uninstall.sh only on the upgrade path; this
# second copy covers the fresh-install path too (fp's `uninstall` command
# looks for ${FP_HOME}/uninstall.sh). Also re-assert ownership on .env and
# bin/ after everything has been written (belt-and-suspenders: the earlier
# chowns can silently no-op if the user's group database wasn't flushed
# yet when they ran).
if [ -f "${SCRIPT_DIR}/uninstall.sh" ] && [ -d "${FP_HOME}" ]; then
    install -m 0755 -o "${FP_USER}" -g "${FP_USER}" \
        "${SCRIPT_DIR}/uninstall.sh" "${FP_HOME}/uninstall.sh" 2>/dev/null || \
        cp "${SCRIPT_DIR}/uninstall.sh" "${FP_HOME}/uninstall.sh" 2>/dev/null || true
    chmod 0755 "${FP_HOME}/uninstall.sh" 2>/dev/null || true
fi
if [ -f "${REPO_ROOT}/shared/lib/auth.sh" ] && [ -d "${FP_HOME}" ]; then
    install -m 0644 -o "${FP_USER}" -g "${FP_USER}" \
        "${REPO_ROOT}/shared/lib/auth.sh" "${FP_HOME}/auth.sh" 2>/dev/null || \
        cp "${REPO_ROOT}/shared/lib/auth.sh" "${FP_HOME}/auth.sh" 2>/dev/null || true
fi
# Re-assert the final ownership/mode we want on the user-facing files.
if getent group docker >/dev/null 2>&1; then
    chown "${FP_USER}:docker" "${FP_HOME}/.env" 2>/dev/null || true
    chown -R "${FP_USER}:docker" "${FP_HOME}/bin" 2>/dev/null || true
fi
chmod 0640 "${FP_HOME}/.env" 2>/dev/null || true
chmod 0755 "${FP_HOME}/bin" "${FP_HOME}/bin/fp" 2>/dev/null || true

# ── Post-install health check ───────────────────────────────────────────────
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

  ${FP_C_BOLD}▸ fp CLI is at: ${FP_HOME}/bin/fp${FP_C_RESET}

  ${FP_C_YELLOW}${FP_C_BOLD}▸ Activate 'fp' in THIS terminal (one-time per shell):${FP_C_RESET}
        ${FP_C_BOLD}source ${FP_HOME}/activate.sh${FP_C_RESET}
    ${FP_C_DIM}New shells & SSH logins find 'fp' automatically.${FP_C_RESET}
    ${FP_C_DIM}If you prefer the full path:${FP_C_RESET}
        ${FP_HOME}/bin/fp status

  Control the stack with fp:
    fp                          # interactive console (TUI)
    fp status                   # stack status
    fp start | stop | restart   # control
    fp logs [service]           # tail logs
    fp config export <file>     # admin-only encrypted backup
    fp config inspect <file>    # read-only backup verification

  To uninstall: sudo bash ${SCRIPT_DIR}/uninstall.sh

EOF
