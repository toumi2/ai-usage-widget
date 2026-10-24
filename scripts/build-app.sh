#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Usage"
APP_OUTPUT_ROOT="${APP_OUTPUT_ROOT:-$ROOT/build}"
APP_PATH="$APP_OUTPUT_ROOT/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-1.1.0}"
BUILD_ARCH="${BUILD_ARCH:-}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "APP_VERSION must be a semantic version such as 1.0.0." >&2
    exit 2
fi

if [[ "$BUILD_CONFIGURATION" != "release" && "$BUILD_CONFIGURATION" != "debug" ]]; then
    echo "BUILD_CONFIGURATION must be release or debug." >&2
    exit 2
fi

if [[ -n "$BUILD_ARCH" ]]; then
    swift build --package-path "$ROOT" --triple "$BUILD_ARCH" -c "$BUILD_CONFIGURATION"
    BIN_PATH="$(swift build --package-path "$ROOT" --triple "$BUILD_ARCH" -c "$BUILD_CONFIGURATION" --show-bin-path)"
else
    swift build --package-path "$ROOT" -c "$BUILD_CONFIGURATION"
    BIN_PATH="$(swift build --package-path "$ROOT" -c "$BUILD_CONFIGURATION" --show-bin-path)"
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/CodexUsageWidget" "$APP_PATH/Contents/MacOS/CodexUsageWidget"
cp "$ROOT/assets/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>CodexUsageWidget</string>
    <key>CFBundleIdentifier</key><string>com.mounirtoumi.codexusagewidget</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>Codex Usage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$APP_VERSION</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP_PATH"
echo "Built $APP_PATH"
