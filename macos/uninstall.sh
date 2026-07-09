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
#     - Remove compose.yml
#     - Remove the menu bar app + LaunchAgent
#     - KEEP ~/falconpulsar/data (database preserved)
#     - KEEP ~/falconpulsar/ai-gateway-data + gateway.yaml (AI conversations,
#       memory, and gateway config preserved)
#     - KEEP ~/falconpulsar/.env — FP_GATEWAY_SECRET must outlive the
#       ai_config.db it encrypts; the installer reuses it on reinstall
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
FP_FORCE=0
FP_LOG_FILE="${FP_LOG_FILE:-/tmp/falconpulsar-install.log}"
export FP_ASSUME_YES="${FP_ASSUME_YES:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --home)   FP_HOME="$2"; shift 2 ;;
        --purge)  FP_PURGE=1; shift ;;
        --keep)   FP_PURGE=0; shift ;;
        -y|--yes) FP_ASSUME_YES=1; shift ;;
        --force)  FP_FORCE=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: uninstall.sh [options]
  --home <path>   Stack directory (default: ~/falconpulsar)
  --purge         Remove everything including database
  --keep          Keep data, remove application only
  --yes, -y       Assume yes to all prompts
  --force         Skip admin authentication (emergency use only)
EOF
            exit 0
            ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# Admin authentication gate — load the shared helper and prompt. Anyone with
# shell access on this machine could otherwise `bash uninstall.sh --purge` and
# wipe the stack, so we require the FalconPulsar admin password first.
# --force bypasses for emergencies (e.g. Core is broken).
if [ "$FP_FORCE" = "1" ]; then
    log_warn "--force supplied: skipping admin authentication"
else
    # Look in several locations so the uninstaller works both when run from
    # the installer repo and when run standalone (dropped into ~/falconpulsar
    # alongside auth.sh at install time).
    AUTH_SH=""
    for candidate in \
        "${SCRIPT_DIR}/auth.sh" \
        "${REPO_ROOT}/shared/lib/auth.sh"; do
        if [ -f "$candidate" ]; then AUTH_SH="$candidate"; break; fi
    done
    if [ -n "$AUTH_SH" ]; then
        # shellcheck disable=SC1090
        . "$AUTH_SH"
        # Capture return code without tripping errexit (set -e).
        auth_rc=0
        fp_authenticate_admin 3 || auth_rc=$?
        case "$auth_rc" in
            0) ;;  # authenticated — continue
            2)
                # Core not reachable. Most likely the user already stopped
                # the stack before uninstalling. We have no way to verify
                # the admin password, so fall back to an explicit bypass
                # confirmation (or allow --yes to imply it for automation).
                if [ "$FP_ASSUME_YES" = "1" ]; then
                    log_warn "Core unreachable — proceeding because --yes was supplied."
                else
                    printf '\n' >&2
                    printf 'FalconPulsar Core is not running, so the admin password cannot be verified.\n' >&2
                    printf 'To authorize this uninstall anyway, type exactly YES (uppercase): ' >&2
                    confirm=''
                    read -r confirm </dev/tty 2>/dev/null || confirm=''
                    if [ "$confirm" != 'YES' ]; then
                        printf '[error] Confirmation not received — aborting.\n' >&2
                        exit 1
                    fi
                fi
                ;;
            *)
                # Any other non-zero: wrong password, user cancelled, too
                # many attempts, or curl missing. Abort without cleanup.
                exit 1
                ;;
        esac
    else
        log_warn "auth.sh not found — proceeding without admin auth"
    fi
fi

# Append a run marker to the install log so the user can see a single
# audit trail of installation + uninstallation. Best-effort only — if the
# log file can't be written to (wrong permissions, disk full, etc.) we do
# NOT let that break the uninstall itself.
#
# Note: earlier versions tried `exec > >(tee -a "$FP_LOG_FILE") 2>&1` to
# capture every subsequent stdout line, but if tee couldn't open the file
# it died and the next write hit SIGPIPE — which, combined with `set -o
# errexit`, aborted the script silently before image/volume cleanup ran.
# Instead we just write explicit begin/end markers and let the rest of
# the script log to the terminal as it always has.
# Rotate if > 5 MiB, ensure 0600 permissions — log contains admin usernames
# and partial error output. Helper defined in shared/lib/common.sh.
if declare -f fp_rotate_log >/dev/null 2>&1; then
    fp_rotate_log "$FP_LOG_FILE"
fi
{
    printf '\n=== %s  uninstall (platform=macos, pid=%d, mode=%s) ===\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$$" \
        "$([ "$FP_PURGE" = "1" ] && echo purge || echo keep)"
} >> "$FP_LOG_FILE" 2>/dev/null || true

# If not specified via flags, ask the user
if [ -z "$FP_PURGE" ]; then
    if [ "$FP_ASSUME_YES" = "1" ]; then
        FP_PURGE=0
    else
        cat >&2 <<'EOF'

What would you like to remove?

  1) Keep data — remove containers, images, and app files but
     KEEP your database at ~/falconpulsar/data, your AI data
     (conversations, memory, gateway config) at
     ~/falconpulsar/ai-gateway-data, and the credentials in
     ~/falconpulsar/.env that unlock it. You can reinstall later
     and your data will be preserved.

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

# Ensure docker is on PATH. When this script is invoked from `fp uninstall`
# (a Go subprocess) or any other launcher that doesn't carry the user's
# interactive PATH, the `docker` command may be missing from $PATH and
# every cleanup command below would fail silently — exactly the bug
# users hit when the uninstall reports success but containers, images,
# and volumes are all still there. Prepend the standard macOS Docker
# locations so we never depend on the caller's PATH.
export PATH="/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"
if ! command -v docker >/dev/null 2>&1; then
    log_warn "docker not found on PATH after PATH augmentation — container/image cleanup will be skipped."
    log_warn "Docker Desktop should be installed and running for a clean uninstall."
fi

# Step 1: Stop the menu bar app
log_step "Stopping FalconPulsar Menu Bar"
pkill -f FalconPulsarMenuBar 2>/dev/null || true
log_info "Menu bar app stopped"

# Step 2: Stop and remove containers (+ volumes on purge)
log_step "Stopping containers"
if [ -f "${FP_HOME}/compose.yml" ]; then
    # NB: stderr is INTENTIONALLY surfaced here. Previous versions had
    # `2>/dev/null` which hid the actual error when docker compose failed,
    # so the user saw "Containers stopped" but nothing was actually removed.
    # --profile ai: legacy compose compat (pre-mandatory-gateway installs
    # kept ai-gateway behind the "ai" profile); no-op on current stacks.
    if [ "$FP_PURGE" = "1" ]; then
        if ( cd "$FP_HOME" && docker compose --profile ai down --remove-orphans --volumes ); then
            log_info "Containers and named volumes removed"
        else
            log_warn "docker compose down failed (see error above) — continuing anyway"
        fi
    else
        if ( cd "$FP_HOME" && docker compose --profile ai down --remove-orphans ); then
            log_info "Containers stopped and removed (volumes preserved)"
        else
            log_warn "docker compose down failed (see error above) — continuing anyway"
        fi
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
    # --profile ai: legacy compose compat (pre-mandatory-gateway installs);
    # without it a legacy compose.yml omits the ai-gateway image from the
    # list. No-op on current stacks.
    IMAGES="$( cd "$FP_HOME" && docker compose --profile ai config --images 2>/dev/null | sort -u )"
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
# Compose currently uses bind mounts only (no named volumes), but earlier
# versions did, and unrelated docker volumes named "falconpulsar*" should be
# removed too. Surface the actual error if rm fails — was hidden before.
if [ "$FP_PURGE" = "1" ]; then
    log_step "Pruning orphan Docker named volumes"
    set +e
    matched=0
    failed=0
    while IFS= read -r vol; do
        [ -z "$vol" ] && continue
        matched=$((matched + 1))
        if docker volume rm -f "$vol"; then
            log_info "removed volume: $vol"
        else
            failed=$((failed + 1))
            log_warn "failed to remove volume: $vol (likely still in use)"
        fi
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar')
    set -e
    if [ "$matched" -eq 0 ]; then
        log_info "no falconpulsar named volumes found (compose uses bind mounts)"
    elif [ "$failed" -eq 0 ]; then
        log_info "all $matched orphan volume(s) removed"
    else
        log_warn "$failed of $matched volumes could not be removed"
    fi
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

# Step 6: Remove installer staging. The install log is NOT removed — it is
# this very run's audit log ($FP_LOG_FILE), finalized and surfaced to the
# user at the end of the script.
rm -rf /tmp/falconpulsar-installer 2>/dev/null || true

# Step 7 (LAST): stack-directory removal. This deletes this script file
# itself when running from ~/falconpulsar, so it MUST be the final step --
# any code after this may not execute if bash was reading line-by-line.
log_step "Removing application files"

# Helper: try `rm -rf`; if it fails with "Operation not permitted" because
# container-owned files have a different UID than the host user, retry
# under sudo. macOS will prompt for the user's password if not already
# cached -- the user explicitly initiated an uninstall so this prompt
# is expected behaviour.
fp_rm_rf() {
    local path="$1"
    [ -z "$path" ] && return 0
    [ ! -e "$path" ] && return 0
    if rm -rf "$path" 2>/tmp/fp-rm-err.$$; then
        return 0
    fi
    local err
    err="$(cat /tmp/fp-rm-err.$$ 2>/dev/null)"
    rm -f /tmp/fp-rm-err.$$
    log_warn "rm failed: $err"
    log_info "retrying with sudo (may prompt for your macOS password)..."
    if sudo rm -rf "$path"; then
        log_info "removed $path with sudo"
        return 0
    fi
    log_warn "sudo rm also failed for $path -- some files may remain"
    return 1
}

if [ "$FP_PURGE" = "1" ]; then
    # Partial cleanup first (files we know are safe) to minimize the amount
    # of work the final `rm -rf` has to do on the doomed directory.
    fp_rm_rf "${FP_HOME:?}/compose.yml"
    fp_rm_rf "${FP_HOME:?}/.env"
    fp_rm_rf "${FP_HOME:?}/.docker"
    fp_rm_rf "${FP_HOME:?}/ai-gateway-data"
    fp_rm_rf "${FP_HOME:?}/gateway.yaml"
    fp_rm_rf "${FP_HOME:?}/bin"
    fp_rm_rf "${FP_HOME:?}/data"
    fp_rm_rf "${FP_HOME:?}"
    if [ -d "${FP_HOME}" ]; then
        log_warn "${FP_HOME} could not be fully removed -- check 'ls -la ${FP_HOME}' for what's left."
    else
        log_info "Deleted ${FP_HOME} (database removed)"
    fi
else
    # ai-gateway-data (AI conversations, memory, knowledge embeddings) and
    # gateway.yaml (operator-edited config) are user data on par with the
    # core database — keep-data mode preserves all of them. .env is kept
    # too (matching the Linux keep semantics): it is 0600, holds no admin
    # password, and carries FP_GATEWAY_SECRET — the key that encrypts the
    # provider API keys inside the preserved ai_config.db. Deleting it
    # would make a reinstall mint a fresh secret and permanently orphan
    # those keys; the installer carries the credentials forward instead.
    fp_rm_rf "${FP_HOME:?}/compose.yml"
    fp_rm_rf "${FP_HOME:?}/.docker"
    fp_rm_rf "${FP_HOME:?}/bin"
    log_info "Application files removed"
    log_info "Database preserved at ${FP_HOME}/data"
    log_info "AI data preserved at ${FP_HOME}/ai-gateway-data"
    log_info "Gateway credentials preserved in ${FP_HOME}/.env"
fi

log_step "Uninstall complete"
if [ "$FP_PURGE" = "0" ] && [ -d "${FP_HOME}/data" ]; then
    echo ""
    echo "  Your database is preserved at: ${FP_HOME}/data"
    if [ -d "${FP_HOME}/ai-gateway-data" ]; then
        echo "  Your AI data is preserved at:  ${FP_HOME}/ai-gateway-data"
    fi
    echo "  Reinstall FalconPulsar to resume using your existing data."
    echo ""
fi

# Close the run marker and surface the full install log so the user has a
# single record of everything that happened (install → uninstall).
printf '=== end ===\n' >> "$FP_LOG_FILE" 2>/dev/null || true
echo ""
echo "  Full log: $FP_LOG_FILE"
if [ "$FP_ASSUME_YES" != "1" ] && command -v open >/dev/null 2>&1; then
    # Best-effort; silently ignore if the user has no default text editor.
    open -t "$FP_LOG_FILE" 2>/dev/null || open "$FP_LOG_FILE" 2>/dev/null || true
fi
