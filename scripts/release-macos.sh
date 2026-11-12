#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.1.0}"
BUILD_ROOT="$ROOT/.build/release-$VERSION"
RELEASE_DIR="$ROOT/build/release"
APP_NAME="AI Usage.app"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <version> (for example: 1.0.0)" >&2
    exit 2
fi

ARM64_OUTPUT="$BUILD_ROOT/arm64"
X86_OUTPUT="$BUILD_ROOT/x86_64"
ARM64_APP="$ARM64_OUTPUT/$APP_NAME"
X86_APP="$X86_OUTPUT/$APP_NAME"
UNIVERSAL_APP="$BUILD_ROOT/universal/$APP_NAME"

APP_VERSION="$VERSION" BUILD_ARCH="arm64-apple-macosx13.0" APP_OUTPUT_ROOT="$ARM64_OUTPUT" \
    bash "$ROOT/scripts/build-app.sh"
APP_VERSION="$VERSION" BUILD_ARCH="x86_64-apple-macosx13.0" APP_OUTPUT_ROOT="$X86_OUTPUT" \
    bash "$ROOT/scripts/build-app.sh"

mkdir -p "$UNIVERSAL_APP/Contents/MacOS" "$RELEASE_DIR"
ditto "$ARM64_APP" "$UNIVERSAL_APP"
lipo -create \
    "$ARM64_APP/Contents/MacOS/CodexUsageWidget" \
    "$X86_APP/Contents/MacOS/CodexUsageWidget" \
    -output "$UNIVERSAL_APP/Contents/MacOS/CodexUsageWidget"
codesign --force --deep --sign - "$UNIVERSAL_APP"
codesign --verify --deep --strict "$UNIVERSAL_APP"

ARCHIVE="$RELEASE_DIR/AI-Usage-$VERSION-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$UNIVERSAL_APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Created $ARCHIVE"
