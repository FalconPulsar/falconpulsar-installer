#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 FalconPulsar Contributors

# =============================================================================
# FalconPulsar Linux bootstrap
#
# Tiny dispatcher served at https://get.falconpulsar.com/linux (redirect to
# this file's release asset: linux.sh). It downloads BOTH the bundled
# install script and the bundled uninstall script to the same temp
# directory, then execs the one the user asked for (default: install).
#
# Why download both on every run:
#   install.sh has a reconciliation block that copies `uninstall.sh` sitting
#   next to it into $FP_HOME during install. Before this bootstrap, the
#   `curl | sh` path gave the user install.sh only -- the reconciliation
#   found nothing to copy, and users ended up with no on-disk uninstaller.
#   Having both files present at install time closes that silent gap.
#
# Usage:
#   curl -fsSL https://get.falconpulsar.com/linux | sudo bash
#       → install (default)
#   curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- uninstall
#       → uninstall
#   curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- uninstall --purge --yes
#       → uninstall with passthrough flags
#   curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- help
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

# Release URLs. GitHub's `/releases/latest/download/` alias excludes
# prereleases, and FalconPulsar currently ships prerelease tags only
# (v0.1.4-alpha.X) — the alias 404s. So the newest release tag (prereleases
# included) is resolved via the GitHub API below, mirroring
# shared/lib/fpcli.sh, with the /latest alias kept only as the fallback
# when the API is unreachable. No version hard-coded here -- one bootstrap
# script works across versions. FP_RELEASE_BASE skips the lookup entirely.
FP_REPO="${FP_REPO:-FalconPulsar/falconpulsar-installer}"
FP_RELEASE_BASE="${FP_RELEASE_BASE:-}"

# Small helpers so the bootstrap has a consistent voice before it hands off
# to the real script. Colors only if stderr is a TTY.
if [ -t 2 ]; then
    _c_bold=$'\033[1m'; _c_cyan=$'\033[36m'; _c_red=$'\033[31m'; _c_reset=$'\033[0m'
else
    _c_bold=''; _c_cyan=''; _c_red=''; _c_reset=''
fi
bs_info() { printf '%s[bootstrap]%s %s\n' "$_c_cyan" "$_c_reset" "$1" >&2; }
bs_err()  { printf '%s[bootstrap] ERROR:%s %s\n' "$_c_red"  "$_c_reset" "$1" >&2; }

show_help() {
    cat >&2 <<EOF
${_c_bold}FalconPulsar Linux bootstrap${_c_reset}

Usage:
  curl -fsSL https://get.falconpulsar.com/linux | sudo bash [-- SUBCOMMAND [FLAGS]]

Subcommands:
  install      (default)  Install FalconPulsar.
  uninstall               Remove FalconPulsar. Pass --purge to also
                          delete the database and --yes for no prompts.
  help                    Show this message.

Examples:
  # Install (same as having no subcommand)
  curl -fsSL https://get.falconpulsar.com/linux | sudo bash
  curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- install

  # Uninstall, keep data (default)
  curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- uninstall

  # Uninstall everything, unattended
  curl -fsSL https://get.falconpulsar.com/linux | sudo bash -s -- uninstall --purge --yes

Environment overrides:
  FP_REPO           GitHub repository the release assets are pulled from
                    (default: ${FP_REPO})
  FP_RELEASE_BASE   override the release-asset base URL and skip the
                    GitHub API release lookup entirely
EOF
}

# Argument parsing -- first positional arg is the subcommand, the rest is
# forwarded verbatim to the underlying script.
SUBCOMMAND="${1:-install}"
shift >/dev/null 2>&1 || true

case "$SUBCOMMAND" in
    install|i)
        ACTION=install
        ;;
    uninstall|u|remove)
        ACTION=uninstall
        ;;
    help|--help|-h)
        show_help
        exit 0
        ;;
    *)
        bs_err "Unknown subcommand: '$SUBCOMMAND'"
        bs_err "Run with 'help' for usage."
        exit 2
        ;;
esac

# Download both bundles into the same temp dir so that, when install.sh
# runs, its reconciliation block finds uninstall.sh next to it and copies
# it into \$FP_HOME/uninstall.sh. The user ends up with a local
# uninstaller even on a fresh install.
TMP="$(mktemp -d -t falconpulsar-bootstrap-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

INSTALL_SH="$TMP/install.sh"
UNINSTALL_SH="$TMP/uninstall.sh"

# Resolve the newest release tag (prereleases included) via the GitHub API
# — same idiom as fp_download_release_asset in shared/lib/fpcli.sh: one
# `/releases?per_page=1` call, tag parsed with awk (no jq dependency).
# Only when the API is unreachable (offline, rate-limited proxy, ...) fall
# back to the /releases/latest alias and hope a stable release exists.
if [ -z "$FP_RELEASE_BASE" ]; then
    API_RELEASES="https://api.github.com/repos/${FP_REPO}/releases?per_page=1"
    API_JSON="$TMP/releases.json"
    HTTP_CODE="$(curl -sSL -o "$API_JSON" -w '%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        "$API_RELEASES" 2>/dev/null || true)"
    TAG=""
    if [ "$HTTP_CODE" = "200" ]; then
        TAG="$(awk -F'"' '/"tag_name":/ { print $4; exit }' "$API_JSON" 2>/dev/null)"
    fi
    rm -f "$API_JSON"
    if [ -n "$TAG" ]; then
        bs_info "Newest release: $TAG"
        FP_RELEASE_BASE="https://github.com/${FP_REPO}/releases/download/${TAG}"
    else
        bs_info "GitHub API gave no release (HTTP ${HTTP_CODE:-no-response}) -- falling back to /releases/latest"
        FP_RELEASE_BASE="https://github.com/${FP_REPO}/releases/latest/download"
    fi
fi
INSTALL_URL="${FP_RELEASE_BASE}/install-linux.sh"
UNINSTALL_URL="${FP_RELEASE_BASE}/uninstall-linux.sh"

bs_info "Downloading install bundle..."
if ! curl -fsSL "$INSTALL_URL" -o "$INSTALL_SH"; then
    bs_err "Failed to download $INSTALL_URL"
    exit 1
fi
if [ ! -s "$INSTALL_SH" ]; then
    bs_err "Downloaded install bundle is empty: $INSTALL_URL"
    exit 1
fi

bs_info "Downloading uninstall bundle..."
if ! curl -fsSL "$UNINSTALL_URL" -o "$UNINSTALL_SH"; then
    bs_err "Failed to download $UNINSTALL_URL"
    exit 1
fi
if [ ! -s "$UNINSTALL_SH" ]; then
    bs_err "Downloaded uninstall bundle is empty: $UNINSTALL_URL"
    exit 1
fi

chmod +x "$INSTALL_SH" "$UNINSTALL_SH"

# Exec the right script. Keep the temp dir for the duration of the child
# process -- the trap above removes it on exit. Passing "$@" forwards any
# flags the user gave after the subcommand (e.g. --purge --yes for uninstall,
# or --mode docker for install).
#
# When the user invokes us via `curl ... | sudo bash`, this bootstrap's
# stdin is the curl pipe — already at EOF by the time the child runs.
# The child installer needs a real TTY to prompt for legal, registry
# credentials, admin password, etc. Reattach stdin to /dev/tty whenever
# one is available so those prompts actually work. Fall back to the
# inherited stdin on systems without /dev/tty (rare; usually CI runners,
# in which case --yes / FP_ASSUME_YES=1 should be set anyway).
STDIN_REDIR=""
if [ -r /dev/tty ]; then
    STDIN_REDIR="/dev/tty"
fi

case "$ACTION" in
    install)
        bs_info "Running installer ($INSTALL_SH)"
        if [ -n "$STDIN_REDIR" ]; then
            bash "$INSTALL_SH" "$@" < "$STDIN_REDIR"
        else
            bash "$INSTALL_SH" "$@"
        fi
        ;;
    uninstall)
        bs_info "Running uninstaller ($UNINSTALL_SH)"
        if [ -n "$STDIN_REDIR" ]; then
            bash "$UNINSTALL_SH" "$@" < "$STDIN_REDIR"
        else
            bash "$UNINSTALL_SH" "$@"
        fi
        ;;
esac
