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

# Inject the report-receiver write token into the source just for this build, then
# restore the placeholder on exit so it never lands in the working tree (mirrors the
# Info.plist modify-then-restore dance). The token is public by design (§8) — a bot
# filter that ships in every copy of the app — but it lives in the shell env, not the
# repo, per the secrets rule. A dev build without it simply can't upload reports.
TOKEN_FILE="Sources/Lore/Diagnostics/ReportUploader.swift"
if [ -n "${LORE_REPORT_TOKEN:-}" ]; then
    # Restore by swapping the token back to the placeholder (not `git checkout`, which
    # would also discard any unrelated uncommitted edits to this file).
    trap 'sed -i "" "s|${LORE_REPORT_TOKEN}|LORE_REPORT_TOKEN_PLACEHOLDER|" "$TOKEN_FILE" 2>/dev/null || true' EXIT
    sed -i '' "s|LORE_REPORT_TOKEN_PLACEHOLDER|${LORE_REPORT_TOKEN}|" "$TOKEN_FILE"
    echo "Report token injected for this build."
else
    echo "Note: LORE_REPORT_TOKEN not set — building with placeholder (problem reports won't upload)."
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
# Filter by paid-account email (team CTHL87V7H8) so dev builds share TCC permissions
# with Developer ID releases. Grep by email, not cert ID — the ID changes on renewal.
# No fallback and no swallowed stderr (#144): a silently ad-hoc bundle flips the
# TCC identity, drops the permission grants, and fires the signature-changed
# summon — the ad-hoc path was only ever a trap. Fail loudly instead.
SIGN_ID=$(security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db 2>/dev/null | grep "Apple Development: a@cognition.design" | head -1 | awk '{print $2}')
if [ -z "$SIGN_ID" ]; then
    echo "Error: 'Apple Development: a@cognition.design' certificate not found in login keychain." >&2
    echo "  Unlock the keychain or install the certificate — an ad-hoc bundle would drop TCC grants." >&2
    exit 1
fi
# Sign Sparkle framework first if present
if [ -d "$FRAMEWORKS/Sparkle.framework" ]; then
    codesign --force --sign "$SIGN_ID" "$FRAMEWORKS/Sparkle.framework"
fi
codesign --force --sign "$SIGN_ID" \
    --entitlements "Sources/Lore/Lore.entitlements" \
    "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo ""
echo "To run:"
echo "  open $APP_DIR"
echo ""
echo "To install to /Applications:"
echo "  cp -R $APP_DIR /Applications/"
