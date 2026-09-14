#!/bin/bash
# Builds BoneCode and assembles a launchable .app bundle.
#
# Usage:
#   ./build.sh              # debug build (fast, for development)
#   ./build.sh release      # optimized build
#   ./build.sh release run  # build then launch

set -euo pipefail

CONFIG="${1:-debug}"
ACTION="${2:-}"
APP_NAME="BoneCode"
BUNDLE_ID="cn.bonecode.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
# SwiftPM needs --disable-sandbox: sandbox-exec is unavailable in this
# environment, which breaks manifest compilation.
swift build -c "$CONFIG" --disable-sandbox

BIN_PATH="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
  echo "error: binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# ---- icon
ICONSET="$ROOT/dist/icon.iconset"
if [ ! -f "$ROOT/dist/$APP_NAME.icns" ]; then
  echo "==> Generating app icon"
  mkdir -p "$ROOT/dist/tools"
  xcrun swiftc -O -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$ROOT/dist/tools/makeicon" "$ROOT/tools/makeicon.swift" 2>/dev/null || true
  if [ -x "$ROOT/dist/tools/makeicon" ]; then
    rm -rf "$ICONSET"
    "$ROOT/dist/tools/makeicon" "$ICONSET" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/$APP_NAME.icns" 2>/dev/null || true
    cp "$APP_DIR/Contents/Resources/$APP_NAME.icns" "$ROOT/dist/$APP_NAME.icns" 2>/dev/null || true
  fi
else
  cp "$ROOT/dist/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
fi

# ---- Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSRequiresAquaSystemAppearance</key>
	<false/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Source File</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.text</string>
				<string>public.source-code</string>
				<string>public.plain-text</string>
				<string>public.json</string>
				<string>public.xml</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 || \
  echo "warning: ad-hoc signing failed; the app still runs but keychain prompts may repeat"

echo "==> Done"
echo "    $APP_DIR"
echo "    binary size: $(du -h "$APP_DIR/Contents/MacOS/$APP_NAME" | cut -f1)"

if [ "$ACTION" = "run" ]; then
  echo "==> Launching"
  open "$APP_DIR"
fi
