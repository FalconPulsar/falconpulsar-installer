#!/usr/bin/env bash
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

# Release URLs. `/releases/latest/download/` is a stable GitHub alias that
# always resolves to the most recent published release's asset with the
# matching name. No version hard-coded here -- one bootstrap script works
# across versions.
FP_RELEASE_BASE="${FP_RELEASE_BASE:-https://github.com/FalconPulsar/falconpulsar-installer/releases/latest/download}"
INSTALL_URL="${FP_RELEASE_BASE}/install-linux.sh"
UNINSTALL_URL="${FP_RELEASE_BASE}/uninstall-linux.sh"

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
  FP_RELEASE_BASE   override the release-asset base URL
                    (default: ${FP_RELEASE_BASE})
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
