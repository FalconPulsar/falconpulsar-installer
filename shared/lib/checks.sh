#!/usr/bin/env bash
# =============================================================================
# checks.sh — Pre-flight checks for the FalconPulsar installers.
#
# Provides:
#   - check_supported_os        — refuse to run on EOL distros
#   - check_arch                — x86_64 / arm64 only
#   - check_kernel              — Linux 5.15+ recommended
#   - check_systemd             — required for the systemd install mode
#   - check_ram / check_disk    — minimums per REQUIREMENTS.md
#   - check_ports               — 7433/7434/7435/7436/8080 must be free
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
FP_DEFAULT_PORTS="7433 7434 7435 7436 8080"

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

    local free_gb
    free_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
    [ -z "$free_gb" ] && free_gb=$(df -g "$path" 2>/dev/null | awk 'NR==2 {print $4}')

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

# check_ports [port...]  (defaults to FP_DEFAULT_PORTS)
check_ports() {
    local ports="${*:-$FP_DEFAULT_PORTS}"
    local port conflicts=""
    for port in $ports; do
        if port_in_use "$port"; then
            conflicts="${conflicts}${port} "
        fi
    done
    if [ -n "$conflicts" ]; then
        log_error "the following ports are already in use: ${conflicts}"
        log_error "either stop the conflicting services or set FP_*_PORT in .env to remap them"
        die "port conflict"
    fi
    log_success "all required ports are free: ${ports}"
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

# Linux-only: install Docker Engine via the official get.docker.com script.
install_docker_linux() {
    require_cmd curl
    log_step "installing Docker Engine via get.docker.com (will use sudo)"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
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
