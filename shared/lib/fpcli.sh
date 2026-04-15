# shellcheck shell=bash
# =============================================================================
#  fp CLI installer
# -----------------------------------------------------------------------------
#  Downloads the `fp` Go binary (https://falconpulsar.com/docs/fp) into the
#  stack's own bin/ directory so everything stays under ~/falconpulsar/.
#
#  Exposes:
#    fp_install_cli <home> <version>   # downloads $home/bin/fp for this OS/arch
#    fp_offer_path_append <home>       # prompts to append $home/bin to PATH
# =============================================================================

fp_detect_platform() {
    local os arch
    os="$(uname -s 2>/dev/null)"
    arch="$(uname -m 2>/dev/null)"

    case "$os" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        *)       return 1 ;;
    esac
    case "$arch" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             return 1 ;;
    esac
    echo "${os}-${arch}"
}

fp_install_cli() {
    local home="$1"
    local version="$2"
    local suffix

    if ! suffix="$(fp_detect_platform)"; then
        log_warn "unable to detect platform for fp CLI — skipping"
        return 0
    fi

    local repo="${FP_REPO:-FalconPulsar/falconpulsar-installer}"
    local url="https://github.com/${repo}/releases/download/v${version}/fp-${suffix}"
    local dest="${home}/bin/fp"

    mkdir -p "${home}/bin"

    log_info "downloading fp CLI (${suffix}) from ${url}"
    if ! curl -fsSL -o "${dest}" "$url"; then
        log_warn "fp CLI download failed — you can still manage the stack via 'docker compose'"
        return 0
    fi
    chmod +x "${dest}"
    log_success "fp CLI installed at ${dest}"
}

fp_offer_path_append() {
    local home="$1"
    local bin_dir="${home}/bin"

    # Skip on non-interactive runs (FP_ASSUME_YES) unless explicitly opted in.
    if [ "${FP_ASSUME_YES:-0}" = "1" ] && [ "${FP_ADD_TO_PATH:-0}" != "1" ]; then
        log_info "skipping PATH append (non-interactive); run with FP_ADD_TO_PATH=1 to enable"
        return 0
    fi

    if [ "${FP_ADD_TO_PATH:-}" = "0" ]; then
        log_info "skipping PATH append (FP_ADD_TO_PATH=0)"
        return 0
    fi

    local rc answer
    rc="$(fp_user_shell_rc)"

    if [ "${FP_ASSUME_YES:-0}" != "1" ]; then
        printf 'Add %s to your PATH in %s so you can run "fp" anywhere? [Y/n]: ' "$bin_dir" "$rc" >&2
        read -r answer
        case "$answer" in
            n|N|no|NO) log_info "skipping PATH append"; return 0 ;;
        esac
    fi

    # Idempotent: only append if not already present.
    if grep -qs "falconpulsar/bin" "$rc" 2>/dev/null; then
        log_info "PATH already contains ${bin_dir} in ${rc}"
        return 0
    fi

    {
        printf '\n# Added by FalconPulsar installer\n'
        printf 'export PATH="%s:$PATH"\n' "$bin_dir"
    } >> "$rc"
    log_success "added ${bin_dir} to PATH in ${rc} (open a new terminal or run: source ${rc})"
}

# Returns the path to the user's shell rc file (~/.zshrc, ~/.bashrc, ~/.profile).
fp_user_shell_rc() {
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"
    case "$shell_name" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            if [ -f "${HOME}/.bashrc" ]; then echo "${HOME}/.bashrc"
            else                              echo "${HOME}/.bash_profile"
            fi ;;
        fish) echo "${HOME}/.config/fish/config.fish" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}
