#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# checks.sh — Pre-flight checks for the FalconPulsar installers.
#
# Provides:
#   - check_supported_os        — refuse to run on EOL distros
#   - check_arch                — x86_64 / arm64 only
#   - check_kernel              — Linux 5.15+ recommended
#   - check_systemd             — required for the systemd install mode
#   - check_ram / check_disk    — minimums per REQUIREMENTS.md
#   - check_ports               — 7433/7434/7435/7436/80 must be free
#   - check_docker              — docker engine + compose v2 plugin
#   - check_docker_daemon       — daemon reachable + non-root member of docker group
#   - install_docker_linux      — wraps the official get.docker.com script
#   - check_virtualization (wsl) — VT-x/AMD-V enabled
#
# Sourced by linux/install.sh and macos/install.sh. Depends on common.sh.
# =============================================================================

if [ -n "${__FP_CHECKS_SH_LOADED:-}" ]; then
    return 0
fi
__FP_CHECKS_SH_LOADED=1

# Ensure common.sh is loaded
if [ -z "${__FP_COMMON_SH_LOADED:-}" ]; then
    # shellcheck source=common.sh
    . "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
fi

# ── Minimums (kept in sync with REQUIREMENTS.md) ─────────────────────────────
FP_MIN_RAM_MB_LINUX=4096
FP_MIN_RAM_MB_OTHER=8192
FP_MIN_DISK_GB=10
FP_DEFAULT_PORTS="7433 7434 7435 7436 80"

# ── OS detection ─────────────────────────────────────────────────────────────
# Reads /etc/os-release and exports FP_DISTRO_ID, FP_DISTRO_VERSION,
# FP_DISTRO_LIKE. Returns 1 on macOS or other non-linux OSes.
detect_distro() {
    if [ ! -r /etc/os-release ]; then
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    FP_DISTRO_ID="${ID:-unknown}"
    FP_DISTRO_VERSION="${VERSION_ID:-0}"
    FP_DISTRO_LIKE="${ID_LIKE:-}"
    export FP_DISTRO_ID FP_DISTRO_VERSION FP_DISTRO_LIKE
}

# Compare two dotted version strings: returns 0 if $1 >= $2.
# Example: version_ge "24.04" "22.04"
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ── Preflight package install ────────────────────────────────────────────────
#
# A minimal Ubuntu / Debian / RHEL / openSUSE base image is missing several
# tools the installer treats as universal:
#
#   curl       (every download path: get.docker.com, fp binary, /auth/me, ...)
#   hostname   (post-install banner; non-fatal but breaks the IP detection)
#   useradd    (service-user mode creates the falconpulsar account)
#   openssl    (password generation; falls back to /dev/urandom — non-fatal)
#   ss         (port-free check; falls back to lsof/netstat — non-fatal)
#   ca-certificates  (HTTPS verification for curl)
#
# Note: we used to also require `sg` (switch-group), but some minimal
# Ubuntu cloud images ship the `login` package WITHOUT /usr/bin/sg. We
# now use `sudo -u <user> -g docker -H bash -c "..."` everywhere instead,
# which sets the effective gid via sudo and is universally available.
#
# fp_preflight_packages detects which of those are missing, maps them to the
# right packages per package manager, and installs them in one apt/dnf/yum/
# zypper invocation. Idempotent: skips silently when everything is present.
# Fails with an actionable error when no package manager is found (air-gap).
fp_preflight_packages() {
    local missing=()
    local cmd
    for cmd in curl hostname useradd openssl ss; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log_info "preflight: required tools present (curl, hostname, useradd, openssl, ss)"
        return 0
    fi

    log_step "preflight — installing missing tools: ${missing[*]}"

    # Map missing commands to the packages that provide them. Each branch
    # below builds the package list for ONE package manager, then runs the
    # install. Mappings come from the audit at the top of this section.
    local packages=()
    local pkg_mgr=""

    if command -v apt-get >/dev/null 2>&1; then
        pkg_mgr="apt"
        # ca-certificates is always pulled with curl on Debian/Ubuntu; explicit
        # so the install doesn't end up with a curl that can't verify HTTPS.
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                curl)     packages+=("curl" "ca-certificates") ;;
                hostname) packages+=("hostname") ;;
                useradd)  packages+=("passwd") ;;
                openssl)  packages+=("openssl") ;;
                ss)       packages+=("iproute2") ;;
            esac
        done
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            pkg_mgr="dnf"
        else
            pkg_mgr="yum"
        fi
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                curl)     packages+=("curl" "ca-certificates") ;;
                hostname) packages+=("hostname") ;;
                useradd)  packages+=("shadow-utils") ;;
                openssl)  packages+=("openssl") ;;
                ss)       packages+=("iproute") ;;
            esac
        done
    elif command -v zypper >/dev/null 2>&1; then
        pkg_mgr="zypper"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                curl)     packages+=("curl" "ca-certificates") ;;
                hostname) packages+=("hostname") ;;
                useradd)  packages+=("shadow") ;;
                openssl)  packages+=("openssl") ;;
                ss)       packages+=("iproute2") ;;
            esac
        done
    else
        local err_msg="no supported package manager (apt/dnf/yum/zypper) detected. "
        err_msg+="Install these tools manually then re-run: ${missing[*]}"
        die "$err_msg"
    fi

    # De-duplicate the package list (e.g. shadow-utils appears twice if both
    # sg and useradd are missing on RHEL). sort -u keeps the helper portable
    # to bash 3.2 (macOS) — declare -A would have been cleaner but is bash 4+.
    local unique_packages=()
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && unique_packages+=("$pkg")
    done < <(printf '%s\n' "${packages[@]}" | sort -u)

    log_info "preflight: ${pkg_mgr} install: ${unique_packages[*]}"
    case "$pkg_mgr" in
        apt)
            # noninteractive frontend so any debconf prompts don't hang the
            # install behind a TTY-less ssh session.
            DEBIAN_FRONTEND=noninteractive \
                apt-get update -qq
            DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends "${unique_packages[@]}"
            ;;
        dnf)
            dnf install -y --setopt=install_weak_deps=False "${unique_packages[@]}"
            ;;
        yum)
            yum install -y "${unique_packages[@]}"
            ;;
        zypper)
            zypper --non-interactive install --no-recommends "${unique_packages[@]}"
            ;;
    esac

    # Verify every originally-missing tool is now present. Catches the
    # weird case where a package install reports success but the binary
    # didn't land on PATH (alternative slots, restricted distros, etc.).
    local still_missing=()
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
    done
    if [ ${#still_missing[@]} -gt 0 ]; then
        local err_msg="preflight: still missing after install: ${still_missing[*]}. "
        err_msg+="Check the ${pkg_mgr} output above for failures. "
        err_msg+="You can install them manually then re-run the installer."
        die "$err_msg"
    fi
    log_success "preflight: installed ${unique_packages[*]}"
}

check_supported_os() {
    local os
    os="$(detect_os)"

    case "$os" in
        macos)
            local mac_ver
            mac_ver="$(sw_vers -productVersion 2>/dev/null || echo 0)"
            if ! version_ge "$mac_ver" "14.0"; then
                die "macOS ${mac_ver} is not supported. Minimum: macOS 14 Sonoma. See REQUIREMENTS.md"
            fi
            log_success "macOS ${mac_ver} is supported"
            return 0
            ;;
        linux|wsl)
            : # fall through to distro checks
            ;;
        *)
            die "unsupported OS: $(uname -s). See REQUIREMENTS.md for the supported list."
            ;;
    esac

    detect_distro || die "cannot read /etc/os-release — unable to identify Linux distribution"

    local id="$FP_DISTRO_ID"
    local ver="$FP_DISTRO_VERSION"
    local ok=0

    case "$id" in
        ubuntu)
            version_ge "$ver" "22.04" && ok=1
            ;;
        debian)
            version_ge "$ver" "12" && ok=1
            ;;
        rhel|rocky|almalinux)
            version_ge "$ver" "9" && ok=1
            ;;
        fedora)
            version_ge "$ver" "41" && ok=1
            ;;
        opensuse-leap)
            version_ge "$ver" "15.6" && ok=1
            ;;
        *)
            # Try ID_LIKE as a fallback (e.g. derivatives of ubuntu/debian/rhel)
            case "$FP_DISTRO_LIKE" in
                *debian*|*ubuntu*|*rhel*|*fedora*)
                    log_warn "distro '${id}' is not officially supported but looks ${FP_DISTRO_LIKE}-derived; continuing best-effort"
                    ok=1
                    ;;
            esac
            ;;
    esac

    if [ "$ok" -ne 1 ]; then
        die "${id} ${ver} is not supported. See REQUIREMENTS.md for the supported list."
    fi

    log_success "${id} ${ver} is supported"
}

check_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64|aarch64|arm64)
            log_success "architecture ${arch} is supported"
            ;;
        *)
            die "architecture ${arch} is not supported. Need x86_64 or arm64."
            ;;
    esac
}

check_kernel() {
    [ "$(detect_os)" = "macos" ] && return 0
    local kver
    kver="$(uname -r | cut -d- -f1)"
    if ! version_ge "$kver" "5.15"; then
        log_warn "kernel ${kver} is older than 5.15 — Docker features may be limited"
    else
        log_success "kernel ${kver} is supported"
    fi
}

check_systemd() {
    if [ "$(detect_os)" = "macos" ]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemd not found. The systemd install mode requires systemd >= 245."
    fi
    if ! [ -d /run/systemd/system ]; then
        die "systemd is installed but not running as PID 1. The systemd install mode requires systemd."
    fi
    log_success "systemd is available"
}

# ── Resource checks ──────────────────────────────────────────────────────────
check_ram() {
    local total_mb min_mb
    case "$(detect_os)" in
        macos)
            total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
            min_mb=$FP_MIN_RAM_MB_OTHER
            ;;
        *)
            total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
            min_mb=$FP_MIN_RAM_MB_LINUX
            ;;
    esac

    if [ "$total_mb" -eq 0 ]; then
        log_warn "could not determine system RAM — skipping check"
        return 0
    fi

    if [ "$total_mb" -lt "$min_mb" ]; then
        die "insufficient RAM: ${total_mb} MB available, ${min_mb} MB required"
    fi
    log_success "RAM: ${total_mb} MB (min ${min_mb} MB)"
}

# check_disk <path>
check_disk() {
    local path="${1:-/var/lib}"
    [ -d "$path" ] || path="$(dirname "$path")"
    [ -d "$path" ] || path="/"

    log_info "checking free disk on ${path}..."

    local free_gb=""

    # Try GNU df first (Linux), then BSD df (macOS). Strip anything that
    # isn't a digit so we get a clean integer regardless of suffix ("G",
    # "Gi", etc.) and don't fall over on whitespace or APFS quirks.
    if free_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9') && [ -n "$free_gb" ]; then
        :
    elif free_gb=$(df -g "$path" 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9') && [ -n "$free_gb" ]; then
        :
    else
        free_gb=""
    fi

    if [ -z "$free_gb" ]; then
        log_warn "could not determine free disk on ${path} — skipping check"
        return 0
    fi

    if [ "$free_gb" -lt "$FP_MIN_DISK_GB" ]; then
        die "insufficient disk: ${free_gb} GB free on ${path}, ${FP_MIN_DISK_GB} GB required"
    fi
    log_success "disk: ${free_gb} GB free on ${path} (min ${FP_MIN_DISK_GB} GB)"
}

# ── Port checks ──────────────────────────────────────────────────────────────
# port_in_use <port>  — returns 0 if something is listening
port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    else
        # No tooling — assume free, the bind will fail later if not.
        return 1
    fi
}

# port_holder <port>  — print the process holding a port (best-effort)
port_holder() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print "    " $1 " (pid " $2 ", user " $3 ")"}'
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnp "sport = :${port}" 2>/dev/null | awk 'NR>1 {print "    " $0}'
    fi
}

# fp_port_held_by_our_stack <port>
#
# True when the listener on <port> is one of OUR OWN running containers.
#
# WHY THIS EXISTS
#
# An upgrade deliberately leaves the stack running: fp_apply_existing_action's
# `upgrade` branch keeps containers up (only `reinstall` and `fresh` run
# `compose down`), because the upgrade fast-path is pull + restart. The
# phantom sweep then correctly skips those containers -- they are ours, at the
# target home, not orphans.
#
# So by the time the port check runs, OUR containers are holding 7433/7434/
# 7435, and the check called that a conflict and died. On Windows, which always
# passes --yes, FP_ASSUME_YES=1 made it fatal with no way through:
#
#     [ok] no orphaned FalconPulsar containers found
#     [error] Port conflict(s) detected ... FP_REST_PORT = 7433
#     [error] (could not identify the process holding the port)
#     [error] Cannot prompt for remap in non-interactive mode
#
# "could not identify the process" is the tell: the listener lives in Docker's
# network namespace, so lsof/ss on the host see a bound port with no process
# behind it. Every upgrade over a running stack hit this.
#
# A port held by a container `docker compose up -d` is about to recreate is
# not a conflict -- compose replaces its own containers. Only a FOREIGN
# listener is worth stopping the install for.
fp_port_held_by_our_stack() {
    local port="$1"
    [ -n "$port" ] || return 1
    # fp_docker, NOT bare docker: the installer body runs as root, and root
    # is not guaranteed to reach the daemon (WSL + Docker Desktop grants the
    # socket to the service user). A bare `docker info` failed here, this
    # returned "not ours", and our own Core's ports were reported as a foreign
    # conflict that aborted the upgrade.
    #
    # `docker ps` prints published ports as "0.0.0.0:7433->7433/tcp", several
    # comma-separated per container. Match the HOST side only -- the container
    # side is not what we are competing for.
    fp_docker ps --filter 'name=falconpulsar-' --format '{{.Ports}}' 2>/dev/null \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//' \
        | grep -qE "^(0\.0\.0\.0|127\.0\.0\.1|\[::\]|::|[0-9.]+):${port}->"
}

# check_ports [port...]  (defaults to FP_DEFAULT_PORTS)
check_ports() {
    local ports="${*:-$FP_DEFAULT_PORTS}"
    local port conflicts=""
    log_info "checking required TCP ports: ${ports}"
    for port in $ports; do
        if port_in_use "$port"; then
            log_error "port ${port} is already in use:"
            port_holder "$port" >&2 || true
            conflicts="${conflicts}${port} "
        fi
    done
    if [ -n "$conflicts" ]; then
        log_error ""
        log_error "Conflicting ports: ${conflicts}"
        log_error "Either stop the offending process(es) or remap the FalconPulsar"
        log_error "ports by re-running with --ui-port / --rest-port, e.g.:"
        log_error "    bash $0 --ui-port 18080"
        die "port conflict"
    fi
    log_success "all required ports are free: ${ports}"
}

# fp_check_ports_interactive <var_name> [var_name ...]
#
# Recoverable replacement for check_ports. Takes a list of FP_*_PORT
# variable names (NOT values). For each name it reads the current value,
# checks for conflicts, and on conflict offers:
#
#   1) Remap one of the conflicting FalconPulsar ports to a free number
#   2) Re-check (the operator stopped the process out of band)
#   3) Abort the installation
#
# On successful remap the function mutates the named variable in place
# (export "$var=$new_port") and re-checks. The caller can then read the
# updated value through the same variable name in subsequent steps —
# step 6 (.env writing) and step 7 (compose up) both reference the
# variables, so a remap propagates automatically.
#
# Returns 0 on success; calls die() on abort or after FP_PORT_REMAP_MAX
# unresolved iterations (default 8).
#
# Honoured environment overrides:
#   FP_ASSUME_YES=1           Non-interactive: any conflict is fatal with
#                             a clear "set FP_*_PORT or stop the holder"
#                             message. No prompts.
#   FP_PORT_REMAP_MAX         Override the iteration cap (default 8).
fp_check_ports_interactive() {
    local -a port_vars=("$@")
    if [ "${#port_vars[@]}" -eq 0 ]; then
        die "fp_check_ports_interactive: no port variable names supplied"
    fi

    local max_attempts="${FP_PORT_REMAP_MAX:-8}"
    local attempt=0

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))

        # Snapshot the current values into a parallel array so we can
        # show them to the user and pick which to remap.
        local -a conflict_vars=()
        local -a conflict_ports=()
        local v port
        local -a ours=()
        for v in "${port_vars[@]}"; do
            eval "port=\${$v:-}"
            [ -z "$port" ] && continue
            if port_in_use "$port"; then
                # Ours is not a conflict: `compose up -d` recreates its own
                # containers in place. Only a foreign listener blocks us.
                if fp_port_held_by_our_stack "$port"; then
                    ours+=("${v}=${port}")
                    continue
                fi
                conflict_vars+=("$v")
                conflict_ports+=("$port")
            fi
        done

        if [ "${#ours[@]}" -gt 0 ]; then
            log_info "in use by this stack's own containers (will be recreated): ${ours[*]}"
        fi

        if [ "${#conflict_vars[@]}" -eq 0 ]; then
            local summary=""
            for v in "${port_vars[@]}"; do
                eval "port=\${$v:-}"
                [ -n "$port" ] && summary="${summary}${port} "
            done
            log_success "all required ports are free: ${summary% }"
            return 0
        fi

        # Print the conflicts.
        log_error ""
        log_error "Port conflict(s) detected — these ports are already in use:"
        local i=0
        while [ "$i" -lt "${#conflict_vars[@]}" ]; do
            printf '\n    %s = %s\n' "${conflict_vars[$i]}" "${conflict_ports[$i]}" >&2
            port_holder "${conflict_ports[$i]}" >&2 || printf '    (could not identify the process holding the port)\n' >&2
            i=$((i + 1))
        done

        # Non-interactive: fail fast with actionable instructions.
        if [ "${FP_ASSUME_YES:-0}" = "1" ]; then
            log_error ""
            log_error "Cannot prompt for remap in non-interactive mode (FP_ASSUME_YES=1)."
            log_error "Either stop the offending process(es) and re-run, or pre-set"
            log_error "the FalconPulsar port environment variables to free numbers, e.g.:"
            local cv
            for cv in "${conflict_vars[@]}"; do
                log_error "    ${cv}=<free-port>"
            done
            die "port conflict (non-interactive)"
        fi

        # Interactive: present three top-level options.
        printf '\n%sWhat would you like to do?%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
        printf '  %s1%s) Remap a FalconPulsar port to a different number\n' "${FP_C_CYAN}" "${FP_C_RESET}" >&2
        printf '  %s2%s) Re-check (after you stop the conflicting process)\n' "${FP_C_CYAN}" "${FP_C_RESET}" >&2
        printf '  %s3%s) Abort the installation\n\n' "${FP_C_CYAN}" "${FP_C_RESET}" >&2
        printf 'Choice [1-3, default 2]: ' >&2
        local choice=''
        IFS= read -r choice </dev/tty 2>/dev/null || choice=''
        case "${choice:-2}" in
            1)
                fp_prompt_port_remap conflict_vars conflict_ports || true
                ;;
            2)
                log_info "re-checking ports..."
                ;;
            3|q|Q|cancel)
                die "installation cancelled by user (unresolved port conflict)"
                ;;
            *)
                log_warn "invalid choice; re-checking"
                ;;
        esac
    done

    die "port conflict not resolved after ${max_attempts} attempts"
}

# fp_prompt_port_remap <conflict_vars_arrname> <conflict_ports_arrname>
#
# Helper called by fp_check_ports_interactive. Lets the user pick which
# of the conflicting ports to remap and what to remap it to. Validates
# the new port (numeric, 1024-65535 — privileged ports rejected because
# the falconpulsar service user can't bind them, also rejects already-
# in-use numbers). Mutates the named port variable on success.
fp_prompt_port_remap() {
    # We receive array NAMES so we can read both the variable name and
    # the current value side-by-side. Bash 4+ namerefs would be cleaner
    # but POSIX-ish eval keeps us portable to older macOS bash.
    local cvars_name="$1"
    local cports_name="$2"
    local count
    eval "count=\${#${cvars_name}[@]}"

    if [ "$count" -eq 1 ]; then
        local only_var only_port
        eval "only_var=\${${cvars_name}[0]}"
        eval "only_port=\${${cports_name}[0]}"
        fp_prompt_single_port_remap "$only_var" "$only_port"
        return $?
    fi

    printf '\nWhich port would you like to remap?\n' >&2
    local i=0
    while [ "$i" -lt "$count" ]; do
        local cv cp
        eval "cv=\${${cvars_name}[$i]}"
        eval "cp=\${${cports_name}[$i]}"
        printf '  %s%d%s) %s (currently %s)\n' "${FP_C_CYAN}" "$((i+1))" "${FP_C_RESET}" "$cv" "$cp" >&2
        i=$((i + 1))
    done
    printf '\nChoice [1-%d]: ' "$count" >&2
    local pick=''
    IFS= read -r pick </dev/tty 2>/dev/null || pick=''
    case "$pick" in
        ''|*[!0-9]*) log_warn "not a number; cancelling remap"; return 1 ;;
    esac
    if [ "$pick" -lt 1 ] || [ "$pick" -gt "$count" ]; then
        log_warn "out of range; cancelling remap"
        return 1
    fi
    local idx=$((pick - 1))
    local target_var target_port
    eval "target_var=\${${cvars_name}[$idx]}"
    eval "target_port=\${${cports_name}[$idx]}"
    fp_prompt_single_port_remap "$target_var" "$target_port"
}

# fp_prompt_single_port_remap <var_name> <current_port>
# Asks for a new port number, validates it, and assigns it back to the
# named variable (also export it so child processes see the change).
fp_prompt_single_port_remap() {
    local var_name="$1"
    local current="$2"
    printf '\n    Current %s = %s\n' "$var_name" "$current" >&2
    printf '    New port [1024-65535]: ' >&2
    local new_port=''
    IFS= read -r new_port </dev/tty 2>/dev/null || new_port=''
    case "$new_port" in
        ''|*[!0-9]*) log_warn "not a number; cancelling remap"; return 1 ;;
    esac
    if [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        log_warn "port out of unprivileged range 1024-65535; cancelling remap"
        return 1
    fi
    if [ "$new_port" = "$current" ]; then
        log_warn "port unchanged; cancelling remap"
        return 1
    fi
    if port_in_use "$new_port"; then
        log_warn "port ${new_port} is also already in use; cancelling remap"
        return 1
    fi
    eval "${var_name}=${new_port}"
    export "${var_name?}"
    log_success "remapped ${var_name}=${new_port}"
    return 0
}

# ── Docker checks ────────────────────────────────────────────────────────────
check_docker_installed() {
    command -v docker >/dev/null 2>&1
}

check_compose_v2() {
    docker compose version >/dev/null 2>&1
}

check_docker_daemon() {
    if ! docker info >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# check_dockerhub_login — verifies the user is logged into Docker Hub.
# Required during the pre-release period because the falconpulsar/* images
# are private. Reads the standard ~/.docker/config.json. We do NOT call
# `docker login` ourselves — credentials should never be passed on the
# command line or sit in environment variables.
check_dockerhub_login() {
    log_info "checking Docker Hub authentication..."
    local cfg="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
    if [ ! -f "$cfg" ]; then
        log_error "no Docker config found at ${cfg}"
        log_error ""
        log_error "FalconPulsar images are private during the pre-release period."
        log_error "Log in to Docker Hub with an authorized account first:"
        log_error "    docker login"
        log_error "then re-run this installer."
        die "docker hub login required"
    fi
    if ! grep -q '"https://index.docker.io/v1/"' "$cfg" 2>/dev/null && \
       ! grep -q '"docker.io"' "$cfg" 2>/dev/null; then
        log_error "Docker config exists but has no Docker Hub credentials."
        log_error "Run: docker login    (then re-run this installer)"
        die "docker hub login required"
    fi
    log_success "Docker Hub credentials present in ${cfg}"
}

# Linux-only: install Docker Engine via the official get.docker.com script.
install_docker_linux() {
    require_cmd curl
    log_step "installing Docker Engine via get.docker.com (will use sudo)"
    # Download into a private 0700 directory, never a fixed name in /tmp.
    #
    # This runs as root (linux/install.sh refuses to start otherwise). With a predictable
    # path, any local unprivileged user can pre-create /tmp/get-docker.sh as a file they
    # own; `curl -o` opens it O_TRUNC without O_EXCL and does not take ownership, so root
    # writes into THEIR inode — and they can rewrite it before, or while, root executes it.
    # The sticky bit does not help: it prevents unlinking another user's file, not writing
    # to your own. mktemp -d gives a root-owned directory no one else can enter, which is
    # the pattern already used in common.sh and linux/install.sh.
    _fp_dockertmp="$(mktemp -d)" || { log_error "could not create a temp directory"; return 1; }
    curl -fsSL https://get.docker.com -o "$_fp_dockertmp/get-docker.sh" || {
        rm -rf "$_fp_dockertmp"; log_error "could not download the Docker install script"; return 1
    }
    sh "$_fp_dockertmp/get-docker.sh"
    _fp_rc=$?
    rm -rf "$_fp_dockertmp"
    [ "$_fp_rc" -eq 0 ] || { log_error "the Docker install script failed (exit $_fp_rc)"; return "$_fp_rc"; }
    log_success "Docker Engine installed"
}

# add_user_to_docker_group <username>  — Linux only
add_user_to_docker_group() {
    local user="$1"
    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker "$user"
    log_success "added ${user} to the docker group (re-login required for the group to take effect)"
}

# Verify a non-root user can talk to the docker daemon. Used after the
# falconpulsar user is added to the docker group.
check_docker_as_user() {
    local user="$1"
    if run_as_user "$user" docker info >/dev/null 2>&1; then
        log_success "${user} can talk to docker daemon"
        return 0
    fi
    log_warn "${user} cannot talk to docker daemon yet — group membership may need a re-login"
    return 1
}

# ── WSL / virtualization (Windows side runs Inno Setup, but the WSL distro
# itself runs the Linux installer, so this lives here too).
check_wsl_virtualization() {
    [ "$(detect_os)" = "wsl" ] || return 0
    if ! grep -q vmx /proc/cpuinfo 2>/dev/null && ! grep -q svm /proc/cpuinfo 2>/dev/null; then
        log_warn "hardware virtualization (VT-x/AMD-V) not detected inside WSL — Docker may not run"
    else
        log_success "WSL2 hardware virtualization detected"
    fi
}
