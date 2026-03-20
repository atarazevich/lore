#!/bin/bash
set -euo pipefail

# Build OpenOats.app bundle from swift build output
# Usage: ./build.sh [--release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="debug"
SWIFT_FLAGS=""
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
    SWIFT_FLAGS="-c release"
fi

echo "Building OpenOats ($CONFIG)..."
swift build $SWIFT_FLAGS

# Paths
BUILD_DIR=".build/$CONFIG"
APP_DIR="$BUILD_DIR/OpenOats.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

# Clean previous bundle
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# Copy binary
cp "$BUILD_DIR/OpenOats" "$MACOS/OpenOats"

# Copy Info.plist
cp "Sources/OpenOats/Info.plist" "$CONTENTS/Info.plist"

# Copy app icon
if [ -f "Sources/OpenOats/Assets/AppIcon.icns" ]; then
    cp "Sources/OpenOats/Assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Copy Sparkle framework
if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    cp -R "$BUILD_DIR/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"
fi

# Fix rpath so the binary finds Sparkle.framework in Contents/Frameworks/
install_name_tool -add_rpath @loader_path/../Frameworks "$MACOS/OpenOats" 2>/dev/null || true

# Sign with self-signed dev certificate (stable identity preserves Accessibility permission across rebuilds)
SIGN_ID="Apple Development"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    # Sign Sparkle framework first if present
    if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
        codesign --force --sign "$SIGN_ID" "$FRAMEWORKS/Sparkle.framework" 2>/dev/null || true
    fi
    codesign --force --sign "$SIGN_ID" \
        --entitlements "Sources/OpenOats/OpenOats.entitlements" \
        "$APP_DIR" 2>/dev/null || echo "Warning: codesign with '$SIGN_ID' failed"
else
    echo "Warning: '$SIGN_ID' certificate not found, falling back to ad-hoc signing"
    echo "  Run the dev setup to create it (see docs/dev-setup.md)"
    codesign --force --deep --sign - \
        --entitlements "Sources/OpenOats/OpenOats.entitlements" \
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
