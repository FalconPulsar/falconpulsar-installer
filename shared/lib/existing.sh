# shellcheck shell=bash
# =============================================================================
#  Existing-installation detection + Upgrade/Reinstall/Fresh prompt.
#
#  Same UX as the macOS SwiftUI installer. Sources the normal log_* / confirm
#  helpers from common.sh.
#
#  Exposes:
#    fp_detect_existing_install <home>     # populates FP_EXISTING_* vars
#    fp_prompt_existing_action <home>      # sets FP_INSTALL_ACTION = upgrade|reinstall|fresh|cancel
#    fp_apply_existing_action <home>       # performs the chosen pre-install steps
# =============================================================================

FP_EXISTING_STACK_DIR=0
FP_EXISTING_DATA_DIR=0
FP_EXISTING_COMPOSE=0
FP_EXISTING_ENV=0
FP_EXISTING_CONTAINERS=0
FP_EXISTING_IMAGES=0
FP_EXISTING_MENUBAR=0
FP_EXISTING_STACK_SIZE=""
FP_EXISTING_DATA_SIZE=""

fp_detect_existing_install() {
    local home="$1"

    [ -d "$home" ]                && FP_EXISTING_STACK_DIR=1
    [ -d "${home}/data" ]         && FP_EXISTING_DATA_DIR=1
    [ -f "${home}/compose.yml" ]  && FP_EXISTING_COMPOSE=1
    [ -f "${home}/.env" ]         && FP_EXISTING_ENV=1

    if [ -d "$home" ]; then
        FP_EXISTING_STACK_SIZE="$(du -sh "$home" 2>/dev/null | awk '{print $1}')"
    fi
    if [ -d "${home}/data" ]; then
        FP_EXISTING_DATA_SIZE="$(du -sh "${home}/data" 2>/dev/null | awk '{print $1}')"
    fi

    if command -v docker >/dev/null 2>&1; then
        local count
        count="$(docker ps -a --filter name=falconpulsar- --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
        FP_EXISTING_CONTAINERS="${count:-0}"
        count="$(docker images --filter reference='*falconpulsar*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | wc -l | tr -d ' ')"
        FP_EXISTING_IMAGES="${count:-0}"
    fi

    if [ -d "/Applications/FalconPulsar Menu Bar.app" ]; then
        FP_EXISTING_MENUBAR=1
    fi
}

# Detect a real prior install. An empty stack dir alone does NOT count —
# `useradd --create-home falconpulsar` creates `/home/falconpulsar` on Linux,
# which is not an install artifact. We require at least one of:
#   - compose.yml or .env (the install actually wrote files)
#   - a falconpulsar container or image present in Docker
#   - the menu bar app on macOS
fp_has_existing_install() {
    [ "${FP_EXISTING_COMPOSE}" = "1" ] || \
    [ "${FP_EXISTING_ENV}" = "1" ] || \
    [ "${FP_EXISTING_CONTAINERS:-0}" -gt 0 ] || \
    [ "${FP_EXISTING_IMAGES:-0}" -gt 0 ] || \
    [ "${FP_EXISTING_MENUBAR}" = "1" ]
}

fp_print_existing_inventory() {
    printf '\n%sWe detected an existing FalconPulsar installation:%s\n' \
        "${FP_C_BOLD}" "${FP_C_RESET}" >&2
    if [ "${FP_EXISTING_STACK_DIR}" = "1" ]; then
        printf '  ● Stack directory: %s' "$1" >&2
        [ -n "$FP_EXISTING_STACK_SIZE" ] && printf ' (%s)' "$FP_EXISTING_STACK_SIZE" >&2
        printf '\n' >&2
    fi
    if [ "${FP_EXISTING_DATA_DIR}" = "1" ]; then
        printf '  ● %sDatabase:%s %s/data' "${FP_C_YELLOW}" "${FP_C_RESET}" "$1" >&2
        [ -n "$FP_EXISTING_DATA_SIZE" ] && printf ' (%s — preserved unless you choose Fresh)' "$FP_EXISTING_DATA_SIZE" >&2
        printf '\n' >&2
    fi
    if [ "${FP_EXISTING_CONTAINERS:-0}" -gt 0 ]; then
        printf '  ● Containers: %s\n' "$FP_EXISTING_CONTAINERS" >&2
    fi
    if [ "${FP_EXISTING_IMAGES:-0}" -gt 0 ]; then
        printf '  ● Cached images: %s\n' "$FP_EXISTING_IMAGES" >&2
    fi
    if [ "${FP_EXISTING_MENUBAR}" = "1" ]; then
        printf '  ● Menu bar app: installed\n' >&2
    fi
    printf '\n' >&2
}

fp_prompt_existing_action() {
    local home="$1"
    FP_INSTALL_ACTION="${FP_INSTALL_ACTION:-}"

    # If caller explicitly set the action via env, honor it.
    if [ -n "$FP_INSTALL_ACTION" ]; then
        log_info "using FP_INSTALL_ACTION=$FP_INSTALL_ACTION"
        return 0
    fi

    fp_print_existing_inventory "$home"

    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        FP_INSTALL_ACTION="upgrade"
        log_info "FP_ASSUME_YES=1 — defaulting to Upgrade in place"
        export FP_INSTALL_ACTION
        return 0
    fi

    printf '%sWhat would you like to do?%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
    printf '  %s1%s) %sUpgrade in place%s — pull latest images, restart. Keeps data + settings.\n' \
        "${FP_C_CYAN}" "${FP_C_RESET}" "${FP_C_BOLD}" "${FP_C_RESET}" >&2
    printf '  %s2%s) %sReinstall (keep data)%s — recreate stack files. Database preserved.\n' \
        "${FP_C_CYAN}" "${FP_C_RESET}" "${FP_C_BOLD}" "${FP_C_RESET}" >&2
    printf '  %s3%s) %sFresh install%s — %sDELETES ALL DATA%s. Irreversible.\n' \
        "${FP_C_CYAN}" "${FP_C_RESET}" "${FP_C_BOLD}" "${FP_C_RESET}" "${FP_C_RED}" "${FP_C_RESET}" >&2
    printf '  %s4%s) Cancel\n\n' "${FP_C_CYAN}" "${FP_C_RESET}" >&2

    local answer
    while :; do
        printf 'Choose [1-4, default 1]: ' >&2
        read -r answer
        case "${answer:-1}" in
            1) FP_INSTALL_ACTION="upgrade";   break ;;
            2) FP_INSTALL_ACTION="reinstall"; break ;;
            3) FP_INSTALL_ACTION="fresh";     break ;;
            4) FP_INSTALL_ACTION="cancel";    break ;;
            *) printf '%sPlease enter 1, 2, 3, or 4.%s\n' "${FP_C_YELLOW}" "${FP_C_RESET}" >&2 ;;
        esac
    done

    if [ "$FP_INSTALL_ACTION" = "cancel" ]; then
        log_info "cancelled by user"
        exit 0
    fi

    # Fresh install requires a type-to-confirm — same UX as the macOS installer
    if [ "$FP_INSTALL_ACTION" = "fresh" ]; then
        printf '\n%sYou chose Fresh install. This will PERMANENTLY DELETE%s %s/data %sand all images/volumes.%s\n' \
            "${FP_C_RED}" "${FP_C_RESET}" "$home" "${FP_C_RED}" "${FP_C_RESET}" >&2
        printf 'Type %sDELETE%s (uppercase) to confirm: ' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        local confirm_text
        read -r confirm_text
        if [ "$confirm_text" != "DELETE" ]; then
            log_error "confirmation did not match — aborting"
            exit 1
        fi
    fi

    export FP_INSTALL_ACTION
}

fp_apply_existing_action() {
    local home="$1"
    case "${FP_INSTALL_ACTION:-}" in
        upgrade)
            log_info "Upgrade in place — keeping existing compose.yml, .env, and data"
            # Tell the installer to skip overwriting files that already exist.
            export FP_SKIP_COMPOSE_WRITE=1
            ;;
        reinstall)
            log_info "Reinstall — stopping containers, rewriting stack files, preserving data"
            if [ -f "${home}/compose.yml" ]; then
                ( cd "$home" && docker compose --profile ai down 2>/dev/null ) || true
            fi
            ;;
        fresh)
            log_info "Fresh install — removing everything"
            if [ -f "${home}/compose.yml" ]; then
                ( cd "$home" && docker compose --profile ai down --remove-orphans --volumes 2>/dev/null ) || true
            fi
            # Best-effort image + orphan volume cleanup
            if command -v docker >/dev/null 2>&1; then
                docker images --filter reference='*falconpulsar*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
                    while IFS= read -r img; do
                    if [ -n "$img" ]; then
                        docker rmi -f "$img" >/dev/null 2>&1 || true
                    fi
                done
                docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar' | \
                    while IFS= read -r vol; do
                    if [ -n "$vol" ]; then
                        docker volume rm -f "$vol" >/dev/null 2>&1 || true
                    fi
                done
            fi
            if [ -n "$home" ] && [ "$home" != "/" ]; then
                rm -rf "${home:?}"
            fi
            ;;
        *)
            # No existing install detected — no action needed.
            ;;
    esac
}

# Upgrade fast-path: when the user chose "upgrade" AND the existing compose.yml
# is intact, skip the full install and just pull+recreate. Returns 0 if it
# completed the upgrade (caller should exit success); 1 if not applicable.
#
# Re-verifies registry access before pulling so expired credentials surface
# as a clean re-auth prompt rather than as a generic pull failure several
# retries later. Without this step, an upgrade against a private registry
# whose token rotated since the original install would fail with a noisy
# "manifest unknown" / "unauthorized" error from `docker compose pull`,
# and the operator would have no obvious path to fix it. By calling
# `fp_registry_ensure_access` first the operator gets the same auth UX
# they had at install time.
fp_try_upgrade_fastpath() {
    local home="$1"
    if [ "${FP_INSTALL_ACTION:-}" != "upgrade" ]; then return 1; fi
    if [ ! -f "${home}/compose.yml" ]; then return 1; fi

    # Re-probe the registry. The function is sourced from registry_auth.sh
    # by the install.sh entry points (linux/install.sh + macos/install.sh).
    # In the rare case it isn't available (caller invoked us directly with
    # a stripped environment), fall through to the pull and let it surface
    # whatever the underlying docker error is.
    if declare -f fp_registry_ensure_access >/dev/null 2>&1; then
        if ! fp_registry_ensure_access; then
            log_error "registry access could not be established; aborting upgrade"
            return 1
        fi
    fi

    log_step "Upgrade in place: pulling latest images"
    if declare -f fp_compose_pull_with_retry >/dev/null 2>&1; then
        fp_compose_pull_with_retry "$home" || return 1
    else
        ( cd "$home" && docker compose pull ) || return 1
    fi
    log_step "Upgrade in place: recreating containers"
    ( cd "$home" && docker compose up -d ) || return 1
    return 0
}
