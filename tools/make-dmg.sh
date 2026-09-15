#!/bin/bash
# Packages dist/BoneCode.app into a distributable disk image.
#
# Usage:
#   tools/make-dmg.sh              # build (release) then package
#   tools/make-dmg.sh --no-build   # package whatever is already in dist/
#
# Output: dist/BoneCode-<version>.dmg  (+ a .sha256 next to it)
#
# The image opens as the usual drag-to-install window: the app on the left,
# a shortcut to /Applications on the right.
#
# Note on Gatekeeper: build.sh signs the app ad-hoc. That is fine for running it
# on this machine, but a downloaded copy carries a quarantine flag and macOS will
# refuse to open it until the user right-clicks → Open, or runs
# `xattr -dr com.apple.quarantine /Applications/BoneCode.app`.
# For a warning-free download you need a Developer ID certificate and
# notarization; set SIGN_ID below (or export it) to sign properly before packing.

set -euo pipefail

APP_NAME="BoneCode"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/$APP_NAME.app"
VOL_NAME="$APP_NAME"

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$BUILD" = 1 ]; then
  echo "==> Building release"
  "$ROOT/build.sh" release >/dev/null
fi

if [ ! -d "$APP_DIR" ]; then
  echo "error: $APP_DIR not found — run ./build.sh release first" >&2
  exit 1
fi

# ---- version, taken from the bundle so the file name cannot drift from it
PLIST="$APP_DIR/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo 1.0)"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
TMP_DMG="$ROOT/dist/.$APP_NAME-rw.dmg"
STAGE_MOUNT="/Volumes/$VOL_NAME"

# ---- optional Developer ID signing, before anything is copied
if [ -n "${SIGN_ID:-}" ]; then
  echo "==> Signing with $SIGN_ID"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_ID" "$APP_DIR"
  codesign --verify --strict --verbose=2 "$APP_DIR"
else
  echo "==> No SIGN_ID set; keeping the ad-hoc signature from build.sh"
fi

# ---- a stale volume from an earlier run would make the mount below fail
if [ -d "$STAGE_MOUNT" ]; then
  echo "==> Detaching stale volume at $STAGE_MOUNT"
  hdiutil detach "$STAGE_MOUNT" -force >/dev/null 2>&1 || true
fi

rm -f "$DMG" "$TMP_DMG"

# ---- build the image by mounting a read-write scratch image and filling it.
#
# Deliberately NOT `hdiutil create -srcfolder`: that mode may dereference the
# /Applications symlink and try to copy the entire Applications folder into the
# image. Mounting first and copying in has no such ambiguity.
APP_MB=$(du -sm "$APP_DIR" | cut -f1)
SIZE_MB=$((APP_MB + 32))          # slack for the HFS+ metadata and the symlink

echo "==> Creating scratch image (${SIZE_MB} MB)"
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "$VOL_NAME" \
  -ov "$TMP_DMG" >/dev/null

echo "==> Mounting"
MOUNT_POINT="$(hdiutil attach -nobrowse -readwrite "$TMP_DMG" \
  | grep -o '/Volumes/.*' | head -1)"
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
  echo "error: could not mount the scratch image" >&2
  exit 1
fi

# From here on, always detach even if something fails, or the volume is left
# mounted and the next run trips over it.
cleanup() {
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Copying $APP_NAME.app"
ditto "$APP_DIR" "$MOUNT_POINT/$APP_NAME.app"

# The drag target. `ln -s` inside the mounted volume is unambiguous.
ln -s /Applications "$MOUNT_POINT/Applications"

# A short note the user sees when they open the image.
cat > "$MOUNT_POINT/安装说明.txt" <<'NOTE'
把 BoneCode.app 拖到右边的「Applications」文件夹即可安装。

首次打开时 macOS 可能提示「无法验证开发者」——这是因为应用没有经过
Apple 公证。解决办法：在「应用程序」里右键点 BoneCode → 打开 → 再点「打开」。
之后就可以正常双击启动了。
NOTE

# Give the Finder time to flush before detaching.
sync
hdiutil detach "$MOUNT_POINT" >/dev/null
trap - EXIT

echo "==> Compressing"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"

# ---- checksum, so a download can be verified
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo "==> Done"
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"
echo "    $(cat "$DMG.sha256")"
