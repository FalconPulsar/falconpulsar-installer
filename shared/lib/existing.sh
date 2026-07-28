# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

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
        FP_EXISTING_STACK_SIZE="$(du -sh "$home" 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [ -d "${home}/data" ]; then
        FP_EXISTING_DATA_SIZE="$(du -sh "${home}/data" 2>/dev/null | awk '{print $1}' || true)"
    fi

    # Probe docker FUNCTIONALLY (docker info), not just `command -v docker`.
    # On WSL with Docker Desktop but its WSL-integration DISABLED, a docker
    # SHIM sits on PATH: `command -v docker` finds it, but every invocation
    # prints "could not be found in this WSL 2 distro" and exits non-zero.
    # Under `set -o pipefail`+`errexit` that made `count="$(docker ps ...|wc)"`
    # abort the whole installer here ("checking for existing installation").
    # The `|| true` also keeps a transient docker hiccup from aborting.
    if docker info >/dev/null 2>&1; then
        local count
        count="$( { docker ps -a --filter name=falconpulsar- --format '{{.Names}}' 2>/dev/null || true; } | wc -l | tr -d ' ')"
        FP_EXISTING_CONTAINERS="${count:-0}"
        count="$( { docker images --filter reference='*falconpulsar*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true; } | wc -l | tr -d ' ')"
        FP_EXISTING_IMAGES="${count:-0}"
    fi

    if [ -d "/Applications/FalconPulsar Menu Bar.app" ]; then
        FP_EXISTING_MENUBAR=1
    fi
}

# ── Phantom-container detection ─────────────────────────────────────────────
#
# A "phantom" is a docker container the install would collide with:
#
#   (a) ORPHAN — name starts with `falconpulsar-`, carries the compose
#       project label `com.docker.compose.project=falconpulsar`, but its
#       working_dir no longer holds a compose.yml (the user removed the
#       stack dir while the container kept running).
#
#   (b) NAME CONFLICT — a container holding one of the stack's RESERVED
#       container names (the container_name values in shared/compose.yml)
#       that our compose project does NOT own: e.g. started with a plain
#       `docker run --name falconpulsar-core ...` (dev setups, pre-compose
#       install methods). `docker compose up` cannot start while the name
#       is taken, and these containers typically publish our standard
#       ports too — so the install is doomed either way.
#
# Why detect them: they hold our reserved names/ports, but
# fp_detect_existing_install misses both cases because there's no
# compose.yml to find (a) or no compose labels at all (b). Without this
# check the user hits "port 7433 in use" with no obvious way out.
#
# Containers merely PREFIXED `falconpulsar-` that carry neither our
# project label nor a reserved name (e.g. a user's own falconpulsar-doc)
# are deliberately left alone — they don't block the stack.
#
# Populates the FP_PHANTOM_CONTAINERS array as "name|origin" entries.
# Returns 0 if any phantom was found, 1 otherwise.

# Container names the stack claims — keep in sync with the
# `container_name:` fields in shared/compose.yml.
# falconpulsar-ai-engine belongs here too: it is an opt-in module with a fixed
# container_name, so a label-less copy (e.g. one started via `docker run`, or a
# previous non-compose launch) holds the name and makes `compose up` abort with
# "container name is already in use" — while a project-scoped `compose down`
# cannot see it. Its omission is exactly what let that orphan slip past phantom
# detection and break the upgrade.
FP_RESERVED_CONTAINER_NAMES="falconpulsar-core falconpulsar-ui falconpulsar-ai-gateway falconpulsar-ai-engine falconpulsar-copilot"

FP_PHANTOM_CONTAINERS=()
fp_detect_phantom_containers() {
    FP_PHANTOM_CONTAINERS=()
    # Functional check (see fp_detect_existing_install): a WSL docker shim
    # passes `command -v` but fails on use, and phantom detection runs docker.
    docker info >/dev/null 2>&1 || return 1

    local target_home="$1"
    local name project workdir reserved is_reserved
    while IFS=$'\t' read -r name project workdir; do
        [ -z "$name" ] && continue

        is_reserved=0
        for reserved in $FP_RESERVED_CONTAINER_NAMES; do
            [ "$name" = "$reserved" ] && is_reserved=1 && break
        done

        if [ "$project" = "falconpulsar" ]; then
            # Ours by label. If it belongs to the install we're targeting
            # it's not a phantom — fp_apply_existing_action handles it via
            # the normal upgrade/reinstall/fresh path.
            if [ -n "$target_home" ] && [ "$workdir" = "$target_home" ]; then
                continue
            fi
            # Orphan = working_dir is gone or has no compose.yml.
            if [ -z "$workdir" ] || [ ! -d "$workdir" ] || [ ! -f "${workdir}/compose.yml" ]; then
                FP_PHANTOM_CONTAINERS+=("${name}|orphaned from: ${workdir:-(no working_dir label)}")
            fi
        elif [ "$is_reserved" = "1" ]; then
            # Reserved name held by something our compose project doesn't
            # own — `compose up` would fail on the name even if the ports
            # were somehow free.
            FP_PHANTOM_CONTAINERS+=("${name}|name conflict — not created by this installer${project:+ (compose project: ${project})}")
        fi
    done < <(
        docker ps -a \
            --filter "name=falconpulsar-" \
            --format '{{.Names}}'$'\t''{{.Label "com.docker.compose.project"}}'$'\t''{{.Label "com.docker.compose.project.working_dir"}}' \
            2>/dev/null
    )

    [ "${#FP_PHANTOM_CONTAINERS[@]}" -gt 0 ]
}

# fp_handle_phantom_containers
#
# If FP_PHANTOM_CONTAINERS has entries (i.e. fp_detect_phantom_containers
# returned 0), prompt the user. On "stop", remove each phantom with
# `docker rm -f`. Honoured env: FP_ASSUME_YES=1 → auto-remove (the
# alternative is dying on the port check that immediately follows, so
# silent cleanup is the only sensible non-interactive behaviour).
fp_handle_phantom_containers() {
    [ "${#FP_PHANTOM_CONTAINERS[@]}" -gt 0 ] || return 0

    log_warn ""
    log_warn "Found docker containers that hold FalconPulsar's reserved container"
    log_warn "names and/or ports but do not belong to this install. They will"
    log_warn "break the install if left in place:"
    local entry
    for entry in "${FP_PHANTOM_CONTAINERS[@]}"; do
        printf '    %s   (%s)\n' "${entry%%|*}" "${entry##*|}" >&2
    done
    printf '\n' >&2
    log_warn "Removing a container does not delete its data volumes."

    local do_remove=0
    if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
        do_remove=1
        log_info "FP_ASSUME_YES=1 — removing conflicting containers"
    elif confirm "Stop and remove these containers?" default-yes; then
        do_remove=1
    fi

    if [ "$do_remove" = "1" ]; then
        for entry in "${FP_PHANTOM_CONTAINERS[@]}"; do
            local cname="${entry%%|*}"
            if docker rm -f "$cname" >/dev/null 2>&1; then
                log_success "removed conflicting container ${cname}"
            else
                log_warn "could not remove ${cname} — it may need manual cleanup"
            fi
        done
        FP_PHANTOM_CONTAINERS=()
    else
        log_warn "keeping them — the port-conflict prompt below will surface them again"
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
        read -r answer || answer=''   # EOF (piped/closed stdin) -> '' -> default 1, not an errexit abort
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
        read -r confirm_text || confirm_text=''   # EOF -> '' != DELETE -> safe abort, not an errexit crash
        if [ "$confirm_text" != "DELETE" ]; then
            log_error "confirmation did not match — aborting"
            exit 1
        fi

        # Parity with the Mac SwiftUI / Windows Inno-Setup "Remove cached
        # images" toggle. Defaults to true (matches prior Linux behaviour),
        # but the user can opt to keep the images so a re-install pulls
        # from the local layer cache rather than the network.
        # Honours --keep-cached-images / --remove-cached-images flags and
        # FP_REMOVE_CACHED_IMAGES env (true|false) for unattended runs.
        if [ -z "${FP_REMOVE_CACHED_IMAGES:-}" ]; then
            if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
                FP_REMOVE_CACHED_IMAGES=true
            elif confirm "Also remove cached FalconPulsar Docker images? (saves space, slower next install)" default-yes; then
                FP_REMOVE_CACHED_IMAGES=true
            else
                FP_REMOVE_CACHED_IMAGES=false
            fi
        fi
        export FP_REMOVE_CACHED_IMAGES
    fi

    export FP_INSTALL_ACTION
}

fp_apply_existing_action() {
    local home="$1"
    case "${FP_INSTALL_ACTION:-}" in
        upgrade)
            log_info "Upgrade in place — keeping existing data and settings"
            ;;
        reinstall)
            log_info "Reinstall — stopping containers, rewriting stack files, preserving data"
            if [ -f "${home}/compose.yml" ]; then
                # --profile ai --profile engine: a --profile flag REPLACES the
                # .env COMPOSE_PROFILES, so both must be named to pull every
                # gated service into the `down` model — "ai" for legacy
                # pre-mandatory-gateway stacks, "engine" for the optional
                # ai-engine (without it the engine is left Up, stranding the
                # network and blocking the recreate below).
                ( cd "$home" && docker compose --profile ai --profile engine --profile copilot down 2>/dev/null ) || true
            fi
            ;;
        fresh)
            log_info "Fresh install — removing everything"
            if [ -f "${home}/compose.yml" ]; then
                # --profile ai --profile engine: see the reinstall note above —
                # both profiles so the ai-engine is torn down too.
                ( cd "$home" && docker compose --profile ai --profile engine --profile copilot down --remove-orphans --volumes 2>/dev/null ) || true
            fi
            # Best-effort image + orphan volume cleanup.
            # Image removal is gated by FP_REMOVE_CACHED_IMAGES so the user
            # can keep them cached locally for a faster re-install.
            # Volumes are always purged — keeping them with FP_INSTALL_ACTION=fresh
            # would leave stale data behind that contradicts the "fresh" choice.
            if docker info >/dev/null 2>&1; then   # functional, not a broken shim
                if [ "${FP_REMOVE_CACHED_IMAGES:-true}" != "false" ]; then
                    docker images --filter reference='*falconpulsar*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
                        while IFS= read -r img; do
                        if [ -n "$img" ]; then
                            docker rmi -f "$img" >/dev/null 2>&1 || true
                        fi
                    done
                else
                    log_info "keeping cached FalconPulsar images (FP_REMOVE_CACHED_IMAGES=false)"
                fi
                # `|| true`: grep exits 1 when no name matches (the standard
                # product has NO named falconpulsar volumes -- only bind mounts
                # -- so this is the common case). Under errexit+pipefail an
                # unguarded no-match would ABORT the teardown here, AFTER the
                # compose-down + image removal above but BEFORE the rm -rf below
                # -- destroying data and then dying half-done.
                { docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^falconpulsar' || true; } | \
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
# is intact, skip the full install and just migrate+pull+recreate. Returns 0 if
# it completed the upgrade (caller should exit success); 1 if not applicable.
#
# Besides pulling images, the fast-path migrates legacy installs to the
# mandatory AI Gateway: it refreshes the product-managed stack files
# (compose.yml, nginx.conf), provisions gateway.yaml and the gateway
# secrets when missing (existing secrets are always carried forward,
# never regenerated), and hard-gates on the gateway's health endpoint.
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

    # ── Stack-file migration ────────────────────────────────────────────
    # compose.yml and nginx.conf are product-managed: re-copy the bundled
    # versions so the upgraded stack matches the images being pulled (in
    # particular, legacy compose.yml files gated ai-gateway behind the
    # retired "ai" compose profile). gateway.yaml is user-editable, so it
    # is only provisioned when missing. REPO_ROOT is set by the
    # install.sh entry points that source this file.
    log_step "Upgrade in place: refreshing stack files"
    local shared_dir="${REPO_ROOT:-}/shared"
    if [ -f "${shared_dir}/compose.yml" ]; then
        # Preserve the stack files' ownership across the copy — on Linux
        # the installer runs as root but the stack dir belongs to the
        # falconpulsar user. stat flags differ between GNU and BSD.
        local stack_owner
        stack_owner=$(stat -c '%U:%G' "${home}/compose.yml" 2>/dev/null || stat -f '%Su:%Sg' "${home}/compose.yml" 2>/dev/null || echo "")
        cp "${shared_dir}/compose.yml" "${home}/compose.yml" \
            || die "could not refresh ${home}/compose.yml"
        if [ -f "${shared_dir}/nginx.conf" ]; then
            cp "${shared_dir}/nginx.conf" "${home}/nginx.conf" \
                || die "could not refresh ${home}/nginx.conf"
        fi
        # A broken earlier install can leave gateway.yaml as a DIRECTORY:
        # docker auto-creates missing bind-mount sources as directories, so
        # a compose up that ran before the config existed plants one. The
        # [ ! -f ] below is false for a directory, so the default config
        # would never land and the gateway would crash-loop on the
        # directory mount forever. Clear it so the refresh can write the
        # real file (same repair as the full-install paths).
        if [ -d "${home}/gateway.yaml" ]; then
            log_warn "${home}/gateway.yaml is a directory (docker auto-created it on a broken install) — removing it"
            rm -rf "${home}/gateway.yaml"
        fi
        if [ ! -f "${home}/gateway.yaml" ] && [ -f "${shared_dir}/gateway.yaml" ]; then
            # tr instead of cp: strip Windows CRLF on the way in — the
            # gateway's YAML loader crash-loops on \r bytes (see the same
            # defensive scrub in linux/install.sh).
            tr -d '\r' < "${shared_dir}/gateway.yaml" > "${home}/gateway.yaml" \
                || die "could not write ${home}/gateway.yaml"
            log_info "copied default gateway.yaml"
        fi
        # Defensive: also strip CRLF from a pre-existing gateway.yaml —
        # pre-fix Windows/WSL installs shipped one with \r line endings,
        # which crash-loop the gateway's YAML loader (same repair as the
        # full-install path). tr through a temp file rather than `sed -i`:
        # this file also runs on macOS/BSD. The chmod/chown below restore
        # mode and ownership after the rewrite.
        if [ -f "${home}/gateway.yaml" ] \
           && grep -q "$(printf '\r')" "${home}/gateway.yaml" 2>/dev/null; then
            if ! tr -d '\r' < "${home}/gateway.yaml" > "${home}/gateway.yaml.tmp" \
               || ! mv "${home}/gateway.yaml.tmp" "${home}/gateway.yaml"; then
                die "could not scrub CRLF from ${home}/gateway.yaml"
            fi
            log_info "stripped CRLF line endings from existing gateway.yaml"
        fi
        chmod 0644 "${home}/compose.yml" "${home}/nginx.conf" "${home}/gateway.yaml" 2>/dev/null || true
        if [ -n "$stack_owner" ]; then
            chown "$stack_owner" "${home}/compose.yml" "${home}/nginx.conf" "${home}/gateway.yaml" 2>/dev/null || true
        fi
    else
        log_warn "bundled stack files not found under ${shared_dir} — keeping the existing compose.yml"
    fi

    # ── .env migration ──────────────────────────────────────────────────
    # The existing .env is edited in place, never rewritten, so secrets
    # (FP_API_KEY / FP_GATEWAY_SECRET / FP_BRIDGE_TOKEN) always carry
    # forward. Only missing pieces are provisioned.
    if [ -f "${home}/.env" ]; then
        # Legacy .env compat: scrub FP_AI_GATEWAY_ENABLED=false left by
        # the retired opt-out prompt. Current code never reads the key,
        # but older fp / tray binaries still do — force it true so they
        # treat the now-mandatory gateway as part of the stack.
        if grep -q '^FP_AI_GATEWAY_ENABLED=' "${home}/.env" \
           && ! grep -q '^FP_AI_GATEWAY_ENABLED=true$' "${home}/.env"; then
            local env_content
            env_content=$(sed 's/^FP_AI_GATEWAY_ENABLED=.*/FP_AI_GATEWAY_ENABLED=true/' "${home}/.env")
            printf '%s\n' "$env_content" > "${home}/.env"
            log_info "set FP_AI_GATEWAY_ENABLED=true in .env (AI Capabilities are a mandatory component)"
        fi
        # Legacy .env compat: the AI Engine used to be an opt-in module
        # behind compose profile "engine". It is now a STANDARD service
        # (no profile), so compose starts it regardless — but every
        # consumer that still gates on the flag (fp console, both trays,
        # and the copilot service's FP_ENGINE_REQUIRED) would hide it
        # while it runs. Force the recorded value true on upgrade.
        if grep -q '^FP_AI_ENGINE_ENABLED=' "${home}/.env" \
           && ! grep -q '^FP_AI_ENGINE_ENABLED=true$' "${home}/.env"; then
            local eng_env_content
            eng_env_content=$(sed 's/^FP_AI_ENGINE_ENABLED=.*/FP_AI_ENGINE_ENABLED=true/' "${home}/.env")
            printf '%s\n' "$eng_env_content" > "${home}/.env"
            log_info "set FP_AI_ENGINE_ENABLED=true in .env (the AI Engine is now a standard component)"
        elif ! grep -q '^FP_AI_ENGINE_ENABLED=' "${home}/.env"; then
            printf 'FP_AI_ENGINE_ENABLED=true\n' >> "${home}/.env"
            log_info "added FP_AI_ENGINE_ENABLED=true to .env (the AI Engine is now a standard component)"
        fi
        # SEC-001: legacy installs that skipped the gateway have no bridge
        # secret. Generate one only when absent — both core and ai-gateway
        # read it, and they pick it up on the recreate below.
        if ! grep -q '^FP_BRIDGE_TOKEN=.' "${home}/.env"; then
            local bridge_token
            if command -v openssl >/dev/null 2>&1; then
                bridge_token="$(openssl rand -hex 32)"
            else
                bridge_token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            fi
            printf 'FP_BRIDGE_TOKEN=%s\n' "$bridge_token" >> "${home}/.env"
            log_info "generated FP_BRIDGE_TOKEN (32 random bytes, hex)"
        fi
        if ! grep -q '^FP_CONFIRM_SECRET=.' "${home}/.env"; then
            local confirm_secret
            if command -v openssl >/dev/null 2>&1; then
                confirm_secret="$(openssl rand -hex 32)"
            else
                confirm_secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            fi
            printf 'FP_CONFIRM_SECRET=%s\n' "$confirm_secret" >> "${home}/.env"
            log_info "generated FP_CONFIRM_SECRET (32 random bytes, hex)"
        fi
        # Anchor the gateway.yaml mount to the stack dir — compose's
        # default resolves relative to FP_DATA_DIR, which breaks for
        # legacy installs created with a custom --data-dir (Docker would
        # bind-mount an auto-created directory over the config file).
        # Same pin the fresh installers write; only added when absent so
        # an operator-set custom path carries forward.
        if ! grep -q '^FP_GATEWAY_CONFIG=' "${home}/.env"; then
            printf 'FP_GATEWAY_CONFIG=%s/gateway.yaml\n' "$home" >> "${home}/.env"
            log_info "anchored FP_GATEWAY_CONFIG to ${home}/gateway.yaml"
        fi
        # The gateway's bind-mounted data dir must exist before `up -d`,
        # otherwise the Docker engine auto-creates it root-owned and the
        # gateway process (running as FP_UID:FP_GID) cannot write its
        # databases. Mirror compose.yml's default when .env has no
        # explicit FP_GATEWAY_DATA_DIR.
        local gw_data_dir
        gw_data_dir="$(sed -n 's/^FP_GATEWAY_DATA_DIR=//p' "${home}/.env" | head -n1)"
        if [ -z "$gw_data_dir" ]; then
            local data_dir
            data_dir="$(sed -n 's/^FP_DATA_DIR=//p' "${home}/.env" | head -n1)"
            [ -n "$data_dir" ] && gw_data_dir="${data_dir}/../ai-gateway-data"
        fi
        if [ -n "$gw_data_dir" ] && [ ! -d "$gw_data_dir" ]; then
            mkdir -p "$gw_data_dir" || die "could not create ${gw_data_dir}"
            local env_uid env_gid
            env_uid="$(sed -n 's/^FP_UID=//p' "${home}/.env" | head -n1)"
            env_gid="$(sed -n 's/^FP_GID=//p' "${home}/.env" | head -n1)"
            if [ -n "$env_uid" ] && [ -n "$env_gid" ]; then
                chown "${env_uid}:${env_gid}" "$gw_data_dir" 2>/dev/null || true
            fi
            log_info "created AI Gateway data directory: ${gw_data_dir}"
        fi
        # Same treatment for the AI Engine's bind mount: the engine is now
        # a standard service, so a legacy install that had declined it has
        # no ai-engine-data dir — Docker would auto-create it root-owned
        # and the container (running as FP_UID:FP_GID) could not write.
        local eng_data_dir
        eng_data_dir="$(sed -n 's/^FP_ENGINE_DATA_DIR=//p' "${home}/.env" | head -n1)"
        if [ -z "$eng_data_dir" ]; then
            local eng_base_dir
            eng_base_dir="$(sed -n 's/^FP_DATA_DIR=//p' "${home}/.env" | head -n1)"
            [ -n "$eng_base_dir" ] && eng_data_dir="${eng_base_dir}/../ai-engine-data"
        fi
        if [ -n "$eng_data_dir" ] && [ ! -d "$eng_data_dir" ]; then
            mkdir -p "$eng_data_dir" || die "could not create ${eng_data_dir}"
            local eng_uid eng_gid
            eng_uid="$(sed -n 's/^FP_UID=//p' "${home}/.env" | head -n1)"
            eng_gid="$(sed -n 's/^FP_GID=//p' "${home}/.env" | head -n1)"
            if [ -n "$eng_uid" ] && [ -n "$eng_gid" ]; then
                chown "${eng_uid}:${eng_gid}" "$eng_data_dir" 2>/dev/null || true
            fi
            log_info "created AI Engine data directory: ${eng_data_dir}"
        fi
        # Command Center's data dir + the auth-policy.json the refreshed
        # compose.yml bind-mounts read-only into it. Only when opted in:
        # without the file Docker auto-creates a DIRECTORY at that path and
        # copilot crash-loops (same failure mode as gateway.yaml above).
        if grep -q '^FP_COPILOT_ENABLED=true' "${home}/.env" 2>/dev/null; then
            local cop_data_dir
            cop_data_dir="$(sed -n 's/^FP_COPILOT_DATA_DIR=//p' "${home}/.env" | head -n1)"
            [ -z "$cop_data_dir" ] && cop_data_dir="${home}/copilot-data"
            if [ ! -d "$cop_data_dir" ]; then
                mkdir -p "$cop_data_dir" || die "could not create ${cop_data_dir}"
                local cop_uid cop_gid
                cop_uid="$(sed -n 's/^FP_UID=//p' "${home}/.env" | head -n1)"
                cop_gid="$(sed -n 's/^FP_GID=//p' "${home}/.env" | head -n1)"
                if [ -n "$cop_uid" ] && [ -n "$cop_gid" ]; then
                    chown "${cop_uid}:${cop_gid}" "$cop_data_dir" 2>/dev/null || true
                fi
                log_info "created Command Center data directory: ${cop_data_dir}"
            fi
            if [ -d "${home}/auth-policy.json" ]; then
                log_warn "${home}/auth-policy.json is a directory (docker auto-created it) — removing it"
                rm -rf "${home}/auth-policy.json"
            fi
            if [ ! -f "${home}/auth-policy.json" ]; then
                if declare -f fp_write_auth_policy >/dev/null 2>&1; then
                    fp_write_auth_policy "${home}/auth-policy.json"
                else
                    printf '{\n  "version": 1,\n  "authMode": "local",\n  "ssoProvider": "none",\n  "ssoIssuer": "",\n  "ssoClientId": "",\n  "breakGlassLocalAdmin": true,\n  "notes": "Local break-glass admin always exists. Finish SSO mapping in Web UI Config Hub when ready."\n}\n' \
                        > "${home}/auth-policy.json"
                fi
                chmod 0644 "${home}/auth-policy.json" 2>/dev/null || true
                log_info "provisioned ${home}/auth-policy.json for Command Center"
            fi
        fi
    fi

    # Snapshot the image IDs each compose service currently resolves to,
    # BEFORE the pull. We use these IDs as the cleanup whitelist after the
    # upgrade succeeds — only images that were "ours" prior to the upgrade
    # are candidates for removal, and only if they are now untagged
    # (i.e. the pull brought a newer version that displaced them).
    #
    # This is registry-agnostic: it doesn't care whether the images came
    # from Docker Hub, a private registry, GHCR, a mirror, or an air-gapped
    # tarball — only "was this image ID ours immediately before the pull?"
    # matters. It also can't accidentally touch unrelated images on the
    # operator's machine (which a label-based `docker image prune` could
    # if the label is missing or stripped by a registry).
    local prev_image_ids=""
    local svc current_image
    # --profile ai on every compose invocation below: legacy compose
    # compat (pre-mandatory-gateway installs gated ai-gateway behind the
    # profile, and the stack-file refresh above can be skipped when the
    # bundle is incomplete); a no-op on current compose.yml files.
    #
    # --profile copilot is added when the surviving .env opted into Command
    # Center. A --profile flag on the CLI *REPLACES* COMPOSE_PROFILES from
    # .env (see the note in fp_apply_existing_action), so without naming it
    # here the upgrade would pull+recreate every service EXCEPT copilot,
    # leaving Command Center running the pre-upgrade image. AI Engine needs
    # no profile — it is a standard service.
    local _fp_profiles="--profile ai"
    if grep -q '^FP_COPILOT_ENABLED=true' "${home}/.env" 2>/dev/null; then
        _fp_profiles="${_fp_profiles} --profile copilot"
    fi
    if cd "$home" 2>/dev/null; then
        # shellcheck disable=SC2086  # word-splitting of the flag list is intended
        for svc in $(docker compose $_fp_profiles config --services 2>/dev/null); do
            # shellcheck disable=SC2086
            current_image=$(docker compose $_fp_profiles images -q "$svc" 2>/dev/null | head -1 || true)
            if [ -n "$current_image" ]; then
                prev_image_ids="${prev_image_ids} ${current_image}"
            fi
        done
        cd - >/dev/null 2>&1 || true
    fi

    log_step "Upgrade in place: pulling latest images"
    if declare -f fp_compose_pull_with_retry >/dev/null 2>&1; then
        fp_compose_pull_with_retry "$home" || return 1
    else
        # shellcheck disable=SC2086
        ( cd "$home" && docker compose $_fp_profiles pull ) || return 1
    fi
    log_step "Upgrade in place: recreating containers"
    # shellcheck disable=SC2086
    ( cd "$home" && docker compose $_fp_profiles up -d ) || return 1

    # ── Gateway bootstrap for migrated installs ─────────────────────────
    # Legacy installs that declined the (formerly optional) AI Gateway
    # have no FP_API_KEY — the service token the gateway authenticates
    # against core with. Minting one requires an admin login, so prompt
    # for credentials when they weren't supplied via the environment.
    # Existing tokens are never touched.
    local bootstrapped_gateway=0 ai_setup_incomplete=0
    if [ -f "${home}/.env" ] && ! grep -q '^FP_API_KEY=.' "${home}/.env" \
       && declare -f fp_bootstrap_gateway_token >/dev/null 2>&1; then
        if { [ -z "${FP_ADMIN_USER:-}" ] || [ -z "${FP_ADMIN_PASS:-}" ]; } \
           && [ "${FP_ASSUME_YES:-0}" != "1" ] && [ -r /dev/tty ]; then
            printf '\nThe AI Gateway needs a one-time service token, which requires an admin login.\n' >&2
            printf 'Admin username [admin]: ' >&2
            read -r FP_ADMIN_USER </dev/tty || FP_ADMIN_USER=''
            [ -z "$FP_ADMIN_USER" ] && FP_ADMIN_USER='admin'
            printf 'Admin password: ' >&2
            stty -echo </dev/tty 2>/dev/null || true
            read -r FP_ADMIN_PASS </dev/tty || FP_ADMIN_PASS=''
            stty echo </dev/tty 2>/dev/null || true
            printf '\n' >&2
            export FP_ADMIN_USER FP_ADMIN_PASS
        fi
        if [ -n "${FP_ADMIN_USER:-}" ] && [ -n "${FP_ADMIN_PASS:-}" ]; then
            # Mint against the port the stack actually publishes: the
            # .env remap wins over FP_REST_PORT pre-defaulted (unexported)
            # by the installer shell — same precedence as gw_port below.
            local rest_port
            rest_port="$(sed -n 's/^FP_REST_PORT=//p' "${home}/.env" | head -n1)"
            FP_REST_PORT="${rest_port:-${FP_REST_PORT:-7433}}" \
                fp_bootstrap_gateway_token "${home}/.env"
            bootstrapped_gateway=1
            # Recreate so the gateway container picks up the fresh key.
            # shellcheck disable=SC2086
            ( cd "$home" && docker compose $_fp_profiles up -d ) || return 1
        else
            ai_setup_incomplete=1
            log_warn "cannot mint the AI Gateway service token without admin credentials"
            log_warn "re-run this installer with FP_ADMIN_USER and FP_ADMIN_PASS set to finish AI setup"
            # Persist the incomplete state so fp status / the tray apps
            # can surface it until a token exists.
            # fp_bootstrap_gateway_token drops the marker when the mint
            # eventually succeeds.
            if ! grep -q '^FP_AI_SETUP_INCOMPLETE=' "${home}/.env"; then
                printf 'FP_AI_SETUP_INCOMPLETE=1\n' >> "${home}/.env"
            fi
        fi
    fi

    # Hard gate: the AI Gateway must come up healthy, same bar as the
    # fresh-install paths. Honour a port remap from the existing .env:
    # it wins over FP_GATEWAY_PORT pre-defaulted by the installer shell,
    # because that variable is unexported — compose interpolates the
    # published port from .env, so the .env value is what actually binds.
    local gw_port=""
    if [ -f "${home}/.env" ]; then
        gw_port="$(sed -n 's/^FP_GATEWAY_PORT=//p' "${home}/.env" | head -n1)"
    fi
    gw_port="${gw_port:-${FP_GATEWAY_PORT:-7436}}"
    if declare -f fp_wait_for_gateway_ready >/dev/null 2>&1; then
        fp_wait_for_gateway_ready "${gw_port}" || \
            die "the AI Gateway did not become healthy — inspect: docker logs falconpulsar-ai-gateway"
    fi
    if [ "$bootstrapped_gateway" = "1" ] \
       && declare -f fp_wipe_gateway_seed_defaults >/dev/null 2>&1; then
        fp_wipe_gateway_seed_defaults falconpulsar-ai-gateway "${gw_port}"
    fi

    # Post-upgrade cleanup: remove each snapshotted previous image ID that
    # is now fully untagged (no RepoTags pointing to it = displaced by the
    # pull). Images that still have any tag are left alone — that covers
    # both "pull was a no-op so the ID is still current" and "operator
    # has a manual backup tag pointing at the same ID". Errors are
    # swallowed: cleanup is best-effort, never fatal to the upgrade.
    local id tag_count removed_count=0
    for id in $prev_image_ids; do
        tag_count=$(docker image inspect "$id" --format '{{len .RepoTags}}' 2>/dev/null || echo "")
        if [ "$tag_count" = "0" ]; then
            if docker image rm "$id" >/dev/null 2>&1; then
                removed_count=$((removed_count + 1))
            fi
        fi
    done
    if [ "$removed_count" -gt 0 ]; then
        log_step "Upgrade in place: removed ${removed_count} previous image(s)"
    fi

    # Distinct final status when the token mint was skipped: the stack
    # upgrade itself succeeded (exit 0 stands), but AI features stay
    # offline until a service token exists — make sure the caller's
    # "Upgrade complete." cannot read as unqualified success.
    if [ "$ai_setup_incomplete" = "1" ]; then
        log_warn "──────────────────────────────────────────────────────────────"
        log_warn "Upgrade finished, but AI SETUP IS INCOMPLETE."
        log_warn "The AI Gateway is running without a service token, so AI"
        log_warn "features (assistant, chat, watches) remain offline."
        log_warn "Finish setup by re-running this installer with FP_ADMIN_USER"
        log_warn "and FP_ADMIN_PASS set. (.env carries FP_AI_SETUP_INCOMPLETE=1"
        log_warn "until the token is minted.)"
        log_warn "──────────────────────────────────────────────────────────────"
    fi
    return 0
}
