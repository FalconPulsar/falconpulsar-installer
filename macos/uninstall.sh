#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — macOS Uninstaller
# =============================================================================
#
# Two modes (matching the Windows uninstaller):
#
#   Keep data (default):
#     - Stop and remove containers
#     - Remove Docker images
#     - Remove compose.yml and .env
#     - Remove the menu bar app + LaunchAgent
#     - KEEP ~/falconpulsar/data (database preserved)
#
#   Full removal (--purge):
#     - Everything above, plus:
#     - Delete ~/falconpulsar entirely (database, config, all data)
#
# Usage:
#   bash uninstall.sh                # interactive — asks what to remove
#   bash uninstall.sh --purge --yes  # delete everything, no prompts
#   bash uninstall.sh --yes          # keep data, no prompts
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared/lib/common.sh
if [ -f "${REPO_ROOT}/shared/lib/common.sh" ]; then
    . "${REPO_ROOT}/shared/lib/common.sh"
else
    # Standalone mode — minimal logging
    log_step()        { echo ""; echo "==> $1"; }
    log_info()        { echo "[info] $1"; }
    log_success()     { echo "[ok] $1"; }
    log_warn()        { echo "[warn] $1"; }
    log_error()       { echo "[error] $1" >&2; }
    die()             { log_error "$1"; exit 1; }
    confirm()         { return 0; }
    require_not_root(){ [ "$(id -u)" -ne 0 ] || die "don't run as root"; }
    on_error()        { log_error "failed at line $1"; }
fi

trap 'on_error $LINENO 2>/dev/null || true' ERR

FP_HOME="${FP_HOME:-${HOME}/falconpulsar}"
FP_PURGE=""
export FP_ASSUME_YES="${FP_ASSUME_YES:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --home)   FP_HOME="$2"; shift 2 ;;
        --purge)  FP_PURGE=1; shift ;;
        --keep)   FP_PURGE=0; shift ;;
        -y|--yes) FP_ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: uninstall.sh [options]
  --home <path>   Stack directory (default: ~/falconpulsar)
  --purge         Remove everything including database
  --keep          Keep data, remove application only
  --yes, -y       Assume yes to all prompts
EOF
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# If not specified via flags, ask the user
if [ -z "$FP_PURGE" ]; then
    if [ "$FP_ASSUME_YES" = "1" ]; then
        FP_PURGE=0
    else
        cat >&2 <<'EOF'

What would you like to remove?

  1) Keep data — remove containers, images, and app files but
     KEEP your database at ~/falconpulsar/data. You can reinstall
     later and your data will be preserved.

  2) Remove everything — delete containers, images, database,
     configuration, and all files. This cannot be undone.

  3) Cancel — do nothing.

EOF
        while :; do
            printf 'Choose [1/2/3]: ' >&2
            read -r choice || choice=''
            case "$choice" in
                1) FP_PURGE=0; break ;;
                2) FP_PURGE=1; break ;;
                3) echo "Cancelled."; exit 0 ;;
                *) log_warn "please answer 1, 2, or 3" ;;
            esac
        done
    fi
fi

if [ ! -d "$FP_HOME" ]; then
    log_warn "${FP_HOME} does not exist — nothing to uninstall"
fi

# Make sure our cwd is NOT inside $FP_HOME before any rm happens. Also guards
# against deleting-script-while-reading when bash was invoked with a relative
# path from inside $FP_HOME.
cd "$HOME" 2>/dev/null || cd /

# Step 1: Stop the menu bar app
log_step "Stopping FalconPulsar Menu Bar"
pkill -f FalconPulsarMenuBar 2>/dev/null || true
log_info "Menu bar app stopped"

# Step 2: Stop and remove containers (+ volumes on purge)
log_step "Stopping containers"
if [ -f "${FP_HOME}/compose.yml" ]; then
    if [ "$FP_PURGE" = "1" ]; then
        # --volumes removes named volumes declared in compose.yml
        ( cd "$FP_HOME" && docker compose down --remove-orphans --volumes 2>/dev/null ) || \
            log_warn "docker compose down failed — continuing anyway"
        log_info "Containers and named volumes removed"
    else
        ( cd "$FP_HOME" && docker compose down --remove-orphans 2>/dev/null ) || \
            log_warn "docker compose down failed — continuing anyway"
        log_info "Containers stopped and removed (volumes preserved)"
    fi
else
    log_info "No compose.yml found — skipping"
fi

# Step 3: Remove Docker images (query compose first, then fall back to known names)
log_step "Removing Docker images"
# Entire block is wrapped in `set +e` because Docker/compose edge cases
# (no images, context switch, empty `xargs` input) return non-zero under
# errexit+pipefail even when each result is fine. We re-enable errexit
# after the block so later steps still abort on real errors.
set +e
if [ -f "${FP_HOME}/compose.yml" ]; then
    IMAGES="$( cd "$FP_HOME" && docker compose config --images 2>/dev/null | sort -u )"
    if [ -n "$IMAGES" ]; then
        echo "$IMAGES" | while IFS= read -r img; do
            [ -n "$img" ] && docker rmi -f "$img" >/dev/null 2>&1
        done
    fi
fi
# Fallback: remove any falconpulsar/* images left over from older installs.
# No `xargs -r` here — BSD/macOS xargs doesn't support it; we loop instead.
docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
    grep -E '^falconpulsar/' | while IFS= read -r img; do
    [ -n "$img" ] && docker rmi -f "$img" >/dev/null 2>&1
done
set -e
log_info "Docker images removed"

# Step 3b (purge only): prune any orphan volumes whose names match falconpulsar*
if [ "$FP_PURGE" = "1" ]; then
    log_step "Pruning orphan volumes"
    set +e
    docker volume ls --format '{{.Name}}' 2>/dev/null | \
        grep -E '^falconpulsar' | while IFS= read -r vol; do
        [ -n "$vol" ] && docker volume rm -f "$vol" >/dev/null 2>&1
    done
    set -e
    log_info "Orphan volumes removed"
fi

# Step 4: Remove the menu bar app
log_step "Removing Menu Bar app"
rm -rf "${HOME}/Applications/FalconPulsar Menu Bar.app" 2>/dev/null || true
rm -rf "/Applications/FalconPulsar Menu Bar.app" 2>/dev/null || true
log_info "Menu bar app removed"

# Step 5: Remove LaunchAgent (auto-start)
log_step "Removing auto-start"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/com.falconpulsar.menubar.plist"
if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
    log_info "LaunchAgent removed"
else
    log_info "No LaunchAgent found"
fi

# Step 6: Remove installer staging
rm -rf /tmp/falconpulsar-installer 2>/dev/null || true
rm -f /tmp/falconpulsar-install.log 2>/dev/null || true

# Step 7 (LAST): stack-directory removal. This deletes this script file
# itself when running from ~/falconpulsar, so it MUST be the final step —
# any code after this may not execute if bash was reading line-by-line.
log_step "Removing application files"
if [ "$FP_PURGE" = "1" ]; then
    # Partial cleanup first (files we know are safe) to minimize the amount
    # of work `rm -rf` has to do on the doomed directory.
    rm -f "${FP_HOME}/compose.yml" "${FP_HOME}/.env" 2>/dev/null || true
    rm -rf "${FP_HOME}/.docker" "${FP_HOME}/ai-gateway-data" "${FP_HOME}/bin" 2>/dev/null || true
    rm -rf "$FP_HOME"
    log_info "Deleted ${FP_HOME} (database removed)"
else
    rm -f "${FP_HOME}/compose.yml" 2>/dev/null || true
    rm -f "${FP_HOME}/.env" 2>/dev/null || true
    rm -rf "${FP_HOME}/.docker" 2>/dev/null || true
    rm -rf "${FP_HOME}/ai-gateway-data" 2>/dev/null || true
    rm -rf "${FP_HOME}/bin" 2>/dev/null || true
    log_info "Application files removed"
    log_info "Database preserved at ${FP_HOME}/data"
fi

log_step "Uninstall complete"
if [ "$FP_PURGE" = "0" ] && [ -d "${FP_HOME}/data" ]; then
    echo ""
    echo "  Your database is preserved at: ${FP_HOME}/data"
    echo "  Reinstall FalconPulsar to resume using your existing data."
    echo ""
fi
