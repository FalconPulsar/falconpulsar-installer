#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

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
#   5. Pull images, start the stack, bootstrap the AI gateway service token
#   6. Wait for the core + AI gateway healthchecks and print connection details
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

# Snapshot operator-provided registry overrides BEFORE the sources below —
# registry_auth.sh defaults FP_REGISTRY/FP_VERSION at source time, and the
# reinstall .env seeding further down must be able to tell an explicit
# operator choice from that fallback.
FP_REGISTRY_FROM_ENV="${FP_REGISTRY:-}"
FP_VERSION_FROM_ENV="${FP_VERSION:-}"

# Same idea for the AI Engine choice: prompt_ai_engine (prompts.sh) skips
# its question entirely when the operator pre-set FP_AI_ENGINE_ENABLED in
# the environment, while a value merely seeded from a surviving .env
# further down only flips the prompt's default. Snapshot explicitness
# before the defaults / carry-forward fill the variable in.
# shellcheck disable=SC2034  # consumed by prompt_* in prompts.sh; a
# directive covers one command, so the group extends it to all four
{
    FP_AI_ENGINE_ENABLED_EXPLICIT="${FP_AI_ENGINE_ENABLED:+1}"
    FP_COPILOT_ENABLED_EXPLICIT="${FP_COPILOT_ENABLED:+1}"
    FP_AUTH_MODE_EXPLICIT="${FP_AUTH_MODE:+1}"
    FP_SSO_PROVIDER_EXPLICIT="${FP_SSO_PROVIDER:+1}"
}

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
# Layout and port settings deliberately stay unset here unless the
# environment (or a flag below) provides them: on a reinstall they are
# first seeded from the existing install's .env, and the hard defaults are
# applied only after that — see the seeding block before the port check.
FP_HOME="${FP_HOME:-${HOME}/falconpulsar}"
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
        --home)        FP_HOME="$2"; shift 2 ;;
        --data-dir)    FP_DATA_DIR="$2"; shift 2 ;;
        --rest-port)   FP_REST_PORT="$2"; shift 2 ;;
        --ui-port)     FP_UI_PORT="$2"; shift 2 ;;
        --engine-port) FP_ENGINE_PORT="$2"; shift 2 ;;
        --public-host) FP_PUBLIC_HOST="$2"; shift 2 ;;
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
# Note on ordering: the port check used to run here and aborted with
# `die "port conflict"` if any FalconPulsar port was bound. That made
# re-running the installer impossible whenever a previous install's own
# containers were still running. The port check now runs later (after
# the existing-install block stops our own containers and a phantom-
# container sweep removes orphans from prior installs) so it only flags
# genuinely-external conflicts, and offers remap-or-abort instead of dying.
log_step "step 1/6 — pre-flight checks"
check_supported_os
check_arch
check_ram
check_disk "$HOME"

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
# Read-only at this point: inventory + the menu choice only. The teardown
# the choice implies (fp_apply_existing_action), the admin auth gate and
# the upgrade fast-path all run AFTER the legal acknowledgement below —
# no system mutation happens before Legal.
log_step "checking for existing installation"
fp_detect_existing_install "$FP_HOME"
if fp_has_existing_install; then
    fp_prompt_existing_action "$FP_HOME"
else
    log_info "no existing install detected — proceeding with fresh install"
fi

# ── Legal acknowledgement (must come before any system change) ──────────────
# Skipped for an in-place upgrade (alpha.47 parity with the GUI installers):
# the terms were accepted at install, and the upgrade fast-path only pulls +
# restarts. If the fast-path FALLS THROUGH to the full installer, the
# acknowledgement is collected at that point instead (see below).
if [ "${FP_INSTALL_ACTION:-}" != "upgrade" ]; then
    prompt_legal_acknowledgement
fi

# ── Existing installation: authorize + apply the chosen action ─────────────
# The Upgrade/Reinstall/Fresh choice was collected before Legal (read-only
# inventory + menu above). Its side effects happen here, with Legal
# accepted.
if fp_has_existing_install; then
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
    # Upgrades are exempt (alpha.48 parity): an in-place upgrade neither
    # creates an admin nor destroys data, and both the tray's Apply Now and
    # `fp update --apply` already perform the identical operation with no
    # password. Reinstall keeps the gate — it rewrites the stack files over
    # a running install.
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

    # BEFORE the fast-path, because the fast-path runs `compose up -d` and
    # then exits — it never reaches the stack-directory step below. An
    # upgrade over a stack whose bind sources Docker had auto-created would
    # otherwise pull new images, restart, and come back just as broken.
    fp_repair_bind_sources "$FP_HOME"

    # Fast-path: if the user picked Upgrade and the stack dir is intact,
    # skip everything else and just pull+recreate.
    if fp_try_upgrade_fastpath "$FP_HOME"; then
        log_success "Upgrade complete."
        fp_install_cli "$FP_HOME" "${FP_VERSION:-0.1.0}"
        exit 0
    fi

    # The fast-path fell through to the FULL installer, which reconfigures
    # the stack — collect the Legal acknowledgement that the upgrade path
    # skipped above (still honors FP_LEGAL_ACCEPTED / --yes for headless).
    if [ "${FP_INSTALL_ACTION:-}" = "upgrade" ]; then
        prompt_legal_acknowledgement
    fi
fi

# ── Carry sticky settings forward from the existing .env ───────────────────
# The full flow rewrites .env from this shell's values, so on a reinstall
# (or an upgrade that fell through from the fast-path) anything not re-read
# here silently reverts to defaults: a custom data dir comes back as
# ${FP_HOME}/data (core re-inits an empty database while the real one sits
# orphaned at the custom path), remapped ports revert to 7433/…/8080, and a
# pinned FP_VERSION jumps to "latest". Seed unset settings from the
# existing .env before the port check below so the ports being verified are
# the ones the stack will actually use. Explicit flags and operator-set
# environment values always win — only unset settings are seeded.
fp_seed_from_existing_env() {
    local var="$1" val
    [ -n "${!var:-}" ] && return 0
    # tr: tolerate CRLF line endings from a hand-edited / restored .env.
    # tail -n1: last occurrence wins, matching docker compose's env-file
    # semantics, so a hand-appended override seeds the same value the
    # stack actually runs with.
    val="$(grep "^${var}=" "${FP_HOME}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    [ -n "$val" ] || return 0
    printf -v "$var" '%s' "$val"
    log_info "carried ${var}=${val} forward from existing .env"
}
if [ -f "${FP_HOME}/.env" ]; then
    # FP_AI_ENGINE_ENABLED is deliberately NOT carried forward: the engine is
    # a standard service now and the value is force-set true below. (Matches
    # linux/install.sh — keep the two lists identical.)
    for setting in FP_DATA_DIR FP_GATEWAY_DATA_DIR FP_ENGINE_DATA_DIR FP_COPILOT_DATA_DIR \
                   FP_COPILOT_ENABLED FP_COPILOT_PORT \
                   FP_AUTH_MODE FP_SSO_PROVIDER \
                   FP_REST_PORT FP_WS_PORT FP_PUBSUB_PORT FP_GATEWAY_PORT FP_UI_PORT \
                   FP_ENGINE_PORT FP_PUBLIC_HOST \
                   FP_COOKIE_SECURE FP_UPDATE_MODE; do
        fp_seed_from_existing_env "$setting"
    done
    # FP_REGISTRY/FP_VERSION were already defaulted when registry_auth.sh
    # was sourced above — consult the pre-source snapshot so the values
    # recorded in .env win over that fallback (but never over an operator
    # override), and the registry probe below validates the same
    # registry:tag the pull will use.
    if [ -z "$FP_REGISTRY_FROM_ENV" ]; then
        FP_REGISTRY=""
        fp_seed_from_existing_env FP_REGISTRY
        FP_REGISTRY="${FP_REGISTRY:-falconpulsar}"
    fi
    if [ -z "$FP_VERSION_FROM_ENV" ]; then
        FP_VERSION=""
        fp_seed_from_existing_env FP_VERSION
        FP_VERSION="${FP_VERSION:-latest}"
    fi
fi
# Hard defaults for whatever is still unset (fresh install, sparse .env).
FP_DATA_DIR="${FP_DATA_DIR:-${FP_HOME}/data}"
FP_GATEWAY_DATA_DIR="${FP_GATEWAY_DATA_DIR:-${FP_HOME}/ai-gateway-data}"
# Optional AI Engine (author/simulate/deploy agents). Off by default; its
# config + agent state live in the SAME main folder as Core/Gateway.
FP_ENGINE_DATA_DIR="${FP_ENGINE_DATA_DIR:-${FP_HOME}/ai-engine-data}"
# AI Engine is now a STANDARD service (always installed). Force-enabled so the
# fp console / tray / update-check surfaces always show it (Command Center is
# the only optional opt-in now).
FP_AI_ENGINE_ENABLED="true"
# Optional Command Center — always define path under FP_HOME (like Engine).
FP_COPILOT_DATA_DIR="${FP_COPILOT_DATA_DIR:-${FP_HOME}/copilot-data}"
# Command Center is the shell's Workplace mode, so it is installed by default
# now rather than opted into. The shell shows Home, Workplace and Agents as
# one switcher; leaving Copilot out gave a default install a mode that opened
# to nothing. Still removable with FP_COPILOT_ENABLED=false, but note that
# Workplace is not gated on reachability the way Agents is: it stays in the
# switcher and opens to an unavailable surface.
FP_COPILOT_ENABLED="${FP_COPILOT_ENABLED:-true}"
FP_COPILOT_PORT="${FP_COPILOT_PORT:-8090}"
FP_AUTH_MODE="${FP_AUTH_MODE:-local}"
FP_SSO_PROVIDER="${FP_SSO_PROVIDER:-none}"
FP_SSO_ISSUER="${FP_SSO_ISSUER:-}"
FP_SSO_CLIENT_ID="${FP_SSO_CLIENT_ID:-}"
# Command Center is the only profile-gated optional module; AI Engine is now a
# standard service (no compose profile).
COMPOSE_PROFILES=""
if [ "${FP_COPILOT_ENABLED}" = "true" ]; then COMPOSE_PROFILES="copilot"; fi
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
# host the browser cannot reach, both modes are blank rectangles.
FP_PUBLIC_HOST="${FP_PUBLIC_HOST:-localhost}"

# ── Phantom-container sweep ─────────────────────────────────────────────────
# Same problem the Linux installer solves: containers from a previous
# install whose stack directory has been removed manually (or whose
# FP_HOME differs from the one we're about to write to) don't show up
# in fp_detect_existing_install but are still running and holding our
# ports. Surface + offer to remove BEFORE the port check.
log_step "checking for orphaned containers from previous installs"
if fp_detect_phantom_containers "$FP_HOME"; then
    fp_handle_phantom_containers
else
    log_success "no orphaned FalconPulsar containers found"
fi

# ── Port check (smart, recoverable) ─────────────────────────────────────────
# Runs after the existing-install block has stopped our own containers
# (and after the phantom sweep). Anything still on an FP port is
# external — the prompt lets the user remap our port, re-check, or
# abort instead of dying outright.
log_step "verifying required TCP ports are free"
fp_check_ports_interactive FP_REST_PORT FP_WS_PORT FP_PUBSUB_PORT FP_GATEWAY_PORT FP_UI_PORT FP_ENGINE_PORT

# Container registry — wizard-style prompt (parity with the Linux installer
# and the Mac SwiftUI RegistryPage / Windows Inno Setup RegistryPage).
# Collects URL + optional credentials + optional skip + does a live "test
# connection" probe BEFORE the installer commits to anything. After this
# returns, fp_registry_ensure_access is effectively a no-op safety net.
#
# Skipped automatically (no prompt) when FP_ASSUME_YES=1 or when
# FP_REGISTRY_SKIP was pre-set in the environment (CI, headless installs,
# parent installer).
fp_registry_prompt_settings

# Verify we can pull images from the configured registry. After
# fp_registry_prompt_settings above, this is usually a no-op; it's kept as
# a safety net for non-interactive runs that supplied bad env credentials.
fp_registry_ensure_access

# Options: front-door HTTPS, auth mode, optional modules, then admin.
prompt_transport_mode
prompt_auth_mode
prompt_copilot
if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
    fp_check_ports_interactive FP_COPILOT_PORT
fi
prompt_admin_credentials

# ── Step 3: Stack directory ─────────────────────────────────────────────────
log_step "step 3/6 — stack directory"
# Same layout as Linux: all module data under $FP_HOME.
mkdir -p "$FP_HOME" "$FP_DATA_DIR" "$FP_GATEWAY_DATA_DIR"
# Optional modules: create only when enabled.
[ "$FP_AI_ENGINE_ENABLED" = "true" ] && mkdir -p "$FP_ENGINE_DATA_DIR"
FP_COPILOT_DATA_DIR="${FP_COPILOT_DATA_DIR:-${FP_HOME}/copilot-data}"
if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
    mkdir -p "$FP_COPILOT_DATA_DIR"
    log_info "Command Center data dir: ${FP_COPILOT_DATA_DIR}"
fi
# Repair anything Docker auto-created as a bind-mount source before it is
# mounted again. See fp_repair_bind_sources in shared/lib/common.sh for the
# full reasoning: a missing bind source becomes a ROOT-OWNED DIRECTORY
# whatever the destination is, which crash-loops the engine on
# "EACCES mkdir /data/db" and fails every mount of auth-policy.json with
# "not a directory". One shared implementation, both platforms.
fp_repair_bind_sources "$FP_HOME"


# Stack config files in FP_HOME (gateway.yaml pattern), not inside module data.
fp_write_auth_policy "${FP_HOME}/auth-policy.json"
log_success "${FP_HOME} ready"

# ── Step 4: compose.yml + .env ──────────────────────────────────────────────
log_step "step 4/6 — stack files"

cp "${REPO_ROOT}/shared/compose.yml" "${FP_HOME}/compose.yml"
cp "${REPO_ROOT}/shared/nginx.conf" "${FP_HOME}/nginx.conf"

# Repair a Docker artifact first: if the stack was ever started while
# gateway.yaml was missing, Docker created a DIRECTORY at the bind-mount
# point. [ ! -f ] below is false for a directory, so the default config
# would never land and the gateway would crash-loop on it forever.
if [ -d "${FP_HOME}/gateway.yaml" ]; then
    rm -rf "${FP_HOME}/gateway.yaml"
    log_warn "removed directory at ${FP_HOME}/gateway.yaml (Docker bind-mount artifact)"
fi

# Copy the AI Gateway config if it doesn't already exist (operator edits
# survive reinstalls). The compose ai-gateway service bind-mounts this file
# read-only, so a missing source is fatal — Docker would otherwise create a
# directory named gateway.yaml at the mount point.
if [ ! -f "${FP_HOME}/gateway.yaml" ]; then
    [ -f "${REPO_ROOT}/shared/gateway.yaml" ] || \
        die "gateway.yaml missing from installer payload (${REPO_ROOT}/shared/gateway.yaml) — cannot configure the AI gateway"
    cp "${REPO_ROOT}/shared/gateway.yaml" "${FP_HOME}/gateway.yaml"
    log_info "copied default gateway.yaml"
fi

# On macOS, FP_UID = the current user's UID. The compose.yml uses this to set
# the container's process UID so bind-mounted files are owned correctly on
# the host side.
FP_UID="$(id -u)"
FP_GID="$(id -g)"

# Carry secrets forward from a pre-existing .env (reinstall path). The .env
# is rewritten from scratch below, so anything not re-emitted is lost — and
# these must never be silently regenerated while the data directories they
# guard survive: FP_GATEWAY_SECRET encrypts the LLM provider keys stored in
# the preserved ai_config.db (rotating it orphans them), FP_API_KEY is the
# gateway's service token (still valid in the preserved core database).
# Operator-set environment values win.
OLD_FP_GATEWAY_SECRET=""
OLD_FP_API_KEY=""
if [ -f "${FP_HOME}/.env" ]; then
    OLD_FP_GATEWAY_SECRET="$(grep -m1 '^FP_GATEWAY_SECRET=' "${FP_HOME}/.env" | cut -d= -f2- || true)"
    OLD_FP_API_KEY="$(grep -m1 '^FP_API_KEY=' "${FP_HOME}/.env" | cut -d= -f2- || true)"
    if [ -z "${FP_BRIDGE_TOKEN:-}" ]; then
        FP_BRIDGE_TOKEN="$(grep -m1 '^FP_BRIDGE_TOKEN=' "${FP_HOME}/.env" | cut -d= -f2- || true)"
        if [ -n "${FP_BRIDGE_TOKEN}" ]; then
            log_info "preserved FP_BRIDGE_TOKEN from existing .env"
        fi
    fi
    if [ -z "${FP_CONFIRM_SECRET:-}" ]; then
        FP_CONFIRM_SECRET="$(grep -m1 '^FP_CONFIRM_SECRET=' "${FP_HOME}/.env" | cut -d= -f2- || true)"
        if [ -n "${FP_CONFIRM_SECRET}" ]; then
            log_info "preserved FP_CONFIRM_SECRET from existing .env"
        fi
    fi
fi

# A carried-forward FP_API_KEY is only valid against the core database it
# was minted in. When that database does not survive into this install
# (data dir missing or empty — core's first-run init will build a fresh
# one), drop the token so the bootstrap mint runs; keeping it would
# suppress the mint and leave the gateway healthy-but-unauthorized
# against core. FP_GATEWAY_SECRET is still carried: it encrypts provider
# keys in the gateway's own database, which lives elsewhere.
if [ -n "${OLD_FP_API_KEY}" ] && \
   { [ ! -d "${FP_DATA_DIR}" ] || [ -z "$(ls -A "${FP_DATA_DIR}" 2>/dev/null)" ]; }; then
    log_warn "found FP_API_KEY in the old .env but no surviving database in ${FP_DATA_DIR} — a new gateway service token will be minted"
    OLD_FP_API_KEY=""
fi

# SEC-001: Generate (or preserve) FP_BRIDGE_TOKEN.
# Shared secret core ↔ ai-gateway use on /api/v1/bridge/* calls. The
# gateway's AuthMiddleware rejects bridge calls without a matching
# X-FP-Internal-Token header. Operator-set value is honoured if present,
# as is the value carried forward from a pre-existing .env above.
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

# Shared secret the AI Engine uses to post an incident runbook's report into
# a Command Center room. Same lifecycle as the two above: reuse what the
# existing .env holds, generate once otherwise. A missing key is not fatal —
# the Copilot simply refuses machine posts and reports stay on the timeline.
if [ -z "${FP_CC_MACHINE_KEY:-}" ]; then
    if [ -f "${FP_HOME}/.env" ]; then
        FP_CC_MACHINE_KEY="$(sed -n 's/^FP_CC_MACHINE_KEY=//p' "${FP_HOME}/.env" | head -n1)"
    fi
fi
if [ -z "${FP_CC_MACHINE_KEY:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        FP_CC_MACHINE_KEY="$(openssl rand -hex 32)"
    elif [ -r /dev/urandom ]; then
        FP_CC_MACHINE_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        die "cannot generate FP_CC_MACHINE_KEY: neither openssl nor /dev/urandom available"
    fi
    log_info "generated FP_CC_MACHINE_KEY (32 random bytes, hex)"
fi

# .env — note that the admin password is INTENTIONALLY not stored here.
# It is held in shell memory and passed via the parent environment to
# `docker compose up -d core` for the first-run init only. After that
# the FP_API_KEY (AI gateway service token) and FP_BRIDGE_TOKEN are
# the secrets in here; bootstrap.sh appends FP_API_KEY after the API
# comes up.
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
FP_COPILOT_ENABLED=${FP_COPILOT_ENABLED}
FP_COPILOT_PORT=${FP_COPILOT_PORT}
FP_COPILOT_DATA_DIR=${FP_COPILOT_DATA_DIR}
FP_COPILOT_IMAGE_TAG=${FP_COPILOT_IMAGE_TAG:-${FP_VERSION:-latest}}
COMPOSE_PROFILES=${COMPOSE_PROFILES}
FP_AUTH_MODE=${FP_AUTH_MODE}
FP_SSO_PROVIDER=${FP_SSO_PROVIDER}
FP_SSO_ISSUER=${FP_SSO_ISSUER}
FP_SSO_CLIENT_ID=${FP_SSO_CLIENT_ID}
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
# Browser-visible host for the shell and the two surfaces it embeds.
FP_PUBLIC_HOST=${FP_PUBLIC_HOST}
FP_LOG_LEVEL=${FP_LOG_LEVEL}
# AI Capabilities are a mandatory component; this key exists only so older
# fp / menu-bar binaries that still read it stay on the enabled path.
FP_AI_GATEWAY_ENABLED=true
# Host path of the gateway config bind-mounted into the ai-gateway
# container. Pinned explicitly so a custom --data-dir cannot break the
# mount (compose defaults it relative to FP_DATA_DIR).
FP_GATEWAY_CONFIG=${FP_HOME}/gateway.yaml
# SEC-001: shared secret read by both core and ai-gateway containers.
# Rotate by overwriting this value and 'docker compose up -d'.
FP_BRIDGE_TOKEN=${FP_BRIDGE_TOKEN}
# HMAC secret for AI Gateway write-confirmation IDs (multi-worker).
FP_CONFIRM_SECRET=${FP_CONFIRM_SECRET}
FP_CC_MACHINE_KEY=${FP_CC_MACHINE_KEY}
# Front-door HTTPS declaration — see the equivalent block in
# linux/install.sh for the full rationale.
FP_COOKIE_SECURE=${FP_COOKIE_SECURE:-true}
# Update mode for the tray apps — see the equivalent block in
# linux/install.sh for the full rationale. Default "manual"; the
# tray app's settings UI or 'fp update mode' flips it.
FP_UPDATE_MODE=${FP_UPDATE_MODE:-manual}
EOF

# Re-emit the gateway secrets carried forward above so bootstrap.sh's
# generate-only-when-absent logic is a no-op on reinstall.
if [ -n "${OLD_FP_GATEWAY_SECRET}" ]; then
    printf 'FP_GATEWAY_SECRET=%s\n' "${OLD_FP_GATEWAY_SECRET}" >>"${FP_HOME}/.env"
    log_info "preserved FP_GATEWAY_SECRET from existing .env"
fi
if [ -n "${OLD_FP_API_KEY}" ]; then
    printf 'FP_API_KEY=%s\n' "${OLD_FP_API_KEY}" >>"${FP_HOME}/.env"
    log_info "preserved FP_API_KEY from existing .env"
fi

# SEC-003: ensure the provider-key encryption secret exists independently
# of the token mint in step 5b — a carried-forward FP_API_KEY skips the
# mint (where bootstrap.sh normally generates the secret), which would
# leave pre-SEC-003 installs storing provider API keys in plaintext.
# Generate only when absent: rotating orphans already-encrypted keys.
if ! grep -q '^FP_GATEWAY_SECRET=.' "${FP_HOME}/.env"; then
    if command -v openssl >/dev/null 2>&1; then
        NEW_FP_GATEWAY_SECRET="$(openssl rand -hex 32)"
    elif [ -r /dev/urandom ]; then
        NEW_FP_GATEWAY_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        die "cannot generate FP_GATEWAY_SECRET: neither openssl nor /dev/urandom available"
    fi
    printf 'FP_GATEWAY_SECRET=%s\n' "${NEW_FP_GATEWAY_SECRET}" >>"${FP_HOME}/.env"
    unset NEW_FP_GATEWAY_SECRET
    log_info "generated FP_GATEWAY_SECRET (SEC-003: encrypts provider API keys at rest)"
fi

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
# `|| die` keeps errexit from firing inside the helper — without it the
# first transient pull failure aborts the install before the retry loop runs.
fp_compose_pull_with_retry "$FP_HOME" || die "image pull failed after retries"

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

# 5b. Create the AI gateway service token via REST API. A carried-forward
# FP_API_KEY (reinstall) is kept as-is — it is still valid in the preserved
# database, and re-minting would leave an orphaned service token behind.
if grep -q '^FP_API_KEY=.' "${FP_HOME}/.env" 2>/dev/null; then
    log_info "existing gateway service token found in .env — skipping mint"
else
    fp_bootstrap_gateway_token "${FP_HOME}/.env"
fi

# 5c. Start the rest of the stack.
# Record whether the gateway database predates this run BEFORE the stack
# starts. If it does, the catalog holds user-configured providers/models
# (API keys encrypted under the preserved FP_GATEWAY_SECRET), not the
# image's self-seeded defaults — the wipe below must not touch it.
GATEWAY_DB_PREEXISTS=0
if [ -f "${FP_GATEWAY_DATA_DIR}/ai_config.db" ]; then
    GATEWAY_DB_PREEXISTS=1
fi
log_info "starting ui and ai-gateway"
( cd "$FP_HOME" && docker compose up -d )
# Hard gate: the AI Gateway is a mandatory component — an install whose
# gateway never becomes healthy is a failed install, not a warning.
fp_wait_for_gateway_ready "${FP_GATEWAY_PORT}" || \
    die "AI Gateway did not become healthy. Check: docker logs falconpulsar-ai-gateway"
# Wipe the gateway's self-seeded provider/model catalog so the user
# lands on a clean AI configuration page — only when the gateway DB was
# created by this run (fresh install / legacy opt-out migration). See
# bootstrap.sh for the full rationale + the upstream fix this stops
# being necessary after.
if [ "$GATEWAY_DB_PREEXISTS" = "0" ]; then
    fp_wipe_gateway_seed_defaults
fi

# 5d. Install the fp CLI into ${FP_HOME}/bin/ and optionally add to PATH.
fp_install_cli "$FP_HOME" "${FP_VERSION:-0.1.0}"
fp_offer_path_append "$FP_HOME"

# ── Step 6: Done ────────────────────────────────────────────────────────────
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

# Command Center verification — mirrors linux/install.sh so both platforms
# report the same thing: process health, then the server-side stack links.
if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
    if curl -sf "http://127.0.0.1:${FP_COPILOT_PORT}/health" >/dev/null 2>&1; then
        log_success "Command Center: process health on port ${FP_COPILOT_PORT}"
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
$(if [ "${FP_COPILOT_ENABLED:-false}" = "true" ]; then
  printf '  Command Center: %shttp://localhost:%s%s\n' "${FP_C_CYAN}" "${FP_COPILOT_PORT}" "${FP_C_RESET}"
fi)
  Auth mode: ${FP_C_BOLD}${FP_AUTH_MODE:-local}${FP_C_RESET}$(if [ "${FP_SSO_PROVIDER:-none}" != "none" ]; then printf ' (SSO: %s)' "${FP_SSO_PROVIDER}"; fi)

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
