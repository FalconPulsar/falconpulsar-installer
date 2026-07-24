#!/usr/bin/env bash
# =============================================================================
# bundle.sh — produce a single self-contained install/uninstall script.
#
# Inlines shared/lib/*.sh into the chosen top-level script and embeds the
# auxiliary files (compose.yml, systemd template, uninstall.sh) as here-
# docs that the script extracts at runtime. This lets users do
# `curl ... | bash` without cloning the repo.
#
# Usage:
#   ./bundle.sh linux            > install-linux.sh
#   ./bundle.sh macos            > install-macos.sh
#   ./bundle.sh linux-uninstall  > uninstall-linux.sh
#
# Flavors:
#   linux            install bundle: install.sh + all libs + compose.yml +
#                    systemd template + uninstall.sh (for the in-install
#                    reconciliation copy)
#   macos            install bundle: install.sh + all libs + compose.yml
#   linux-uninstall  lean uninstall bundle: uninstall.sh + common.sh + auth.sh
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

PLATFORM="${1:?usage: $0 <linux|macos|linux-uninstall>}"

case "$PLATFORM" in
    linux|macos|linux-uninstall) ;;
    *) echo "ERROR: platform must be 'linux', 'macos', or 'linux-uninstall'" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
# Which top-level script becomes the bundle body depends on the flavor.
# 'linux' and 'macos' bundle install.sh; 'linux-uninstall' bundles
# linux/uninstall.sh so users can `curl .../uninstall-linux.sh | bash`
# against a broken install that doesn't have $FP_HOME/uninstall.sh.
if [ "$PLATFORM" = "linux-uninstall" ]; then
    INSTALL_SH="${REPO_ROOT}/linux/uninstall.sh"
    SUBDIR="linux"
else
    INSTALL_SH="${REPO_ROOT}/${PLATFORM}/install.sh"
    SUBDIR="$PLATFORM"
fi
UNINSTALL_SH="${REPO_ROOT}/linux/uninstall.sh"
LIB_DIR="${REPO_ROOT}/shared/lib"
COMPOSE_YML="${REPO_ROOT}/shared/compose.yml"
NGINX_CONF="${REPO_ROOT}/shared/nginx.conf"
GATEWAY_YAML="${REPO_ROOT}/shared/gateway.yaml"

# ── Header ──────────────────────────────────────────────────────────────────
cat <<'BUNDLE_HEADER'
#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — bundled installer (auto-generated, do not edit by hand)
# =============================================================================
# This file is produced by .github/scripts/bundle.sh from the source files in
# the falconpulsar-installer repository. To make changes, edit the source
# files and re-run the bundler. To inspect the source, see:
#   https://github.com/FalconPulsar/falconpulsar-installer
# =============================================================================

# ── Bash guard (POSIX-only up to here) ──────────────────────────────────────
# This installer uses bash features throughout (arrays, [[ ]], local, …).
# The shebang above is BYPASSED when a shell is named explicitly
# (`sh install-linux.sh` — dash on Debian/Ubuntu) or when piped
# (`curl … | sh`), which used to die with a cryptic
#   Syntax error: "(" unexpected
# the moment dash parsed the first bash array. Re-exec under bash when we
# were started from a file; when piped into a non-bash shell there is no
# file to re-exec, so fail with the exact command to run instead.
if [ -z "${BASH_VERSION:-}" ]; then
    if [ -f "$0" ]; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: this installer requires bash (it was piped into a POSIX sh)." >&2
    echo "       Run it with bash instead:" >&2
    echo "         curl -fsSL https://get.falconpulsar.com/linux | sudo bash" >&2
    exit 1
fi

set -o errexit
set -o nounset
set -o pipefail

# Extract the embedded compose.yml + libs into a temp dir and use that as
# REPO_ROOT for the installer body below.
__FP_BUNDLE_DIR="$(mktemp -d -t falconpulsar-installer-XXXXXXXX)"
trap 'rm -rf "$__FP_BUNDLE_DIR"' EXIT
mkdir -p "${__FP_BUNDLE_DIR}/shared/lib" "${__FP_BUNDLE_DIR}/linux" "${__FP_BUNDLE_DIR}/linux/systemd" "${__FP_BUNDLE_DIR}/macos"

BUNDLE_HEADER

# ── Embed shared/lib/*.sh ────────────────────────────────────────────────────
# Pick only the libs each flavor actually sources. The uninstall flavor is
# lean: uninstall.sh needs common.sh (fatal-path helpers), auth.sh
# (admin-password challenge), and fpcli.sh (fp_remove_path_append, which
# strips the installer's PATH line from the user's shell rc — without it
# uninstall.sh falls back to a no-op stub and the rc line is orphaned).
# The install flavor needs the full set.
if [ "$PLATFORM" = "linux-uninstall" ]; then
    LIB_LIST="common.sh auth.sh fpcli.sh"
else
    LIB_LIST="common.sh checks.sh prompts.sh bootstrap.sh registry_auth.sh fpcli.sh existing.sh auth.sh"
fi
for libname in $LIB_LIST; do
    libfile="${LIB_DIR}/${libname}"
    [ -f "$libfile" ] || { echo "ERROR: missing $libfile" >&2; exit 1; }
    libsafe="$(echo "$libname" | tr '.' '_')"
    printf 'cat >"${__FP_BUNDLE_DIR}/shared/lib/%s" <<'\''__FP_EOF_%s__'\''\n' "$libname" "$libsafe"
    cat "$libfile"
    printf '\n__FP_EOF_%s__\n\n' "$libsafe"
done

# ── Embed shared/compose.yml (install flavors only) ─────────────────────────
# The uninstall bundle doesn't need it -- uninstall.sh reads compose from
# the already-installed $FP_HOME/compose.yml if it exists.
if [ "$PLATFORM" != "linux-uninstall" ]; then
    [ -f "$COMPOSE_YML" ] || { echo "ERROR: missing $COMPOSE_YML" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/shared/compose.yml" <<'\''__FP_EOF_COMPOSE__'\''\n'
    cat "$COMPOSE_YML"
    printf '\n__FP_EOF_COMPOSE__\n\n'
fi

# ── Embed shared/nginx.conf (install flavors only) ──────────────────────────
# Step 6 of install.sh runs:
#   install ... ${REPO_ROOT}/shared/nginx.conf ${FP_HOME}/nginx.conf
# (mac install.sh does the same via cp). Without this embed, the bundled
# installer fails with `install: No such file or directory` after the
# user has already entered admin credentials.
if [ "$PLATFORM" != "linux-uninstall" ]; then
    [ -f "$NGINX_CONF" ] || { echo "ERROR: missing $NGINX_CONF" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/shared/nginx.conf" <<'\''__FP_EOF_NGINX__'\''\n'
    cat "$NGINX_CONF"
    printf '\n__FP_EOF_NGINX__\n\n'
fi

# ── Embed shared/gateway.yaml (install flavors only) ────────────────────────
# gateway.yaml is a required stack file: install.sh copies it into
# $FP_HOME unconditionally (the AI Gateway is a mandatory service, same
# as compose.yml and nginx.conf above). Without this embed the bundled
# installer would have nothing to copy.
if [ "$PLATFORM" != "linux-uninstall" ]; then
    [ -f "$GATEWAY_YAML" ] || { echo "ERROR: missing $GATEWAY_YAML" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/shared/gateway.yaml" <<'\''__FP_EOF_GATEWAY__'\''\n'
    cat "$GATEWAY_YAML"
    printf '\n__FP_EOF_GATEWAY__\n\n'
fi

# ── Embed linux/systemd/falconpulsar.service.template (linux install only) ──
if [ "$PLATFORM" = "linux" ]; then
    SYSTEMD_TPL="${REPO_ROOT}/linux/systemd/falconpulsar.service.template"
    [ -f "$SYSTEMD_TPL" ] || { echo "ERROR: missing $SYSTEMD_TPL" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/linux/systemd/falconpulsar.service.template" <<'\''__FP_EOF_SYSTEMD__'\''\n'
    cat "$SYSTEMD_TPL"
    printf '\n__FP_EOF_SYSTEMD__\n\n'
fi

# ── Embed linux/uninstall.sh next to install.sh (linux install only) ───────
# install.sh's reconciliation block copies ${SCRIPT_DIR}/uninstall.sh into
# $FP_HOME/uninstall.sh during install. Before this embed, the bundled
# curl | sh path had no uninstall.sh next to install.sh, so users ended
# up with a freshly-installed stack and no on-disk uninstaller.
if [ "$PLATFORM" = "linux" ]; then
    [ -f "$UNINSTALL_SH" ] || { echo "ERROR: missing $UNINSTALL_SH" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/linux/uninstall.sh" <<'\''__FP_EOF_UNINSTALL__'\''\n'
    cat "$UNINSTALL_SH"
    printf '\n__FP_EOF_UNINSTALL__\n'
    # Ensure it's executable so install(1) can copy it with sensible perms.
    echo 'chmod +x "${__FP_BUNDLE_DIR}/linux/uninstall.sh"'
    echo
fi

# ── Embed top-level script body ────────────────────────────────────────────
# Strip the source file's shebang, set/trap lines, and SCRIPT_DIR/REPO_ROOT
# resolution (we provide our own REPO_ROOT pointing at the temp dir). The
# `. shared/lib/*.sh` source lines are kept verbatim -- they pick up the
# extracted files via REPO_ROOT.
if [ "$PLATFORM" = "linux-uninstall" ]; then
    echo '# ---------- begin embedded uninstall.sh ----------'
else
    echo '# ---------- begin embedded install.sh ----------'
fi
echo "REPO_ROOT=\"\${__FP_BUNDLE_DIR}\""
echo 'SCRIPT_DIR="${REPO_ROOT}/'"${SUBDIR}"'"'
echo
# Skip the header up to and including the column-0 REPO_ROOT= resolution
# line — the last header line in install.sh and uninstall.sh, and the one
# this bundle replaces with its own definition above. Do NOT anchor on the
# first "# shellcheck source=" line instead: uninstall.sh's markers are
# indented inside its lib-detection if-block, so a marker anchor either
# misses entirely (column-0 match — the body comes out empty) or cuts
# mid-block (whitespace-tolerant match — the orphaned else/fi is a syntax
# error).
grep -c '^REPO_ROOT=' "$INSTALL_SH" | grep -qx '1' \
    || { echo "ERROR: expected exactly one column-0 REPO_ROOT= line in $INSTALL_SH" >&2; exit 1; }
awk '
    found { print }
    /^REPO_ROOT=/ { found=1 }
' "$INSTALL_SH"
if [ "$PLATFORM" = "linux-uninstall" ]; then
    echo '# ---------- end embedded uninstall.sh ----------'
else
    echo '# ---------- end embedded install.sh ----------'
fi
