#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — local macOS DMG build
# =============================================================================
# Builds FalconPulsar-Setup.dmg under ./dist/ by:
#   1. Compiling the SwiftUI installer and the menu bar app
#   2. Assembling Installer.app with Menu Bar.app embedded in Resources/
#   3. Generating AppIcon.icns from the falcon logo
#   4. Signing both bundles ad-hoc (inner first, then outer — non-deep)
#   5. Packaging into a UDZO DMG
#   6. Cleaning up intermediate .app bundles so Launchpad only knows about
#      the DMG, not our dev build directories
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$REPO_ROOT"

VERSION="${FP_VERSION:-0.1.0}"
INSTALLER_BUNDLE="dist/installer-bundle/FalconPulsar Installer.app"
MB_BUNDLE="$INSTALLER_BUNDLE/Contents/Resources/FalconPulsar Menu Bar.app"
DMG_STAGING="dist/dmg-staging"
DMG_OUTPUT="dist/FalconPulsar-Setup.dmg"
ICONSET_TMP="/tmp/FalconPulsar.iconset"
ICNS_TMP="/tmp/AppIcon.icns"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

log() { printf "[build-dmg] %s\n" "$*"; }

# ── Step 1: Compile binaries ────────────────────────────────────────────────
log "compiling installer-app"
( cd macos/installer-app && swift build -c release >/dev/null )

log "compiling menu-bar-app"
( cd macos/menu-bar-app \
  && mkdir -p .build \
  && swiftc FalconPulsar/main.swift \
            FalconPulsar/AppDelegate.swift \
            FalconPulsar/Logo.swift \
       -o .build/FalconPulsarMenuBar \
       -framework AppKit -framework UserNotifications -O )

# ── Step 2: Build AppIcon.icns ─────────────────────────────────────────────
log "generating AppIcon.icns"
rm -rf "$ICONSET_TMP"
mkdir -p "$ICONSET_TMP"
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s windows/assets/falcon-logo.png \
       --out "$ICONSET_TMP/icon_${s}x${s}.png" >/dev/null 2>&1
done
cp "$ICONSET_TMP/icon_32x32.png"     "$ICONSET_TMP/icon_16x16@2x.png"
cp "$ICONSET_TMP/icon_64x64.png"     "$ICONSET_TMP/icon_32x32@2x.png"
cp "$ICONSET_TMP/icon_256x256.png"   "$ICONSET_TMP/icon_128x128@2x.png"
cp "$ICONSET_TMP/icon_512x512.png"   "$ICONSET_TMP/icon_256x256@2x.png"
cp "$ICONSET_TMP/icon_1024x1024.png" "$ICONSET_TMP/icon_512x512@2x.png"
rm -f "$ICONSET_TMP/icon_64x64.png" "$ICONSET_TMP/icon_1024x1024.png"
iconutil -c icns "$ICONSET_TMP" -o "$ICNS_TMP"

# ── Step 3: Assemble Installer.app ──────────────────────────────────────────
log "assembling Installer.app"
rm -rf "$INSTALLER_BUNDLE"
mkdir -p "$INSTALLER_BUNDLE/Contents/MacOS" "$INSTALLER_BUNDLE/Contents/Resources"
cp macos/installer-app/.build/release/FalconPulsarInstaller \
   "$INSTALLER_BUNDLE/Contents/MacOS/"
cp "$ICNS_TMP" "$INSTALLER_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$INSTALLER_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FalconPulsarInstaller</string>
  <key>CFBundleIdentifier</key><string>com.falconpulsar.installer</string>
  <key>CFBundleName</key><string>FalconPulsar Installer</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# ── Step 4: Embed Menu Bar.app in Installer.app/Contents/Resources ──────────
log "embedding Menu Bar.app in Installer.app Resources"
mkdir -p "$MB_BUNDLE/Contents/MacOS" "$MB_BUNDLE/Contents/Resources"
cp macos/menu-bar-app/.build/FalconPulsarMenuBar "$MB_BUNDLE/Contents/MacOS/"
sips -z 36 36 windows/assets/falcon-logo.png \
     --out "$MB_BUNDLE/Contents/Resources/MenuBarIcon.png" >/dev/null 2>&1
cp "$ICNS_TMP" "$MB_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$MB_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FalconPulsarMenuBar</string>
  <key>CFBundleIdentifier</key><string>com.falconpulsar.menubar</string>
  <key>CFBundleName</key><string>FalconPulsar</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# ── Step 5: Codesign inner-first-then-outer (non-deep) ──────────────────────
log "ad-hoc signing bundles (inner first, then outer)"
codesign --force --sign - "$MB_BUNDLE" >/dev/null 2>&1
codesign --force --sign - "$INSTALLER_BUNDLE" >/dev/null 2>&1
codesign -vvv --strict "$MB_BUNDLE"

# ── Step 6: Package into UDZO DMG ───────────────────────────────────────────
log "packaging DMG"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$INSTALLER_BUNDLE" "$DMG_STAGING/"
rm -f "$DMG_OUTPUT"
hdiutil create \
  -volname "FalconPulsar Installer" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_OUTPUT" >/dev/null

# ── Step 7: Clean up intermediate bundles so Launchpad doesn't index them ──
log "cleaning up intermediate bundles"
"$LSREGISTER" -u "$(pwd)/$INSTALLER_BUNDLE" 2>/dev/null || true
"$LSREGISTER" -u "$(pwd)/$DMG_STAGING/FalconPulsar Installer.app" 2>/dev/null || true
rm -rf "dist/installer-bundle"
rm -rf "$DMG_STAGING"

log "done: $DMG_OUTPUT ($(du -h "$DMG_OUTPUT" | awk '{print $1}'))"
