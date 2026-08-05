#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

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
#   5. Generate compose.yml + .env + gateway.yaml in /home/falconpulsar/
#   6. Pull images, start core, mint the AI Gateway service token, then
#      start ui + ai-gateway as the falconpulsar user
#   7. Optionally register a systemd unit for lifecycle management
#   8. Wait for the core + AI Gateway healthchecks and print connection
#      details
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

# Fail fast when not root: this installer creates the falconpulsar system
# user, installs Docker, and writes under /home/falconpulsar. Without this
# check a non-root run used to die confusingly mid-flow at useradd.
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this installer must run as root." >&2
    echo "       Try:  curl -fsSL https://get.falconpulsar.com/linux | sudo bash" >&2
    echo "       Or:   sudo bash $0" >&2
    exit 1
fi

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
# registry_auth.sh defaults FP_REGISTRY and FP_VERSION at source time, so
# record whether the operator pinned them first — the reinstall carry-forward
# below must be able to tell an explicit pin from the library default when
# it seeds settings from a pre-existing .env. (eval keeps the *_EXPLICIT
# markers pairable by name with the variables that carry-forward loop reads.)
for _fp_var in FP_REGISTRY FP_VERSION; do
    eval "${_fp_var}_EXPLICIT=\${${_fp_var}:+1}"
done
unset _fp_var
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
            _fp_default_user="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
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
# Record which of these the operator supplied explicitly (environment here,
# flags below) before the defaults fill in the rest — on a reinstall the
# non-explicit ones are seeded from the previous .env so custom layouts,
# port remaps and version pins survive the stack-file rewrite.
for _fp_var in FP_DATA_DIR FP_GATEWAY_DATA_DIR FP_ENGINE_DATA_DIR FP_COPILOT_DATA_DIR \
    FP_AI_ENGINE_ENABLED FP_COPILOT_ENABLED FP_COPILOT_PORT \
    FP_AUTH_MODE FP_SSO_PROVIDER \
    FP_REST_PORT FP_WS_PORT \
    FP_PUBSUB_PORT FP_GATEWAY_PORT FP_UI_PORT FP_ENGINE_PORT FP_PUBLIC_HOST \
    FP_COOKIE_SECURE FP_UPDATE_MODE; do
    eval "${_fp_var}_EXPLICIT=\${${_fp_var}:+1}"
done
unset _fp_var
FP_DATA_DIR="${FP_DATA_DIR:-${FP_HOME}/data}"
FP_GATEWAY_DATA_DIR="${FP_GATEWAY_DATA_DIR:-${FP_HOME}/ai-gateway-data}"
# Optional AI Engine (author/simulate/deploy agents). Off by default; its
# config + agent state live in the SAME main folder as Core/Gateway.
FP_ENGINE_DATA_DIR="${FP_ENGINE_DATA_DIR:-${FP_HOME}/ai-engine-data}"
# AI Engine is now a STANDARD service (always installed). Force-enabled so the
# fp console / tray / update-check surfaces always show it (Command Center is
# the only optional opt-in now).
FP_AI_ENGINE_ENABLED="true"
# Optional Command Center — same layout: sibling of data/ under FP_HOME.
# Path is always defined (like FP_ENGINE_DATA_DIR); directory is created
# only when the module is enabled.
FP_COPILOT_DATA_DIR="${FP_COPILOT_DATA_DIR:-${FP_HOME}/copilot-data}"
FP_COPILOT_ENABLED="${FP_COPILOT_ENABLED:-false}"
FP_COPILOT_PORT="${FP_COPILOT_PORT:-8090}"
FP_AUTH_MODE="${FP_AUTH_MODE:-local}"
FP_SSO_PROVIDER="${FP_SSO_PROVIDER:-none}"
FP_SSO_ISSUER="${FP_SSO_ISSUER:-}"
FP_SSO_CLIENT_ID="${FP_SSO_CLIENT_ID:-}"
# Command Center is the only profile-gated optional module; AI Engine is now a
# standard service (no compose profile).
COMPOSE_PROFILES=""
if [ "${FP_COPILOT_ENABLED}" = "true" ]; then COMPOSE_PROFILES="copilot"; fi
FP_INSTALL_MODE="${FP_INSTALL_MODE:-}"        # docker | systemd
FP_REST_PORT="${FP_REST_PORT:-7433}"
FP_WS_PORT="${FP_WS_PORT:-7434}"
FP_PUBSUB_PORT="${FP_PUBSUB_PORT:-7435}"
FP_GATEWAY_PORT="${FP_GATEWAY_PORT:-7436}"
FP_UI_PORT="${FP_UI_PORT:-8080}"
FP_ENGINE_PORT="${FP_ENGINE_PORT:-8085}"
# The host a BROWSER types to reach this machine. Not a bind address and not
# a container name: the shell embeds Command Center and AI Engine as frames,
# so the browser resolves their origins itself. Those origins go into the
# shell's CSP and into each surface's frame-ancestors, and if they name a
# host the browser cannot reach, both modes are blank rectangles. localhost
# is right for a workstation install; set this to the machine's hostname or
# address for anything reached from another computer.
FP_PUBLIC_HOST="${FP_PUBLIC_HOST:-localhost}"
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
  --remove-cached-images    On a fresh install, also remove cached
                            FalconPulsar Docker images (default: ask)
  --keep-cached-images      On a fresh install, keep cached images
                            (default: ask)
  --debug                   Verbose debug output
  --help, -h                This help

Environment variables override defaults. See REQUIREMENTS.md for prerequisites.
EOF
}

while [ $# -gt 0 ]; do
    # shellcheck disable=SC2034  # FP_REMOVE_CACHED_IMAGES is consumed by
    # shared/lib/existing.sh, sourced at runtime (shellcheck can't follow it).
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
        --data-dir)
            FP_DATA_DIR="$2"
            # shellcheck disable=SC2034  # consumed via eval in the .env carry-forward
            FP_DATA_DIR_EXPLICIT=1
            shift 2 ;;
        --rest-port)
            FP_REST_PORT="$2"
            # shellcheck disable=SC2034  # consumed via eval in the .env carry-forward
            FP_REST_PORT_EXPLICIT=1
            shift 2 ;;
        --ui-port)
            FP_UI_PORT="$2"
            # shellcheck disable=SC2034  # consumed via eval in the .env carry-forward
            FP_UI_PORT_EXPLICIT=1
            shift 2 ;;
        -y|--yes)      FP_ASSUME_YES=1; shift ;;
        --remove-cached-images) FP_REMOVE_CACHED_IMAGES=true; shift ;;
        --keep-cached-images)   FP_REMOVE_CACHED_IMAGES=false; shift ;;
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

# ── Step 1: Pre-flight checks ───────────────────────────────────────────────
# Note on ordering: the port check used to run here and aborted with
# `die "port conflict"` if any FalconPulsar port was bound. That made
# re-running the installer impossible whenever a previous install's own
# containers were still running — those containers held our ports and
# the user never got to choose Upgrade / Reinstall / Fresh. The port
# check now runs LATER (after the existing-install block stops our own
# containers) so it only ever flags genuinely-external conflicts, and
# it offers remap-or-abort instead of dying.
log_step "step 1/8 — pre-flight checks"
check_supported_os
check_arch
check_kernel
check_ram
check_disk "$(dirname "$FP_HOME")"

# ── Existing installation detection + Upgrade/Reinstall/Fresh choice ──
# Read-only at this point: inventory + the menu choice only. The teardown
# the choice implies (fp_apply_existing_action), the admin auth gate and
# the upgrade fast-path all run AFTER the legal acknowledgement and the
# Docker checks below — no system mutation happens before Legal. Docker
# may not be installed yet on a fresh box: fp_detect_existing_install
# probes for the docker CLI defensively, so the inventory then lists
# stack files only (container/image counts appear once docker exists).
log_step "checking for existing installation"
fp_detect_existing_install "$FP_HOME"
if fp_has_existing_install; then
    fp_prompt_existing_action "$FP_HOME"
else
    log_info "no existing install detected — proceeding with fresh install"
fi

# ── Legal acknowledgement (must come before any system change) ──────────────
# Skipped for an in-place upgrade (alpha.47 parity with the macOS/Windows
# GUIs): the terms were accepted at install, and the upgrade fast-path only
# pulls + restarts. If the fast-path FALLS THROUGH to the full installer,
# the acknowledgement is collected at that point instead (see below) — a
# terminal can re-prompt mid-flow, unlike the GUI wizards.
if [ "${FP_INSTALL_ACTION:-}" != "upgrade" ]; then
    prompt_legal_acknowledgement
fi

# ── Preflight: install missing base tools (curl, sg, hostname, useradd, …) ──
# Minimal Ubuntu / Debian / RHEL / openSUSE cloud images don't ship the
# tools the installer treats as universal. Without this step, the install
# silently fails partway through (e.g. curl missing → can't download
# Docker, or sg missing → docker compose calls return "command not found"
# in the middle of the stack startup).
#
# Runs FIRST after the legal acknowledgement — it installs packages, so
# it must never precede Legal; everything above this point is read-only.
# Every subsequent check_*, prompt_*, and registry_* call depends on at
# least one of these tools. Idempotent — no-op when everything is already
# present (which it will be on most established workstations).
fp_preflight_packages

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

# ── Existing installation: authorize + apply the chosen action ─────────────
# The Upgrade/Reinstall/Fresh choice was collected before Legal (read-only
# inventory + menu, next to the step-1 checks). Its side effects happen
# here, with Legal accepted and Docker available.
if fp_has_existing_install; then
    # Admin authentication gate — upgrades and reinstalls can overwrite a
    # running production stack, so require the existing admin's password.
    # Skipped when there's no compose.yml (no real stack to auth against —
    # e.g. CI workflows pre-create the user's home dir).
    # Non-interactive path: if FP_ADMIN_PASS is in env, verify once
    # (FP_ADMIN_USER defaults to "admin"). Otherwise prompt interactively.
    # Upgrades are exempt (alpha.48 parity): an in-place upgrade neither
    # creates an admin nor destroys data, and `fp update --apply` already
    # performs the identical operation with no password. Reinstall keeps
    # the gate — it rewrites the stack files over a running install. This
    # also fixes headless `--yes` upgrades, which previously died at the
    # interactive password prompt when Core was up and no FP_ADMIN_PASS
    # was exported.
    if [ "${FP_FORCE:-0}" != "1" ] && \
       [ "${FP_INSTALL_ACTION:-}" = "reinstall" ] && \
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

    # The fast-path fell through to the FULL installer, which reconfigures
    # the stack — collect the Legal acknowledgement that the upgrade path
    # skipped above (still honors FP_LEGAL_ACCEPTED / --yes for headless).
    if [ "${FP_INSTALL_ACTION:-}" = "upgrade" ]; then
        prompt_legal_acknowledgement
    fi
fi

# ── Carry the previous configuration forward from a surviving .env ─────────
# Reinstalls (and upgrades that fall through to the full flow) rewrite .env
# from this shell's defaults in step 6, which used to silently reset custom
# ports, a custom --data-dir (orphaning the database while core re-inits an
# empty one), a pinned FP_VERSION and a private registry mirror. Seed those
# values from the existing .env here, before anything consumes them — the
# port check, the registry probe and the step-6 rewrite must all see the
# install's real layout. Explicit env/flag values still win (tracked via
# the *_EXPLICIT markers set alongside the defaults above). The fresh path
# is unaffected: fp_apply_existing_action deleted ${FP_HOME} — and the .env
# with it — before we get here.
if [ -f "${FP_HOME}/.env" ]; then
    _fp_seeded=""
    # FP_AI_ENGINE_ENABLED is deliberately NOT carried forward: the engine is
    # a standard service now and the value is force-set true above. Seeding it
    # from a pre-change .env would silently restore "false" and skip creating
    # the engine data dir while compose starts the container regardless.
    for _fp_var in FP_DATA_DIR FP_GATEWAY_DATA_DIR FP_ENGINE_DATA_DIR FP_COPILOT_DATA_DIR \
        FP_COPILOT_ENABLED FP_COPILOT_PORT \
        FP_AUTH_MODE FP_SSO_PROVIDER \
        FP_REST_PORT FP_WS_PORT \
        FP_PUBSUB_PORT FP_GATEWAY_PORT FP_UI_PORT FP_ENGINE_PORT FP_PUBLIC_HOST \
        FP_REGISTRY FP_VERSION \
        FP_COOKIE_SECURE FP_UPDATE_MODE; do
        _fp_explicit=""
        eval "_fp_explicit=\${${_fp_var}_EXPLICIT:-}"
        if [ "$_fp_explicit" = "1" ]; then
            continue
        fi
        # tr: tolerate CRLF line endings from a hand-edited / Windows .env.
        # tail -n1: last occurrence wins, matching docker compose's env-file
        # semantics, so a hand-appended override seeds the same value the
        # stack actually runs with.
        _fp_val="$(sed -n "s/^${_fp_var}=//p" "${FP_HOME}/.env" | tail -n1 | tr -d '\r')"
        if [ -n "$_fp_val" ]; then
            eval "${_fp_var}=\"\$_fp_val\""
            _fp_seeded="${_fp_seeded} ${_fp_var}"
        fi
    done
    if [ -n "$_fp_seeded" ]; then
        log_info "carrying forward from the existing .env:${_fp_seeded}"
    fi
    unset _fp_var _fp_val _fp_explicit _fp_seeded
fi

# ── Phantom-container sweep ─────────────────────────────────────────────────
# Containers from a previous install whose stack directory has been
# removed manually (or whose FP_HOME differs from the one we're about to
# write to) won't appear in fp_detect_existing_install because there's
# no compose.yml to find — but they're still running and holding our
# ports. Detect + offer to remove them BEFORE the port check, so the
# user gets a clear "I see these orphans, here's what to do" rather
# than a generic "port 7433 is in use".
log_step "checking for orphaned containers from previous installs"
if fp_detect_phantom_containers "$FP_HOME"; then
    fp_handle_phantom_containers
else
    log_success "no orphaned FalconPulsar containers found"
fi

# ── Port check (smart, recoverable) ─────────────────────────────────────────
# Runs AFTER the existing-install block has stopped our own containers
# (and after the phantom sweep has cleaned up dangling ones from prior
# installs). Whatever still holds an FP port at this point is external —
# we surface what's holding it and let the user remap our port, re-check
# after fixing manually, or abort.
log_step "verifying required TCP ports are free"
fp_check_ports_interactive FP_REST_PORT FP_WS_PORT FP_PUBSUB_PORT FP_GATEWAY_PORT FP_UI_PORT FP_ENGINE_PORT

# Container registry — wizard-style prompt (Linux parity with Mac SwiftUI
# RegistryPage and Windows Inno Setup RegistryPage). Collects URL +
# optional credentials + optional skip + does a live "test connection"
# probe BEFORE the installer commits to anything. After this returns,
# fp_registry_ensure_access is effectively a no-op safety net.
#
# Skipped automatically (no prompt) when FP_ASSUME_YES=1 or when
# FP_REGISTRY / FP_REGISTRY_USER / FP_REGISTRY_PASS / FP_REGISTRY_SKIP were
# pre-set in the environment (CI, headless installs, parent installer).
fp_registry_prompt_settings

# Verify we can pull images from the configured registry. After
# fp_registry_prompt_settings above, this is usually a no-op; it's kept as
# a safety net for non-interactive runs that supplied bad env credentials.
# Whatever configuration ends up in root's ~/.docker/config.json here is
# copied into the falconpulsar user's home in step 6 so the unprivileged
# user can pull.
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
elif getent group "$FP_USER" >/dev/null 2>&1; then
    # A previous --purge uninstall can leave the group behind: userdel only
    # removes it when empty, and this installer adds the invoking human to
    # it below. useradd without -g would then die with "group falconpulsar
    # exists" and wedge every purge→fresh cycle — reuse the group instead.
    useradd \
        --system \
        --create-home \
        --home-dir "$FP_HOME" \
        --shell /bin/bash \
        --comment "FalconPulsar service account" \
        -g "$FP_USER" \
        "$FP_USER"
    log_success "created ${FP_USER} (home: ${FP_HOME}, reused existing group)"
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
# 0750 = owner rwx, group rx, others none. Group is `falconpulsar`
# (the system user's primary group). The invoking human gets in via
# group membership added below — they need it to inspect compose.yml,
# .env, the data dir, logs, etc. Additional users can be granted access
# later with: sudo usermod -aG falconpulsar <user>.
chmod 0750 "$FP_HOME"
chmod 0750 "$FP_DATA_DIR"
chmod 0700 "${FP_HOME}/.docker"
log_success "home directory ready: ${FP_HOME}"

# ── Add the invoking human to the falconpulsar group ────────────────────────
# Without this, the human who ran `sudo bash install.sh` cannot read
# anything inside ${FP_HOME} (group-owned by 'falconpulsar', mode 0750).
# Skipped on per-user installs — FP_USER is already the human.
if [ "$FP_INSTALL_MODEL" = "service-user" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    if id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$FP_USER"; then
        log_success "${SUDO_USER} is already in the ${FP_USER} group"
    else
        usermod -aG "$FP_USER" "$SUDO_USER"
        log_success "added ${SUDO_USER} to the ${FP_USER} group (re-login required)"
    fi
fi

FP_UID="$(id -u "$FP_USER")"
FP_GID="$(id -g "$FP_USER")"
export FP_UID FP_GID

# Stop any stale containers from a previous install before proceeding.
# This prevents port conflicts and ensures a clean state.
#
# --profile ai: legacy compose compat (pre-mandatory-gateway installs
# gated ai-gateway behind the "ai" profile); no-op on current stacks —
# Compose v2 ignores unknown profile names.
#
# We use raw `docker compose` here (not fp) because the new install's
# fp binary isn't on disk yet — that lives in step 7.
if run_as_user "$FP_USER" docker compose -f "${FP_HOME}/compose.yml" ps -q 2>/dev/null | grep -q .; then
    log_info "stopping stale containers from previous install..."
    run_as_user "$FP_USER" docker compose -f "${FP_HOME}/compose.yml" --profile ai down --remove-orphans 2>/dev/null || true
    log_info "stale containers stopped"
fi

# ── Step 4: Docker group membership ─────────────────────────────────────────
log_step "step 4/8 — docker group"
add_user_to_docker_group "$FP_USER"

# Also add the invoking human to the docker group so they can run
# `docker ps` / `docker logs falconpulsar-core` etc. without sudo.
# Per-user installs already covered this via the line above.
if [ "$FP_INSTALL_MODEL" = "service-user" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    if id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "docker"; then
        log_success "${SUDO_USER} is already in the docker group"
    else
        add_user_to_docker_group "$SUDO_USER"
    fi
fi

# ── Step 5: Install mode selection ──────────────────────────────────────────
log_step "step 5/8 — install mode"
if [ -z "$FP_INSTALL_MODE" ]; then
    # Unattended runs cannot answer the menu below — fail fast with the
    # exact flag to pass instead of looping on a read that can never
    # succeed (with stdin at EOF the old loop busy-printed "please answer
    # 1 or 2" forever).
    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        die "FP_ASSUME_YES=1 but no install mode selected — re-run with --mode docker (or --mode systemd)"
    fi
    cat >&2 <<EOF

Choose how FalconPulsar should be managed:

  ${FP_C_BOLD}1) docker${FP_C_RESET}    Pure docker-compose, managed by you. Manage with:
                  fp start | stop | restart | status
              You restart the stack manually after a reboot.

  ${FP_C_BOLD}2) systemd${FP_C_RESET}   Register a systemd user unit so the stack
              starts at boot and can be managed with:
                  systemctl --user start/stop/status falconpulsar
              (also works via fp start/stop/restart)

EOF
    while :; do
        printf '%schoose [1/2]:%s ' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        if ! read -r choice; then
            # stdin hit EOF (piped install, </dev/null) — retrying would
            # spin forever on the same failed read.
            printf '\n' >&2
            die "no interactive input available for the mode menu — re-run with --mode docker (or --mode systemd)"
        fi
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

# ── Step 6: Generate compose.yml + .env + gateway.yaml ──────────────────────
log_step "step 6/8 — stack files in ${FP_HOME}"

# Options: front-door HTTPS, auth mode, optional module (Command Center), admin.
# AI Engine is standard (always installed) — no prompt. prompt_copilot refreshes
# COMPOSE_PROFILES; admin last.
prompt_transport_mode
prompt_auth_mode
prompt_copilot
if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
    fp_check_ports_interactive FP_COPILOT_PORT
fi
prompt_admin_credentials

install -m 0644 -o "$FP_USER" -g "$FP_USER" \
    "${REPO_ROOT}/shared/compose.yml" \
    "${FP_HOME}/compose.yml"
install -m 0644 -o "$FP_USER" -g "$FP_USER" \
    "${REPO_ROOT}/shared/nginx.conf" \
    "${FP_HOME}/nginx.conf"

# A broken earlier install can leave gateway.yaml as a DIRECTORY: docker
# auto-creates missing bind-mount sources as directories, so a compose up
# that ran before the config existed plants one. The copy below would then
# land INSIDE it (gateway.yaml/gateway.yaml) and the gateway crash-loops
# on the directory mount. Clear it before provisioning the real file.
if [ -d "${FP_HOME}/gateway.yaml" ]; then
    log_warn "${FP_HOME}/gateway.yaml is a directory (docker auto-created it on a broken install) — removing it"
    rm -rf "${FP_HOME}/gateway.yaml"
fi

# Copy the AI Gateway config if it doesn't already exist.
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

# Data dirs — same pattern for every module:
#   install -d -m 0750 -o $FP_USER  under $FP_HOME
#   absolute path written to .env
#   compose bind-mounts that path → /data (or /app/data for gateway)
install -d -m 0750 -o "$FP_USER" -g "$FP_USER" "$FP_DATA_DIR"
install -d -m 0750 -o "$FP_USER" -g "$FP_USER" "$FP_GATEWAY_DATA_DIR"
# Optional modules: only create when enabled (same as historical engine path).
[ "$FP_AI_ENGINE_ENABLED" = "true" ] && install -d -m 0750 -o "$FP_USER" -g "$FP_USER" "$FP_ENGINE_DATA_DIR"
FP_COPILOT_DATA_DIR="${FP_COPILOT_DATA_DIR:-${FP_HOME}/copilot-data}"
if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
  install -d -m 0750 -o "$FP_USER" -g "$FP_USER" "$FP_COPILOT_DATA_DIR"
  log_info "Command Center data dir: ${FP_COPILOT_DATA_DIR}"
fi
# Stack-level config files live in FP_HOME (like gateway.yaml), not inside module data.
fp_write_auth_policy "${FP_HOME}/auth-policy.json"

# Copy root's Docker Hub credentials into the falconpulsar user's home so
# `sudo -u falconpulsar -g docker -H bash -c 'docker compose pull'` can
# pull the private images. Pre-release only — once images are public
# this can go.
ROOT_DOCKER_CFG="${DOCKER_CONFIG:-/root/.docker}/config.json"
if [ -f "$ROOT_DOCKER_CFG" ]; then
    install -d -m 0700 -o "$FP_USER" -g "$FP_USER" "${FP_HOME}/.docker"
    install -m 0600 -o "$FP_USER" -g "$FP_USER" \
        "$ROOT_DOCKER_CFG" "${FP_HOME}/.docker/config.json"
    log_success "Docker Hub credentials propagated to ${FP_HOME}/.docker"
fi

# Carry gateway secrets forward from a pre-existing .env (reinstall, or
# an upgrade that fell through to the full flow). These must never be
# regenerated while the data directories survive: FP_GATEWAY_SECRET
# encrypts the LLM provider keys at rest in ai_config.db (a new value
# orphans them), FP_API_KEY is the gateway's minted service token, and
# FP_BRIDGE_TOKEN must keep matching on both core and gateway.
# Explicit env-provided values still win.
FP_EXISTING_API_KEY=""
FP_EXISTING_GATEWAY_SECRET=""
if [ -f "${FP_HOME}/.env" ]; then
    if [ -z "${FP_BRIDGE_TOKEN:-}" ]; then
        FP_BRIDGE_TOKEN="$(sed -n 's/^FP_BRIDGE_TOKEN=//p' "${FP_HOME}/.env" | head -n1)"
    fi
    FP_EXISTING_API_KEY="$(sed -n 's/^FP_API_KEY=//p' "${FP_HOME}/.env" | head -n1)"
    FP_EXISTING_GATEWAY_SECRET="$(sed -n 's/^FP_GATEWAY_SECRET=//p' "${FP_HOME}/.env" | head -n1)"
    if [ -n "$FP_EXISTING_API_KEY" ] || [ -n "$FP_EXISTING_GATEWAY_SECRET" ]; then
        log_info "preserving existing gateway credentials from ${FP_HOME}/.env"
    fi
fi

# A carried-forward FP_API_KEY is only valid against the core database it
# was minted in. When that database does not survive into this install
# (data dir missing or empty — core's first-run init will build a fresh
# one), drop the token so step 7b mints a new one; keeping it would
# suppress the mint and leave the gateway healthy-but-unauthorized
# against core. FP_GATEWAY_SECRET is still carried: it encrypts provider
# keys in the gateway's own database, which lives elsewhere.
if [ -n "$FP_EXISTING_API_KEY" ] && \
   { [ ! -d "$FP_DATA_DIR" ] || [ -z "$(ls -A "$FP_DATA_DIR" 2>/dev/null)" ]; }; then
    log_warn "found FP_API_KEY in the old .env but no surviving database in ${FP_DATA_DIR} — a new gateway service token will be minted"
    FP_EXISTING_API_KEY=""
fi

# SEC-001: Generate (or preserve) FP_BRIDGE_TOKEN.
# The bridge token is a shared secret used by core when it calls the
# AI gateway's /api/v1/bridge/* endpoints. The gateway's AuthMiddleware
# rejects bridge calls without a matching X-FP-Internal-Token header.
#
# If the operator already set FP_BRIDGE_TOKEN in their environment we
# honour it (useful for orchestrated multi-host deploys). Otherwise we
# generate 32 random bytes (hex-encoded) here. The token is written to
# .env below and read by both core and ai-gateway containers.
if [ -z "${FP_BRIDGE_TOKEN:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        FP_BRIDGE_TOKEN="$(openssl rand -hex 32)"
    elif [ -r /dev/urandom ]; then
        FP_BRIDGE_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        die "cannot generate FP_BRIDGE_TOKEN: neither openssl nor /dev/urandom available"
    fi
    log_info "generated FP_BRIDGE_TOKEN (32 random bytes, hex)"
fi

# Write-confirmation HMAC secret (multi-worker shared). Preserve across
# reinstalls when present; generate once when absent. Same entropy class
# as FP_BRIDGE_TOKEN.
if [ -z "${FP_CONFIRM_SECRET:-}" ]; then
    if [ -f "${FP_HOME}/.env" ]; then
        FP_CONFIRM_SECRET="$(sed -n 's/^FP_CONFIRM_SECRET=//p' "${FP_HOME}/.env" | head -n1)"
    fi
fi
if [ -z "${FP_CONFIRM_SECRET:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        FP_CONFIRM_SECRET="$(openssl rand -hex 32)"
    elif [ -r /dev/urandom ]; then
        FP_CONFIRM_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        die "cannot generate FP_CONFIRM_SECRET: neither openssl nor /dev/urandom available"
    fi
    log_info "generated FP_CONFIRM_SECRET (32 random bytes, hex)"
fi

# .env — note 0640 perms (group docker, see below). The admin password
# is never stored here. Secrets that DO land in .env:
#   - FP_API_KEY       AI-gateway Bearer service token (added by bootstrap.sh)
#   - FP_BRIDGE_TOKEN  core ↔ gateway bridge shared secret (SEC-001)
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
# Optional AI Engine — its config lives in the shared main folder. To turn it
# on: set FP_AI_ENGINE_ENABLED=true (COMPOSE_PROFILES is derived), then run
# "docker compose up -d". (No backticks here: this heredoc is unquoted, so
# backticks would EXECUTE the command while writing .env.)
FP_ENGINE_DATA_DIR=${FP_ENGINE_DATA_DIR}
FP_AI_ENGINE_ENABLED=${FP_AI_ENGINE_ENABLED}
# Optional Command Center (clean default). Enable with
# FP_COPILOT_ENABLED=true and COMPOSE_PROFILES including copilot.
# Optional Command Center — data lives under FP_HOME like Core/Gateway/Engine.
# To enable later: FP_COPILOT_ENABLED=true, add copilot to COMPOSE_PROFILES,
# mkdir -p "$FP_COPILOT_DATA_DIR", docker compose up -d.
FP_COPILOT_ENABLED=${FP_COPILOT_ENABLED}
FP_COPILOT_PORT=${FP_COPILOT_PORT}
FP_COPILOT_DATA_DIR=${FP_COPILOT_DATA_DIR}
# Image tag: standard installs pull :latest (or FP_VERSION). Demo image is separate.
FP_COPILOT_IMAGE_TAG=${FP_COPILOT_IMAGE_TAG:-${FP_VERSION:-latest}}
COMPOSE_PROFILES=${COMPOSE_PROFILES}
# Auth policy (local | sso_later | sso_now). Break-glass local admin always.
FP_AUTH_MODE=${FP_AUTH_MODE}
FP_SSO_PROVIDER=${FP_SSO_PROVIDER}
FP_SSO_ISSUER=${FP_SSO_ISSUER}
FP_SSO_CLIENT_ID=${FP_SSO_CLIENT_ID}
# Anchor the gateway.yaml mount to the stack dir — compose's default
# resolves relative to FP_DATA_DIR, which breaks with a custom --data-dir.
FP_GATEWAY_CONFIG=${FP_HOME}/gateway.yaml
FP_HOME=${FP_HOME}
FP_UID=${FP_UID}
FP_GID=${FP_GID}
FP_REGISTRY=${FP_REGISTRY}
FP_VERSION=${FP_VERSION}
FP_REST_PORT=${FP_REST_PORT}
FP_WS_PORT=${FP_WS_PORT}
FP_PUBSUB_PORT=${FP_PUBSUB_PORT}
FP_GATEWAY_PORT=${FP_GATEWAY_PORT}
FP_UI_PORT=${FP_UI_PORT}
FP_ENGINE_PORT=${FP_ENGINE_PORT}
# Browser-visible host for the shell and the two surfaces it embeds. See the
# note in this script; changing it requires 'docker compose up -d' so the new
# origins reach the CSP and the frame-ancestors headers.
FP_PUBLIC_HOST=${FP_PUBLIC_HOST}
FP_LOG_LEVEL=${FP_LOG_LEVEL}
# Legacy key kept for older fp/tray binaries that still read it. The AI
# Gateway is a mandatory component — this is always true.
FP_AI_GATEWAY_ENABLED=true
# SEC-001: shared secret read by both core and ai-gateway containers.
# Rotate by overwriting this value and 'docker compose up -d'.
FP_BRIDGE_TOKEN=${FP_BRIDGE_TOKEN}
# HMAC secret for AI Gateway write-confirmation IDs (multi-worker).
FP_CONFIRM_SECRET=${FP_CONFIRM_SECRET}
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
# Re-append the gateway credentials carried forward from the previous
# .env (see above — never regenerate these while the data dirs survive).
if [ -n "$FP_EXISTING_API_KEY" ]; then
    printf 'FP_API_KEY=%s\n' "$FP_EXISTING_API_KEY" >> "${FP_HOME}/.env"
fi
if [ -n "$FP_EXISTING_GATEWAY_SECRET" ]; then
    printf 'FP_GATEWAY_SECRET=%s\n' "$FP_EXISTING_GATEWAY_SECRET" >> "${FP_HOME}/.env"
fi
# SEC-003: FP_GATEWAY_SECRET encrypts LLM provider API keys at rest in
# ai_config.db; without it the gateway falls back to plaintext storage.
# fp_bootstrap_gateway_token provisions it alongside the token mint, but
# step 7b skips the mint when FP_API_KEY was carried forward — a
# pre-SEC-003 .env (token present, no secret) would otherwise stay in
# plaintext mode forever. Generate here when absent, independent of the
# mint. Never rotate: a new value orphans already-encrypted keys.
if ! grep -q '^FP_GATEWAY_SECRET=.' "${FP_HOME}/.env"; then
    if command -v openssl >/dev/null 2>&1; then
        FP_GATEWAY_SECRET_NEW="$(openssl rand -hex 32)"
    elif [ -r /dev/urandom ]; then
        FP_GATEWAY_SECRET_NEW="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        die "cannot generate FP_GATEWAY_SECRET: neither openssl nor /dev/urandom available"
    fi
    printf 'FP_GATEWAY_SECRET=%s\n' "$FP_GATEWAY_SECRET_NEW" >> "${FP_HOME}/.env"
    unset FP_GATEWAY_SECRET_NEW
    log_info "generated FP_GATEWAY_SECRET (SEC-003: provider keys encrypted at rest)"
fi
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

# `sudo -g docker` sets the effective gid to docker for the duration of the
# call. We need it because the falconpulsar user was just added to the
# docker group in this same session and the new GID isn't in their
# existing process table yet. Previously we used `sg docker -c` for this,
# but /usr/bin/sg is missing from some minimal Ubuntu cloud images even
# when the `login` package is installed (filesystem-stripped containers,
# etc.). sudo is always present (we're invoked through it), so this is
# the universal path.
fp_compose_pull_with_retry "$FP_HOME" 3 "$FP_USER" || \
    die "docker compose pull failed after retries — check registry access/network and re-run the installer"

# ── 7a. Start core only with FP_ADMIN_PASS injected from this shell ────────
# We deliberately do NOT write FP_ADMIN_PASS to .env. Instead we pass it
# via the per-call environment. compose.yml has `${FP_ADMIN_PASS:-}` so
# the value comes from whatever env we set here. Once first-run init
# completes, the password is hashed in the database and we never need
# the plaintext again.
#
# We escape any single quotes in the password (replace ' with '\'') so
# arbitrary user-supplied passwords don't break the inner shell parsing
# of the bash -c "..." invocation. Auto-generated passwords are
# alphanumeric and don't need this, but a user-supplied one might.
log_info "starting core (first-run init may take 60-90s)"
FP_ADMIN_PASS_ESC="${FP_ADMIN_PASS//\'/\'\\\'\'}"
sudo -u "$FP_USER" -g docker -H bash -c \
    "cd '${FP_HOME}' && FP_ADMIN_PASS='${FP_ADMIN_PASS_ESC}' docker compose up -d core"
unset FP_ADMIN_PASS_ESC

# Wait for core healthcheck — up to 3 minutes for first-run init.
log_info "waiting for core to become healthy"
deadline=$(( $(date +%s) + 180 ))
while :; do
    health=$(sudo -u "$FP_USER" -g docker -H bash -c "docker inspect -f '{{.State.Health.Status}}' falconpulsar-core 2>/dev/null" || echo unknown)
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
# Skipped when a token was carried forward from a previous .env — minting
# a new one would strand the old token, and the accompanying
# FP_GATEWAY_SECRET regeneration would orphan the provider keys it
# encrypted in ai_config.db.
if grep -q '^FP_API_KEY=.' "${FP_HOME}/.env" 2>/dev/null; then
    log_info "gateway service token already present in .env — keeping it"
else
    fp_bootstrap_gateway_token "${FP_HOME}/.env"
fi

# ── 7c. Start the rest of the stack ───────────────────────────────────────
log_info "starting ui and ai-gateway"
# Record whether the gateway database already exists BEFORE the container
# can create one — it decides whether the seed wipe below is safe.
GATEWAY_DB_PREEXISTS=0
if [ -f "${FP_GATEWAY_DATA_DIR}/ai_config.db" ]; then
    GATEWAY_DB_PREEXISTS=1
fi
sudo -u "$FP_USER" -g docker -H bash -c "cd '${FP_HOME}' && docker compose up -d"
# Hard gate: the AI Gateway is a mandatory component — an install whose
# gateway never becomes healthy is a failed install, not a warning.
fp_wait_for_gateway_ready "${FP_GATEWAY_PORT}" || \
    die "AI Gateway did not become healthy. Check: docker logs falconpulsar-ai-gateway"
# Wipe the gateway's self-seeded provider/model catalog so the user
# lands on a clean AI configuration page. See bootstrap.sh for the
# full rationale + the upstream fix this stops being necessary after.
# Only on a fresh gateway database: a pre-existing ai_config.db
# (reinstall-keep-data, upgrade fall-through, keep-data uninstall then
# install) holds user-configured providers/models — wiping it would
# destroy the very data the credential carry-forward above preserves.
if [ "$GATEWAY_DB_PREEXISTS" = "0" ]; then
    fp_wipe_gateway_seed_defaults
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
    # The bundle script creates REPO_ROOT via `mktemp -d` which produces
    # a mode 0700 dir owned by whoever ran the installer (root, via curl|sudo).
    # We're about to `sudo -u "$_fp_path_user"` to drop privileges so the
    # PATH-append prompt edits the right user's rc files — but that user
    # cannot read root-owned 0700 dirs / 0600 files, so the `source` lines
    # below would fail with "Permission denied" (which used to leave the
    # user with the alarming `fp_offer_path_append: command not found`
    # at the very end of an otherwise-clean install).
    #
    # `a+rX` adds read for everyone + execute (traverse) on directories
    # only. The temp dir lives in /tmp and contains no secrets (compose.yml,
    # nginx.conf, the lib shell scripts) — making it world-readable for the
    # ~5 seconds the trap'd cleanup takes is fine. The actual install
    # secrets (admin password, registry creds) live in $FP_HOME/.env which
    # has its own 0640 mode.
    chmod -R a+rX "$REPO_ROOT" 2>/dev/null || true

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
    log_info "to start/stop manually: fp start | fp stop | fp restart"
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
HEALTH_SVCS="falconpulsar-core falconpulsar-ui falconpulsar-ai-gateway"
[ "${FP_AI_ENGINE_ENABLED:-false}" = "true" ] && HEALTH_SVCS="${HEALTH_SVCS} falconpulsar-ai-engine"
[ "${FP_COPILOT_ENABLED:-false}" = "true" ] && HEALTH_SVCS="${HEALTH_SVCS} falconpulsar-copilot"
for svc in $HEALTH_SVCS; do
    if docker ps --filter "name=$svc" --filter "status=running" -q 2>/dev/null | grep -q .; then
        log_success "$svc: running"
    else
        log_warn "$svc: not running yet (may still be starting)"
        HEALTH_OK=false
    fi
done
if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
    if curl -sf "http://127.0.0.1:${FP_COPILOT_PORT}/health" >/dev/null 2>&1; then
        log_success "Command Center: process health on port ${FP_COPILOT_PORT}"
        # Phase 2 — server-side stack links (Core/Gateway/Engine)
        CC_STACK="$(curl -sf "http://127.0.0.1:${FP_COPILOT_PORT}/api/cc/stack-status" 2>/dev/null || true)"
        if [ -n "$CC_STACK" ]; then
            CC_READY="$(printf '%s' "$CC_STACK" | sed -n 's/.*"readyForOps":[[:space:]]*\(true\|false\).*/\1/p' | head -1)"
            CC_CORE="$(printf '%s' "$CC_STACK" | sed -n 's/.*"core":{[^}]*"status":"\([^"]*\)".*/\1/p' | head -1)"
            if [ "$CC_CORE" = "ok" ]; then
                log_success "Command Center → Core: linked"
            else
                log_warn "Command Center → Core: not linked yet (open setup UI or run scripts/validate-stack.sh)"
                log_warn "  Install only starts containers; stack communication is validated next."
            fi
            if [ "$CC_READY" = "true" ]; then
                log_success "Command Center stack links: readyForOps"
            else
                log_warn "Command Center stack links: not fully ready — complete setup in the UI"
            fi
        else
            log_warn "Command Center /api/cc/stack-status unavailable (rebuild image with lifecycle support)"
        fi
    else
        log_warn "Command Center: not responding yet on port ${FP_COPILOT_PORT}"
        HEALTH_OK=false
    fi
fi

if curl -sf "http://localhost:${FP_REST_PORT}/api/v1/health" >/dev/null 2>&1; then
    log_success "REST API: responding on port ${FP_REST_PORT}"
else
    log_warn "REST API: not responding yet (core may still be initializing)"
fi

# Re-probe the gateway /health endpoint. The hard gate in step 7c already
# proved it healthy; this catches a crash after the seed-defaults restart.
if curl -sf "http://127.0.0.1:${FP_GATEWAY_PORT}/health" >/dev/null 2>&1; then
    log_success "AI Gateway: responding on port ${FP_GATEWAY_PORT}"
else
    log_warn "AI Gateway: not responding yet (may still be restarting)"
    HEALTH_OK=false
fi

if [ "$HEALTH_OK" = "false" ]; then
    log_warn "some containers are still starting — they may need a few more seconds"
fi

# ── Done ────────────────────────────────────────────────────────────────────
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"   # || true: a busybox hostname w/o -I must not abort the final success banner
[ -z "$HOST_IP" ] && HOST_IP="localhost"

cat >&2 <<EOF

${FP_C_GREEN}${FP_C_BOLD}╔═══════════════════════════════════════════════════════════════╗
║                FalconPulsar is up and running                 ║
╚═══════════════════════════════════════════════════════════════╝${FP_C_RESET}

  Web UI:    ${FP_C_CYAN}http://${HOST_IP}:${FP_UI_PORT}${FP_C_RESET}
  REST API:  ${FP_C_CYAN}http://${HOST_IP}:${FP_REST_PORT}${FP_C_RESET}
  WebSocket: ${FP_C_CYAN}ws://${HOST_IP}:${FP_WS_PORT}${FP_C_RESET}
$(if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
  printf '  Command Center: %shttp://%s:%s%s\n' "${FP_C_CYAN}" "${HOST_IP}" "${FP_COPILOT_PORT}" "${FP_C_RESET}"
fi)
  Auth mode: ${FP_C_BOLD}${FP_AUTH_MODE:-local}${FP_C_RESET}$(if [ "${FP_SSO_PROVIDER:-none}" != "none" ]; then printf ' (SSO: %s)' "${FP_SSO_PROVIDER}"; fi)

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

  ${FP_C_BOLD}▸ Granting access to additional users${FP_C_RESET}
    The installing user (${FP_C_BOLD}${SUDO_USER:-$FP_USER}${FP_C_RESET}) was added to the
    ${FP_C_BOLD}${FP_USER}${FP_C_RESET} and ${FP_C_BOLD}docker${FP_C_RESET} groups. To give another user the same
    access (read the stack files + run docker commands without sudo):

        sudo usermod -aG ${FP_USER},docker <username>
        # then that user must log out + back in for the groups to apply

    To activate the new groups in your CURRENT shell (no logout):
        newgrp docker        # or open a new terminal

  To uninstall: sudo bash ${SCRIPT_DIR}/uninstall.sh

EOF
