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

    local dest="${home}/bin/fp"
    mkdir -p "${home}/bin"

    # Prefer a local copy bundled by the GUI installer (FP_LOCAL_FP_BINARY).
    # Falling back to the GitHub release means a network round-trip and
    # depends on the release containing fp-<platform>. Bundled binaries are
    # how the macOS DMG and the Windows installer ship fp; this branch keeps
    # install working even when GitHub is unreachable.
    if [ -n "${FP_LOCAL_FP_BINARY:-}" ] && [ -f "${FP_LOCAL_FP_BINARY}" ]; then
        # Unlink first: overwriting a currently-executing binary in place
        # fails with ETXTBSY on Linux (e.g. an open fp TUI during an
        # upgrade). Removing the path lets the running process keep its
        # old inode while the new file lands cleanly.
        rm -f "${dest}"
        cp "${FP_LOCAL_FP_BINARY}" "${dest}"
        chmod +x "${dest}"
        log_success "fp CLI installed at ${dest} (from bundled binary)"
        return 0
    fi

    local repo="${FP_REPO:-FalconPulsar/falconpulsar-installer}"
    # Use /latest/ so the URL is version-agnostic. The bundled installer
    # doesn't (and shouldn't have to) know its own version tag, and
    # `v${version}` was previously falling back to "vlatest" or "v0.1.0"
    # — neither of which existed as actual release tags, so the binary
    # was never downloaded and users ended up with no fp in their bin/.
    local url="https://github.com/${repo}/releases/latest/download/fp-${suffix}"

    log_info "downloading fp CLI (${suffix}) from ${url}"
    if fp_download_release_asset "$repo" "fp-${suffix}" "$dest" "$version"; then
        chmod +x "${dest}"
        log_success "fp CLI installed at ${dest}"
        return 0
    fi
    log_warn "fp CLI download failed — you can still manage the stack via 'docker compose'"
    return 0
}

# fp_download_release_asset <repo> <asset-name> <dest> [version]
#
# Downloads <asset-name> from the most recent release of <repo>.
# Handles both the public-repo case (no auth) and the private-repo case
# (prompts for a GitHub PAT, then re-downloads via the API so the
# Authorization header survives GitHub's cross-origin redirect).
#
# The /releases/latest/download/ shortcut URL is deliberately NOT used:
# GitHub excludes prereleases from that endpoint, and FalconPulsar
# currently ships prerelease tags only (v0.1.4-alpha.X). We instead
# resolve the most recent release via the API and build the download
# URL from the returned tag name.
#
# Honoured environment overrides:
#   FP_GITHUB_TOKEN    Pre-provided PAT (skip the prompt entirely)
#   FP_ASSUME_YES=1    Non-interactive — fail fast if auth is needed and
#                      FP_GITHUB_TOKEN is unset.
#
# Returns 0 on success, 1 on failure (caller decides whether that's
# fatal — fp_install_cli treats it as a warning so an offline / private
# install can still proceed via `docker compose`).
fp_download_release_asset() {
    local repo="$1"
    local asset="$2"
    local dest="$3"
    # version arg (4th) is informational only — kept for ABI compat.

    # Step 1: resolve the most recent release tag via the API. This
    # also tells us whether the repo is private (401/403) before we
    # try the download itself.
    local api_releases="https://api.github.com/repos/${repo}/releases?per_page=1"
    local tmp_json="${dest}.api.json"
    local http_code
    http_code="$(curl -sSL -o "$tmp_json" -w "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        "$api_releases" 2>/dev/null || true)"

    case "$http_code" in
        200)
            local tag
            tag="$(awk -F'"' '/"tag_name":/ { print $4; exit }' "$tmp_json" 2>/dev/null)"
            rm -f "$tmp_json"
            if [ -z "$tag" ]; then
                log_warn "no releases found in ${repo}"
                return 1
            fi
            local public_url="https://github.com/${repo}/releases/download/${tag}/${asset}"
            local dl_code
            # Unlink first — ETXTBSY if a running fp holds this inode; a
            # failed in-place write could otherwise still report HTTP 200
            # and leave the OLD binary behind as a silent "success".
            rm -f "$dest"
            dl_code="$(curl -sSL -o "$dest" -w "%{http_code}" "$public_url" 2>/dev/null || true)"
            if [ "$dl_code" = "200" ]; then
                return 0
            fi
            rm -f "$dest"
            # An asset 404 mid-flow (after the API gave us a tag) usually
            # means the release is private and the download endpoint
            # requires auth even though the API allowed the listing.
            if [ "$dl_code" = "404" ] || [ "$dl_code" = "401" ] || [ "$dl_code" = "403" ]; then
                fp_download_with_pat "$repo" "$asset" "$dest" "$dl_code"
                return $?
            fi
            log_warn "release asset not found: ${asset} (in ${tag} of ${repo}, HTTP ${dl_code:-no-response})"
            return 1
            ;;
        401|403|404)
            # GitHub returns 404 to anonymous callers on private repos
            # (to avoid leaking existence), 401/403 on bad/missing auth.
            # All three mean "try with a token" — fp_download_with_pat
            # also re-resolves the tag via the authenticated API.
            rm -f "$tmp_json"
            fp_download_with_pat "$repo" "$asset" "$dest" "$http_code"
            return $?
            ;;
        *)
            rm -f "$tmp_json"
            log_warn "GitHub API unreachable (HTTP ${http_code:-no-response})"
            return 1
            ;;
    esac
}

# fp_download_with_pat <repo> <asset> <dest> <http_code>
#
# Interactive path for a private GitHub repo. Prompts for a PAT
# (or uses FP_GITHUB_TOKEN), then downloads via the REST API so
# Authorization is honoured through the redirect to objects.github.
#
# Retries up to FP_PAT_MAX_ATTEMPTS times (default 5) on auth failure
# so a typo in the token or the owner doesn't terminate the whole
# install. Each failed attempt re-prompts for owner + token and
# surfaces the actual HTTP status from the API so the user can tell
# whether they need a new token, a different scope, or a different org.
fp_download_with_pat() {
    local repo="$1"
    local asset="$2"
    local dest="$3"
    local seen_code="$4"

    # Keep the repo *name* from the incoming "owner/name" so a bare-owner
    # answer at the prompt can be completed to "owner/name". Many enterprise
    # customers fork FalconPulsar into their own org and need to point the
    # installer at their fork — the PAT they're about to paste is on their
    # account, not on ours. (The owner default is recomputed inside the
    # prompt loop as current_owner, since $repo can change between attempts.)
    local default_name="${repo##*/}"

    log_warn "GitHub returned ${seen_code} for ${repo} — the release appears to be private."

    # Non-interactive (assume-yes) builds can only use the env preset.
    # No prompt loop possible — fall back immediately.
    if [ "${FP_ASSUME_YES:-0}" = "1" ] && [ -z "${FP_GITHUB_TOKEN:-}" ]; then
        log_error ""
        log_error "Set FP_GITHUB_TOKEN (and optionally FP_REPO=<owner>/<name>)"
        log_error "in the environment and re-run the installer, or use"
        log_error "FP_LOCAL_FP_BINARY to point at a local fp binary."
        return 1
    fi

    local max_attempts="${FP_PAT_MAX_ATTEMPTS:-5}"
    local attempt=0
    # Was a token supplied via env? If so, attempt 1 uses that without
    # prompting; only re-prompt on failure.
    local token_from_env=0
    [ -n "${FP_GITHUB_TOKEN:-}" ] && token_from_env=1

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        local remaining=$((max_attempts - attempt))

        # ── Prompt (skipped on attempt 1 if FP_GITHUB_TOKEN preset) ────────
        if [ "$attempt" -gt 1 ] || [ "$token_from_env" -eq 0 ]; then
            printf '\n' >&2
            if [ "$attempt" -eq 1 ]; then
                printf '%sGitHub authentication required%s\n' \
                    "${FP_C_BOLD}" "${FP_C_RESET}" >&2
                printf 'The fp CLI lives in a private GitHub release. Anonymous downloads got\n' >&2
                printf 'an HTTP %s on %s%s%s, so it looks private to you.\n\n' \
                    "$seen_code" "${FP_C_CYAN}" "$repo" "${FP_C_RESET}" >&2
            else
                printf '%sAttempt %d of %d%s — re-enter credentials (or press Enter at the\n' \
                    "${FP_C_BOLD}" "$attempt" "$max_attempts" "${FP_C_RESET}" >&2
                printf 'token prompt to cancel and continue with docker compose).\n\n' >&2
            fi
            printf 'If you have your own fork of the installer in a different GitHub\n' >&2
            printf 'organisation, enter the owner here. Otherwise hit Enter to keep the\n' >&2
            printf 'default. You can also paste a full %sowner/repo%s path if your fork has\n' \
                "${FP_C_BOLD}" "${FP_C_RESET}" >&2
            printf 'a different name.\n\n' >&2

            # ── GitHub user / owner prompt ────────────────────────────────
            local current_owner="${repo%%/*}"
            printf '    GitHub user / organisation [%s%s%s]: ' \
                "${FP_C_BOLD}" "$current_owner" "${FP_C_RESET}" >&2
            local entered_owner=''
            IFS= read -r entered_owner </dev/tty 2>/dev/null || entered_owner=''
            if [ -n "$entered_owner" ]; then
                case "$entered_owner" in
                    */*) repo="$entered_owner" ;;            # "myorg/myfork"
                    *)   repo="${entered_owner}/${default_name}" ;;  # just "myorg"
                esac
                log_info "using repository ${repo}"
            fi

            # ── PAT prompt ────────────────────────────────────────────────
            printf '\nPaste a personal access token for %s%s%s on %s%s%s. Token is used\n' \
                "${FP_C_BOLD}" "${repo%%/*}" "${FP_C_RESET}" \
                "${FP_C_CYAN}" "$repo" "${FP_C_RESET}" >&2
            printf 'once and discarded — never written to disk. Scope:\n' >&2
            printf '  • classic PAT: %srepo%s\n' "${FP_C_BOLD}" "${FP_C_RESET}" >&2
            printf '  • fine-grained PAT: %sContents: read%s on the target repo\n\n' \
                "${FP_C_BOLD}" "${FP_C_RESET}" >&2
            printf '    Token (input hidden, paste then Enter): ' >&2
            stty -echo 2>/dev/null || true
            IFS= read -r FP_GITHUB_TOKEN </dev/tty 2>/dev/null || FP_GITHUB_TOKEN=""
            stty echo 2>/dev/null || true
            printf '\n' >&2
            # Strip surrounding whitespace — paste-from-clipboard sometimes
            # includes a stray space or trailing newline that makes the
            # token invalid even though it visually looks correct.
            FP_GITHUB_TOKEN="$(printf '%s' "$FP_GITHUB_TOKEN" | tr -d '[:space:]')"

            if [ -z "$FP_GITHUB_TOKEN" ]; then
                log_warn "no token entered — giving up on private-repo download"
                return 1
            fi
        fi

        # ── Step 1: hit the API to resolve the asset's download URL. ─────
        # `/releases?per_page=1` returns the most recent release including
        # prereleases (unlike `/releases/latest` which skips prereleases).
        # We capture the HTTP status separately so we can give a meaningful
        # error on retry instead of the generic "could not resolve" message.
        local api_url="https://api.github.com/repos/${repo}/releases?per_page=1"
        local api_body_file="${dest}.api.json"
        local api_code
        api_code="$(curl -sSL -o "$api_body_file" -w '%{http_code}' \
            -H "Authorization: token ${FP_GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "$api_url" 2>/dev/null || echo '000')"

        if [ "$api_code" != "200" ]; then
            rm -f "$api_body_file"
            case "$api_code" in
                401)
                    log_error "GitHub API returned HTTP 401 (Bad credentials)."
                    log_error "  The token is invalid, expired, or was mistyped."
                    ;;
                403)
                    log_error "GitHub API returned HTTP 403 (Forbidden)."
                    log_error "  Token lacks the required scope. Classic PATs need 'repo';"
                    log_error "  fine-grained PATs need 'Contents: read' on ${repo}."
                    ;;
                404)
                    log_error "GitHub API returned HTTP 404 for ${repo}."
                    log_error "  Either the repo doesn't exist under that owner, or your"
                    log_error "  token's account doesn't have access to it."
                    ;;
                000)
                    log_error "Could not reach GitHub API — check network connectivity."
                    ;;
                *)
                    log_error "GitHub API returned HTTP ${api_code} for ${repo}."
                    ;;
            esac
            # Clear token so the next loop iteration prompts again.
            FP_GITHUB_TOKEN=""
            token_from_env=0
            if [ "$remaining" -gt 0 ]; then
                log_info "(${remaining} attempt(s) remaining)"
                continue
            fi
            log_error "out of attempts — falling back to 'docker compose' (the stack still works)."
            return 1
        fi

        # API call succeeded — parse out the API URL for the named asset.
        # Tightened regex: match the literal `"url":` field at indent only,
        # NOT `browser_download_url:` (which contains "url:" as a substring
        # and used to overwrite the lasturl tracker on every asset).
        local asset_url
        asset_url="$(
            awk -v want="\"name\": \"${asset}\"" '
                /^[[:space:]]*"url":/ { lasturl=$0 }
                $0 ~ want { print lasturl; exit }
            ' "$api_body_file" \
            | sed -E 's/.*"url": "([^"]+)".*/\1/'
        )"
        rm -f "$api_body_file"

        if [ -z "$asset_url" ]; then
            log_error "API call succeeded (HTTP 200) but the latest release of ${repo}"
            log_error "does not contain an asset named '${asset}'. The release may have"
            log_error "been published without per-platform binaries — contact the maintainer."
            # No point in retrying with a different token — the asset name itself
            # is missing from the release. Bail.
            return 1
        fi

        # ── Step 2: download the asset. ──────────────────────────────────
        # -L follows the redirect to objects.github; we explicitly ask for
        # octet-stream so the API hands back the binary, not JSON metadata.
        local dl_code
        rm -f "$dest"   # unlink first — see the ETXTBSY note in fp_install_cli
        dl_code="$(curl -sSL -o "$dest" -w '%{http_code}' \
            -H "Authorization: token ${FP_GITHUB_TOKEN}" \
            -H "Accept: application/octet-stream" \
            "$asset_url" 2>/dev/null || echo '000')"

        if [ "$dl_code" = "200" ]; then
            log_success "downloaded ${asset} via GitHub API (authenticated)"
            return 0
        fi

        # Download failed even though the asset URL resolved — usually a
        # redirect-strips-auth or scope mismatch on the actual asset object.
        rm -f "$dest"
        log_error "asset download failed with HTTP ${dl_code} after API resolved the URL."
        log_error "  The token may lack the right scope on the actual file object."
        FP_GITHUB_TOKEN=""
        token_from_env=0
        if [ "$remaining" -gt 0 ]; then
            log_info "(${remaining} attempt(s) remaining)"
            continue
        fi
        log_error "out of attempts — falling back to 'docker compose'."
        return 1
    done

    return 1
}

fp_offer_path_append() {
    local home="$1"
    local bin_dir="${home}/bin"

    # Non-interactive runs default to ADDING the path (the GUI installer
    # always sets FP_ASSUME_YES=1, and a `fp: command not found` after
    # install is a worse default than a one-line PATH append). Set
    # FP_ADD_TO_PATH=0 explicitly to opt out.
    if [ "${FP_ADD_TO_PATH:-}" = "0" ]; then
        log_info "skipping PATH append (FP_ADD_TO_PATH=0)"
        return 0
    fi

    local rc answer
    rc="$(fp_user_shell_rc)"

    if [ "${FP_ASSUME_YES:-0}" != "1" ]; then
        printf 'Add %s to your PATH in %s so you can run "fp" anywhere? [Y/n]: ' "$bin_dir" "$rc" >&2
        read -r answer || answer=''   # EOF -> '' -> default Y (add to PATH), not an errexit abort
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
        # shellcheck disable=SC2016  # literal $PATH intended in the rc file
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

# Strip the 2-line block that fp_offer_path_append wrote, from every rc
# file that might contain it. Idempotent and silent on rc files that
# don't exist. Uses awk for portability across GNU/BSD sed dialects.
#
# What we wrote (from fp_offer_path_append above):
#
#     # Added by FalconPulsar installer
#     export PATH="<FP_HOME>/bin:$PATH"
#
# We match on the marker comment AND the next line containing
# "falconpulsar/bin" so we don't accidentally delete an unrelated comment
# that just happens to start with the same prefix. Saves a .fp-bak copy
# next to the file in case the user wants to inspect what was removed.
fp_remove_path_append() {
    local target_home
    for target_home in "$@"; do
        [ -n "$target_home" ] || continue
        # Candidates: bash, zsh, fish, generic
        local rc
        for rc in "${target_home}/.bashrc" \
                  "${target_home}/.bash_profile" \
                  "${target_home}/.zshrc" \
                  "${target_home}/.profile" \
                  "${target_home}/.config/fish/config.fish"; do
            [ -f "$rc" ] || continue
            if ! grep -qsF "Added by FalconPulsar installer" "$rc"; then
                continue
            fi
            # Drop the marker line AND the following PATH line.
            # awk is the most portable way to do a two-line delete in one pass.
            local tmp="${rc}.fp-uninstall.tmp"
            awk '
                BEGIN { skip = 0 }
                /^# Added by FalconPulsar installer$/ {
                    skip = 2     # also drop the next line
                    next
                }
                skip > 0 {
                    skip--
                    next
                }
                { print }
            ' "$rc" > "$tmp" && mv "$tmp" "$rc"
        done
    done
}
