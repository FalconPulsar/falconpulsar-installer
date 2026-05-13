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
