#!/usr/bin/env bash
# =============================================================================
# FalconPulsar — local macOS DMG build
# =============================================================================
# Builds FalconPulsar-Setup.dmg under ./dist/ by:
#   1. Compiling the SwiftUI installer and the menu bar app
#   2. Assembling Installer.app with Menu Bar.app embedded in Resources/
#   3. Generating AppIcon.icns from the falcon logo
#   4. Signing inner-first-then-outer: fp binary → MenuBar.app → Installer.app
#   5. Packaging into a UDZO DMG
#   6. (FP_SIGN=1 only) Signing the DMG and submitting it to Apple for
#      notarization, then stapling the ticket so Gatekeeper accepts the
#      download offline.
#   7. Cleaning up intermediate .app bundles so Launchpad only knows about
#      the DMG, not our dev build directories
#
# Two signing modes:
#
#   (A) LOCAL / CONTRIBUTOR (default, no env vars)
#       Uses ad-hoc signatures (`codesign --sign -`). The resulting DMG
#       works for local testing but is NOT Gatekeeper-accepted — users
#       have to right-click → Open the first time. This is the path every
#       PR build and every forked contributor hits.
#
#   (B) RELEASE (FP_SIGN=1)
#       Uses a real Developer ID Application certificate + Hardened Runtime
#       + notarization + stapling. Produces a DMG that double-clicks
#       cleanly on any Mac with internet OR offline (ticket is stapled).
#       Required env vars:
#         FP_SIGN_IDENTITY        Full cert name, e.g.
#                                 "Developer ID Application: Jane (ABCD1234)"
#         FP_NOTARY_KEY_ID        App Store Connect API Key ID (10 chars)
#         FP_NOTARY_ISSUER_ID     Issuer UUID from App Store Connect
#         FP_NOTARY_KEY_P8_PATH   Path to the .p8 private key on disk
#       If any is missing when FP_SIGN=1, the build aborts. It does NOT
#       silently fall back to ad-hoc — that's how unsigned artifacts get
#       shipped by accident.
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$REPO_ROOT"

VERSION="${FP_VERSION:-0.1.0}"
INSTALLER_BUNDLE="dist/installer-bundle/FalconPulsar Installer.app"
MB_BUNDLE="$INSTALLER_BUNDLE/Contents/Resources/FalconPulsar Menu Bar.app"

# Entitlements: both plists are intentionally empty <dict>s — that means
# "run under Hardened Runtime with zero exceptions", which is the most
# restrictive (and safest) choice. Every capability our apps actually
# use — spawning /bin/bash and docker via Process(), connecting to
# 127.0.0.1 — is allowed under Hardened Runtime without any flag.
#
# IMPORTANT: the .plist files contain NO XML comments. codesign's
# entitlements parser (AMFIUnserializeXML) is stricter than libxml and
# chokes on non-ASCII characters (em-dashes, smart quotes) inside
# comments, emitting "syntax error near line N" with a useless line
# number. Keep those files minimal and ASCII-only. Put rationale here
# instead, where only humans read it.
INSTALLER_ENTITLEMENTS="$REPO_ROOT/macos/installer-app/Entitlements.plist"
MB_ENTITLEMENTS="$REPO_ROOT/macos/menu-bar-app/Entitlements.plist"
DMG_STAGING="dist/dmg-staging"
DMG_OUTPUT="dist/FalconPulsar-Setup.dmg"
ICONSET_TMP="/tmp/FalconPulsar.iconset"
ICNS_TMP="/tmp/AppIcon.icns"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

log() { printf "[build-dmg] %s\n" "$*"; }
warn() { printf "[build-dmg] WARN: %s\n" "$*" >&2; }
die() { printf "[build-dmg] ERROR: %s\n" "$*" >&2; exit 1; }

# ── Signing-mode validation ────────────────────────────────────────────────
# When FP_SIGN=1, every secret we need must be present and usable. The
# checks here run BEFORE compilation so we fail fast on a misconfigured
# release rather than after 3 minutes of builds.
FP_SIGN="${FP_SIGN:-0}"
if [ "$FP_SIGN" = "1" ]; then
    [ -n "${FP_SIGN_IDENTITY:-}" ]      || die "FP_SIGN=1 but FP_SIGN_IDENTITY is not set"
    [ -n "${FP_NOTARY_KEY_ID:-}" ]      || die "FP_SIGN=1 but FP_NOTARY_KEY_ID is not set"
    [ -n "${FP_NOTARY_ISSUER_ID:-}" ]   || die "FP_SIGN=1 but FP_NOTARY_ISSUER_ID is not set"
    [ -n "${FP_NOTARY_KEY_P8_PATH:-}" ] || die "FP_SIGN=1 but FP_NOTARY_KEY_P8_PATH is not set"
    [ -f "$FP_NOTARY_KEY_P8_PATH" ]     || die "FP_SIGN=1 but $FP_NOTARY_KEY_P8_PATH does not exist"
    # Confirm the identity is actually importable — `security find-identity`
    # lists every codesigning identity the current keychain can see.
    if ! security find-identity -v -p codesigning | grep -qF "$FP_SIGN_IDENTITY"; then
        die "signing identity not found in keychain: $FP_SIGN_IDENTITY"
    fi
    log "signing mode: RELEASE (Developer ID + Hardened Runtime + notarization)"
    log "  identity: $FP_SIGN_IDENTITY"
else
    log "signing mode: ad-hoc (set FP_SIGN=1 with credentials for a signed release)"
fi

# ── Signing helpers ────────────────────────────────────────────────────────
# These branch on FP_SIGN once so the rest of the script doesn't have to.
# Inner-first rule: always sign embedded binaries/frameworks BEFORE the
# bundle that contains them. codesign hashes the inner signatures into the
# outer one, so re-signing an outer after modifying inner invalidates it.

sign_binary() {
    local path="$1"
    if [ "$FP_SIGN" = "1" ]; then
        codesign --force \
                 --sign "$FP_SIGN_IDENTITY" \
                 --options runtime \
                 --timestamp \
                 "$path"
    else
        codesign --force --sign - "$path" >/dev/null 2>&1
    fi
}

sign_bundle() {
    local bundle="$1"
    local entitlements="$2"
    if [ "$FP_SIGN" = "1" ]; then
        codesign --force \
                 --sign "$FP_SIGN_IDENTITY" \
                 --options runtime \
                 --timestamp \
                 --entitlements "$entitlements" \
                 "$bundle"
    else
        codesign --force --sign - "$bundle" >/dev/null 2>&1
    fi
}

notarize_and_staple() {
    local dmg="$1"
    if [ "$FP_SIGN" != "1" ]; then return 0; fi

    log "submitting DMG to Apple notary service (this can take 2–10 minutes)"
    # --wait blocks until Apple returns a verdict. Timeout covers the worst
    # case we've seen in practice (~8 min); if Apple's backlog is worse we
    # fail rather than hang the runner forever.
    if ! xcrun notarytool submit "$dmg" \
        --key "$FP_NOTARY_KEY_P8_PATH" \
        --key-id "$FP_NOTARY_KEY_ID" \
        --issuer "$FP_NOTARY_ISSUER_ID" \
        --wait \
        --timeout 30m; then
        # Apple sends us a submission ID even on failure — pull the latest
        # log so the CI output contains the real reason (missing entitlement,
        # unsigned nested binary, etc.) instead of just "failed".
        log "notarization failed — fetching submission log for diagnosis"
        local sub_id
        sub_id="$(xcrun notarytool history \
            --key "$FP_NOTARY_KEY_P8_PATH" \
            --key-id "$FP_NOTARY_KEY_ID" \
            --issuer "$FP_NOTARY_ISSUER_ID" \
            2>/dev/null | awk '/id:/ {print $2; exit}' || true)"
        if [ -n "$sub_id" ]; then
            xcrun notarytool log "$sub_id" \
                --key "$FP_NOTARY_KEY_P8_PATH" \
                --key-id "$FP_NOTARY_KEY_ID" \
                --issuer "$FP_NOTARY_ISSUER_ID" || true
        fi
        die "notarization failed"
    fi

    log "stapling notarization ticket to DMG"
    xcrun stapler staple "$dmg"

    # spctl is the Gatekeeper simulator. If this passes, a user double-
    # clicking the DMG will not see the quarantine / unidentified-developer
    # warning. `--type open --context context:primary-signature` is the
    # correct check for a DMG the user mounts themselves.
    log "verifying Gatekeeper acceptance"
    if ! spctl --assess --type open \
               --context context:primary-signature \
               --verbose=2 "$dmg"; then
        warn "spctl assess failed despite successful staple — investigate"
    fi
}

# ── Step 1: Compile binaries ────────────────────────────────────────────────
log "compiling installer-app"
( cd macos/installer-app && swift build -c release >/dev/null )

log "compiling menu-bar-app"
( cd macos/menu-bar-app \
  && mkdir -p .build \
  && swiftc FalconPulsar/main.swift \
            FalconPulsar/AppDelegate.swift \
            FalconPulsar/Logo.swift \
            FalconPulsar/ConfigBackup.swift \
       -o .build/FalconPulsarMenuBar \
       -framework AppKit -framework UserNotifications -O )

log "compiling fp console CLI (for embed in installer)"
( cd console && mkdir -p dist \
  && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
     go build -ldflags="-s -w" -o dist/fp-macos-arm64 ./cmd/fp )
# Apple Silicon Macs are all arm64; no x86_64 embed needed for Mx builds.

# ── Step 2: Build icns files ───────────────────────────────────────────────
# Two variants:
#   $ICNS_TMP         — installer icon: logo + blue download-arrow badge. Used
#                       on the DMG volume (Finder sidebar, Dock) and on the
#                       FalconPulsar Installer.app.
#   $MB_ICNS_TMP      — plain logo. Used on the menu-bar app which is not an
#                       installer once it has been moved to /Applications.
MB_ICNS_TMP="/tmp/MenuBarIcon.icns"

log "composing installer icon (logo + download badge)"
INSTALLER_ICON_PNG="/tmp/FalconPulsar-InstallerIcon.png"
swift macos/scripts/make-installer-icon.swift \
  windows/assets/falcon-logo.png "$INSTALLER_ICON_PNG" >/dev/null

# Helper: png -> icns
png_to_icns() {
  local src_png="$1" out_icns="$2" iconset
  iconset=$(mktemp -d)
  for s in 16 32 64 128 256 512 1024; do
    sips -z $s $s "$src_png" --out "$iconset/icon_${s}x${s}.png" >/dev/null 2>&1
  done
  cp "$iconset/icon_32x32.png"     "$iconset/icon_16x16@2x.png"
  cp "$iconset/icon_64x64.png"     "$iconset/icon_32x32@2x.png"
  cp "$iconset/icon_256x256.png"   "$iconset/icon_128x128@2x.png"
  cp "$iconset/icon_512x512.png"   "$iconset/icon_256x256@2x.png"
  cp "$iconset/icon_1024x1024.png" "$iconset/icon_512x512@2x.png"
  rm -f "$iconset/icon_64x64.png" "$iconset/icon_1024x1024.png"
  # iconutil requires the dir name to end in .iconset
  local iconset_named="${iconset%/*}/$(basename "$iconset").iconset"
  mv "$iconset" "$iconset_named"
  iconutil -c icns "$iconset_named" -o "$out_icns"
  rm -rf "$iconset_named"
}

log "generating AppIcon.icns (installer)"
png_to_icns "$INSTALLER_ICON_PNG" "$ICNS_TMP"

log "generating AppIcon.icns (menu bar)"
png_to_icns windows/assets/falcon-logo.png "$MB_ICNS_TMP"

# ── Step 3: Assemble Installer.app ──────────────────────────────────────────
log "assembling Installer.app"
rm -rf "$INSTALLER_BUNDLE"
mkdir -p "$INSTALLER_BUNDLE/Contents/MacOS" "$INSTALLER_BUNDLE/Contents/Resources"
cp macos/installer-app/.build/release/FalconPulsarInstaller \
   "$INSTALLER_BUNDLE/Contents/MacOS/"
cp "$ICNS_TMP" "$INSTALLER_BUNDLE/Contents/Resources/AppIcon.icns"

# Embed fp binary so the wizard can install it offline, no GitHub round-trip.
cp console/dist/fp-macos-arm64 "$INSTALLER_BUNDLE/Contents/Resources/fp"
chmod +x "$INSTALLER_BUNDLE/Contents/Resources/fp"
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
cp "$MB_ICNS_TMP" "$MB_BUNDLE/Contents/Resources/AppIcon.icns"
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

# ── Step 5: Codesign inner-first-then-outer ─────────────────────────────────
# Order matters: codesign hashes embedded signatures into the enclosing
# bundle's signature. If we sign the outer first and then modify inner,
# the outer signature is invalidated.
#
#   1. fp (Mach-O inside Installer.app/Contents/Resources)
#   2. MenuBar.app's Mach-O executable
#   3. MenuBar.app bundle
#   4. Installer.app's Mach-O executable
#   5. Installer.app bundle (now contains the signed MenuBar.app)
#
# Note: under Hardened Runtime, every embedded executable (including the
# raw `fp` Go binary) must be signed with `--options runtime`, otherwise
# notarization rejects the whole submission. That's why sign_binary sets
# --options runtime unconditionally in release mode.
log "signing embedded fp binary"
sign_binary "$INSTALLER_BUNDLE/Contents/Resources/fp"

log "signing menu-bar executable"
sign_binary "$MB_BUNDLE/Contents/MacOS/FalconPulsarMenuBar"

log "signing Menu Bar.app bundle"
sign_bundle "$MB_BUNDLE" "$MB_ENTITLEMENTS"

log "signing installer executable"
sign_binary "$INSTALLER_BUNDLE/Contents/MacOS/FalconPulsarInstaller"

log "signing Installer.app bundle"
sign_bundle "$INSTALLER_BUNDLE" "$INSTALLER_ENTITLEMENTS"

# Verify the final bundle signature is valid and self-consistent before we
# package. Catches inner/outer mismatch locally instead of at notarize time.
if [ "$FP_SIGN" = "1" ]; then
    log "verifying Installer.app signature"
    codesign --verify --deep --strict --verbose=2 "$INSTALLER_BUNDLE"
else
    codesign -vvv --strict "$MB_BUNDLE"
fi

# ── Step 6: Package into UDZO DMG (with custom volume icon) ────────────────
# macOS needs the kHasCustomIcon flag set on the root of the DMG for Finder
# to use .VolumeIcon.icns — a UDZO (read-only) image can't be modified after
# creation, so build a UDRW first, attach it, set the flag, detach, then
# convert to UDZO.
log "packaging DMG (staging with custom volume icon)"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$INSTALLER_BUNDLE" "$DMG_STAGING/"
cp "$ICNS_TMP" "$DMG_STAGING/.VolumeIcon.icns"
rm -f "$DMG_OUTPUT"

DMG_TMP="dist/_FalconPulsar-Setup-rw.dmg"
MOUNT_POINT="/tmp/fpdmg-mount-$$"
rm -f "$DMG_TMP"
hdiutil create \
  -volname "FalconPulsar Installer" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDRW \
  "$DMG_TMP" >/dev/null

hdiutil attach "$DMG_TMP" -nobrowse -mountpoint "$MOUNT_POINT" >/dev/null
SetFile -a C "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" >/dev/null

hdiutil convert "$DMG_TMP" -format UDZO -o "$DMG_OUTPUT" >/dev/null
rm -f "$DMG_TMP"

# ── Step 6b: Sign the DMG itself, then notarize + staple ───────────────────
# A Developer ID-signed DMG is not strictly required — notarization staples
# a ticket directly onto the disk image. But signing the DMG gives a clean
# `spctl --assess` result and matches what Apple's own docs recommend.
if [ "$FP_SIGN" = "1" ]; then
    log "signing DMG"
    codesign --force \
             --sign "$FP_SIGN_IDENTITY" \
             --timestamp \
             "$DMG_OUTPUT"

    notarize_and_staple "$DMG_OUTPUT"
fi

# ── Step 7: Clean up intermediate bundles so Launchpad doesn't index them ──
log "cleaning up intermediate bundles"
"$LSREGISTER" -u "$(pwd)/$INSTALLER_BUNDLE" 2>/dev/null || true
"$LSREGISTER" -u "$(pwd)/$DMG_STAGING/FalconPulsar Installer.app" 2>/dev/null || true
rm -rf "dist/installer-bundle"
rm -rf "$DMG_STAGING"

log "done: $DMG_OUTPUT ($(du -h "$DMG_OUTPUT" | awk '{print $1}'))"
