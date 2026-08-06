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

# plutil for every read and every write of this plist, never `defaults`: the
# latter goes through cfprefsd, which caches by path and can hand back — or write
# back — a copy that predates the edits below.
MARKETING_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "Sources/Lore/Info.plist")
BUILD_VERSION="$(echo "$MARKETING_VERSION" | cut -d. -f1,2).${COMMIT_COUNT}"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS/Info.plist"
echo "Version: $MARKETING_VERSION (build $BUILD_VERSION, commit #$COMMIT_COUNT)"

# Compile the macOS 26 icon document into Assets.car (the appearance stacks the
# Dock reads) plus a partial plist naming the icon, merged below so Info.plist
# never drifts from the artwork. Regenerate the document with
# `python3 tools/make_mark.py`.
if ! xcrun --find actool > /dev/null 2>&1; then
    echo "Error: actool is missing. The app icon is a macOS 26 .icon document, and only" >&2
    echo "  Xcode's actool compiles it — the Command Line Tools alone do not ship it." >&2
    echo "  Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
ICON_DOC="Sources/Lore/Assets/Lore.icon"
PARTIAL_PLIST="$BUILD_DIR/icon-partial.plist"
xcrun actool --compile "$RESOURCES" --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon Lore \
    --output-partial-info-plist "$PARTIAL_PLIST" \
    "$ICON_DOC" > /dev/null
# actool still exits 0 when --app-icon names something the document does not
# define; it just writes an empty partial plist. So the extracted value, not the
# exit code, is what says the icon compiled.
for key in CFBundleIconFile CFBundleIconName; do
    ICON_VALUE=$(plutil -extract "$key" raw -o - "$PARTIAL_PLIST" 2>/dev/null || true)
    if [ -z "$ICON_VALUE" ]; then
        echo "Error: actool compiled no $key. Its --app-icon name (Lore) must match the" >&2
        echo "  icon $ICON_DOC declares — a mismatch is silent." >&2
        exit 1
    fi
    plutil -replace "$key" -string "$ICON_VALUE" "$CONTENTS/Info.plist"
done

# Committed artwork, copied in verbatim. Lore.icns overwrites the one actool just
# emitted, which carries only the 16 and 128 slots — Package.swift targets
# macOS 15, where the Dock and Finder read CFBundleIconFile rather than
# Assets.car, and upsample everything else from those two. The two PDFs are the
# marks the app draws itself (sidebar chip, status-item glyph); they load through
# Bundle.main, not Bundle.module, because a SwiftPM resource bundle does not
# survive a hand-assembled .app (the trap MeetingDetector.swift:365 documents for
# its meeting-app table).
for asset in Lore.icns BrandMark.pdf MenuBarMark.pdf; do
    if [ ! -f "Sources/Lore/Assets/$asset" ]; then
        echo "Error: Sources/Lore/Assets/$asset is missing — run python3 tools/make_mark.py" >&2
        exit 1
    fi
    cp "Sources/Lore/Assets/$asset" "$RESOURCES/$asset"
done

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
# summon — the ad-hoc path was only ever a trap. Fail loudly instead. The
# `|| true` keeps a no-match grep from killing the script under pipefail
# before the empty-check below can print its error.
SIGN_ID=$(security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db 2>/dev/null | grep "Apple Development: a@cognition.design" | head -1 | awk '{print $2}' || true)
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
