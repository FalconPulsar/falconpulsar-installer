#!/usr/bin/env bash
# =============================================================================
# bundle.sh — produce a single self-contained installer script.
#
# Inlines shared/lib/*.sh into linux/install.sh or macos/install.sh and
# embeds shared/compose.yml as a heredoc that the installer extracts at
# runtime. This lets users do `curl ... | bash` without cloning the repo.
#
# Usage:
#   ./bundle.sh linux > install-linux.sh
#   ./bundle.sh macos > install-macos.sh
#
# Strategy:
#   - Strip the `. "${REPO_ROOT}/shared/lib/*.sh"` source statements
#   - Replace them with the literal contents of those files
#   - Replace the `${REPO_ROOT}/shared/compose.yml` install with an inline
#     heredoc that writes the file to a temp dir and points the rest of the
#     installer at it via REPO_ROOT
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

PLATFORM="${1:?usage: $0 <linux|macos>}"

case "$PLATFORM" in
    linux|macos) ;;
    *) echo "ERROR: platform must be 'linux' or 'macos'" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
INSTALL_SH="${REPO_ROOT}/${PLATFORM}/install.sh"
LIB_DIR="${REPO_ROOT}/shared/lib"
COMPOSE_YML="${REPO_ROOT}/shared/compose.yml"

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

set -o errexit
set -o nounset
set -o pipefail

# Extract the embedded compose.yml + libs into a temp dir and use that as
# REPO_ROOT for the installer body below.
__FP_BUNDLE_DIR="$(mktemp -d -t falconpulsar-installer-XXXXXXXX)"
trap 'rm -rf "$__FP_BUNDLE_DIR"' EXIT
mkdir -p "${__FP_BUNDLE_DIR}/shared/lib" "${__FP_BUNDLE_DIR}/linux/systemd"

BUNDLE_HEADER

# ── Embed shared/lib/*.sh ────────────────────────────────────────────────────
for libname in common.sh checks.sh prompts.sh bootstrap.sh registry_auth.sh fpcli.sh existing.sh; do
    libfile="${LIB_DIR}/${libname}"
    [ -f "$libfile" ] || { echo "ERROR: missing $libfile" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/shared/lib/%s" <<'\''__FP_EOF_%s__'\''\n' "$libname" "$libname"
    cat "$libfile"
    printf '\n__FP_EOF_%s__\n\n' "$libname"
done

# ── Embed shared/compose.yml ────────────────────────────────────────────────
[ -f "$COMPOSE_YML" ] || { echo "ERROR: missing $COMPOSE_YML" >&2; exit 1; }
printf 'cat >"${__FP_BUNDLE_DIR}/shared/compose.yml" <<'\''__FP_EOF_COMPOSE__'\''\n'
cat "$COMPOSE_YML"
printf '\n__FP_EOF_COMPOSE__\n\n'

# ── Embed linux/systemd/falconpulsar.service.template (Linux bundle only) ──
if [ "$PLATFORM" = "linux" ]; then
    SYSTEMD_TPL="${REPO_ROOT}/linux/systemd/falconpulsar.service.template"
    [ -f "$SYSTEMD_TPL" ] || { echo "ERROR: missing $SYSTEMD_TPL" >&2; exit 1; }
    printf 'cat >"${__FP_BUNDLE_DIR}/linux/systemd/falconpulsar.service.template" <<'\''__FP_EOF_SYSTEMD__'\''\n'
    cat "$SYSTEMD_TPL"
    printf '\n__FP_EOF_SYSTEMD__\n\n'
fi

# ── Embed install.sh body ──────────────────────────────────────────────────
# We strip the existing shebang, set/trap lines, and SCRIPT_DIR/REPO_ROOT
# resolution (we provide our own REPO_ROOT pointing at the temp dir). The
# `. shared/lib/*.sh` source lines are kept verbatim — they will pick up the
# extracted files via REPO_ROOT.
echo '# ---------- begin embedded install.sh ----------'
echo "REPO_ROOT=\"\${__FP_BUNDLE_DIR}\""
echo 'SCRIPT_DIR="${REPO_ROOT}/'"${PLATFORM}"'"'
echo
# Skip the first 50 lines of header (shebang, top comment, set -o, SCRIPT_DIR/
# REPO_ROOT resolution) — start from the first "# shellcheck source" line.
awk '
    /^# shellcheck source=/ { found=1 }
    found { print }
' "$INSTALL_SH"
echo '# ---------- end embedded install.sh ----------'
