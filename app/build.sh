#!/bin/bash
set -euo pipefail

# Build Lore.app bundle from swift build output
# Usage: ./build.sh [--release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="debug"
SWIFT_FLAGS=""
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
    SWIFT_FLAGS="-c release"
fi

echo "Building Lore ($CONFIG)..."
swift build $SWIFT_FLAGS

# Paths
BUILD_DIR=".build/$CONFIG"
APP_DIR="$BUILD_DIR/Lore.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

# Clean previous bundle
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# Copy binary
cp "$BUILD_DIR/Lore" "$MACOS/Lore"

# Copy Info.plist and stamp the machine-facing build version.
# CFBundleShortVersionString (marketing) is left exactly as Info.plist declares it.
# CFBundleVersion (Sparkle's ordering key) = <major.minor of marketing>.<git commit count>,
# so it is monotonic and maps any build back to an exact commit.
cp "Sources/Lore/Info.plist" "$CONTENTS/Info.plist"

# No silent fallback: a build outside a git checkout cannot produce a version that
# maps back to a commit, and shipping one would break "the machine is the record".
if ! COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null); then
    echo "Error: not a git checkout — cannot derive CFBundleVersion from the commit count." >&2
    exit 1
fi

# Read with plutil, not `defaults read`: cfprefsd caches by path and can hand back a
# stale value after release.sh rewrites the plist out of band.
MARKETING_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "Sources/Lore/Info.plist")
BUILD_VERSION="$(echo "$MARKETING_VERSION" | cut -d. -f1,2).${COMMIT_COUNT}"
defaults write "$PWD/$CONTENTS/Info.plist" CFBundleVersion "$BUILD_VERSION"
plutil -convert xml1 "$CONTENTS/Info.plist"
echo "Version: $MARKETING_VERSION (build $BUILD_VERSION, commit #$COMMIT_COUNT)"

# Copy app icon
if [ -f "Sources/Lore/Assets/AppIcon.icns" ]; then
    cp "Sources/Lore/Assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Copy Sparkle framework
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"
fi

# Fix rpath so the binary finds Sparkle.framework in Contents/Frameworks/
install_name_tool -add_rpath @loader_path/../Frameworks "$MACOS/Lore" 2>/dev/null || true

# Sign with Apple Development certificate (stable identity preserves Accessibility permission across rebuilds)
# Free personal account (hello@cognition.design) — paid enrollment pending, so releases
# also sign with this cert (Sparkle-delivered updates don't re-trigger Gatekeeper).
# Grep by email explicitly (not head -1) so the cognition.design cert can't be picked.
SIGN_ID=$(security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db 2>/dev/null | grep "Apple Development: hello@cognition.design" | head -1 | awk '{print $2}')
if [ -n "$SIGN_ID" ]; then
    # Sign Sparkle framework first if present
    if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
        codesign --force --sign "$SIGN_ID" "$FRAMEWORKS/Sparkle.framework" 2>/dev/null || true
    fi
    codesign --force --sign "$SIGN_ID" \
        --entitlements "Sources/Lore/Lore.entitlements" \
        "$APP_DIR" 2>/dev/null || echo "Warning: codesign with '$SIGN_ID' failed"
else
    echo "Warning: '$SIGN_ID' certificate not found, falling back to ad-hoc signing"
    echo "  Create an 'Apple Development' certificate in Keychain Access to fix this"
    codesign --force --deep --sign - \
        --entitlements "Sources/Lore/Lore.entitlements" \
        "$APP_DIR" 2>/dev/null || true
fi

echo ""
echo "Built: $APP_DIR"
echo ""
echo "To run:"
echo "  open $APP_DIR"
echo ""
echo "To install to /Applications:"
echo "  cp -R $APP_DIR /Applications/"
