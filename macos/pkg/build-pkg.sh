#!/bin/bash
# =============================================================================
# build-pkg.sh — Build the macOS .pkg installer from the bash scripts.
#
# Uses pkgbuild + productbuild (shipped with Xcode command-line tools).
# Output: macos/pkg/output/FalconPulsar-Setup.pkg
#
# The .pkg contains:
#   - The bash installer (macos/install.sh, macos/uninstall.sh)
#   - Shared libraries (shared/lib/*.sh)
#   - Shared compose.yml + init schema
#   - postinstall script that runs install.sh non-interactively
#
# The .pkg GUI shows:
#   - Welcome page (branding, version, requirements)
#   - License page (legal terms with links)
#   - Install (runs postinstall which calls install.sh)
#   - Conclusion (URLs, management commands)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION="${1:-0.1.0}"
OUTPUT_DIR="$SCRIPT_DIR/output"
STAGING_DIR="$SCRIPT_DIR/staging"
PKG_ID="com.falconpulsar.installer"

echo "Building FalconPulsar.pkg v${VERSION}"

# Clean previous builds
rm -rf "$STAGING_DIR" "$OUTPUT_DIR"
mkdir -p "$STAGING_DIR/falconpulsar-installer/macos" \
         "$STAGING_DIR/falconpulsar-installer/shared/lib" \
         "$OUTPUT_DIR"

# Stage the installer files (same layout the postinstall expects)
cp "$REPO_ROOT/macos/install.sh"    "$STAGING_DIR/falconpulsar-installer/macos/"
cp "$REPO_ROOT/macos/uninstall.sh"  "$STAGING_DIR/falconpulsar-installer/macos/"
cp "$REPO_ROOT/shared/compose.yml"  "$STAGING_DIR/falconpulsar-installer/shared/"
cp "$REPO_ROOT/shared/lib/"*.sh     "$STAGING_DIR/falconpulsar-installer/shared/lib/"
if [ -f "$REPO_ROOT/shared/init.example.json" ]; then
    cp "$REPO_ROOT/shared/init.example.json" "$STAGING_DIR/falconpulsar-installer/shared/"
fi

chmod +x "$STAGING_DIR/falconpulsar-installer/macos/"*.sh
chmod +x "$STAGING_DIR/falconpulsar-installer/shared/lib/"*.sh

# Ensure postinstall is executable
chmod +x "$SCRIPT_DIR/scripts/postinstall"

# Step 1: Build the component package
# The payload goes to /tmp/falconpulsar-installer (temporary staging).
# The postinstall script runs the actual installer from there.
pkgbuild \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --root "$STAGING_DIR" \
    --install-location "/tmp" \
    --scripts "$SCRIPT_DIR/scripts" \
    "$OUTPUT_DIR/FalconPulsar-component.pkg"

# Step 2: Create the distribution XML for productbuild
cat > "$OUTPUT_DIR/distribution.xml" <<DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>FalconPulsar</title>
    <organization>com.falconpulsar</organization>
    <background file="background.png" alignment="bottomleft" scaling="proportional" />
    <welcome file="welcome.html" />
    <license file="license.html" />
    <conclusion file="conclusion.html" />
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64" />
    <os-version min="14.0" />
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_ID" />
        </line>
    </choices-outline>
    <choice id="default" />
    <choice id="$PKG_ID" visible="false">
        <pkg-ref id="$PKG_ID" />
    </choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">FalconPulsar-component.pkg</pkg-ref>
</installer-gui-script>
DISTXML

# Step 3: Build the final product package with GUI resources
productbuild \
    --distribution "$OUTPUT_DIR/distribution.xml" \
    --package-path "$OUTPUT_DIR" \
    --resources "$SCRIPT_DIR/resources" \
    "$OUTPUT_DIR/FalconPulsar-Setup-v${VERSION}.pkg"

# Unversioned alias for stable redirect URLs
cp "$OUTPUT_DIR/FalconPulsar-Setup-v${VERSION}.pkg" "$OUTPUT_DIR/FalconPulsar-Setup.pkg"

# Clean up intermediate files
rm -f "$OUTPUT_DIR/FalconPulsar-component.pkg" "$OUTPUT_DIR/distribution.xml"
rm -rf "$STAGING_DIR"

echo ""
echo "Built:"
ls -lh "$OUTPUT_DIR/"*.pkg
echo ""
echo "To test: open $OUTPUT_DIR/FalconPulsar-Setup-v${VERSION}.pkg"
