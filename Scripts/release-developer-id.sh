#!/bin/bash
# Ringgo Developer ID 直发流水线：
# release 构建 → Hardened Runtime 签名 → App 公证/装订 → DMG 签名/公证/装订。
#
# 首次使用先保存公证凭据：
#   xcrun notarytool store-credentials "ringgo-notary" \
#     --apple-id "you@example.com" --team-id "TEAMID"
# 命令会安全提示输入 app-specific password，不要把密码写进脚本或 shell history。
#
# 然后：
#   C2S_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="ringgo-notary" Scripts/release-developer-id.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${C2S_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ringgo-notary}"

if [ -z "$SIGN_IDENTITY" ]; then
  echo "❌ 缺少 C2S_SIGN_IDENTITY（Developer ID Application 证书名称）" >&2
  exit 2
fi
if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  echo "❌ 钥匙串中找不到签名身份：$SIGN_IDENTITY" >&2
  exit 3
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "❌ 公证凭据不可用：$NOTARY_PROFILE" >&2
  echo "   请先运行 xcrun notarytool store-credentials（见脚本头部示例）" >&2
  exit 4
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
DIST_DIR="dist"
APP="build/Ringgo.app"
UPLOAD_ZIP="$DIST_DIR/Ringgo-$VERSION-$BUILD-notary-upload.zip"
DMG="$DIST_DIR/Ringgo-$VERSION.dmg"
DMG_RW="$DIST_DIR/Ringgo-$VERSION-rw.dmg"
MOUNT_DIR="/Volumes/Ringgo"
MOUNTED=0

cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  rm -f "$DMG_RW" "$UPLOAD_ZIP"
}
trap cleanup EXIT

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "① 构建并签名 App"
C2S_SIGN_IDENTITY="$SIGN_IDENTITY" Scripts/build-app.sh release
codesign --verify --deep --strict --verbose=2 "$APP"

echo "② 提交 App 公证"
ditto -c -k --keepParent "$APP" "$UPLOAD_ZIP"
xcrun notarytool submit "$UPLOAD_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv --type execute "$APP"

echo "③ 制作并签名 DMG"
if [ -e "$MOUNT_DIR" ]; then
  echo "❌ $MOUNT_DIR 已被占用，请先推出已挂载的 Ringgo 磁盘" >&2
  exit 5
fi
hdiutil create \
  -size 40m \
  -fs HFS+ \
  -volname "Ringgo" \
  -ov \
  "$DMG_RW"
hdiutil attach "$DMG_RW" \
  -nobrowse \
  -noverify
MOUNTED=1

cp -R "$APP" "$MOUNT_DIR/Ringgo.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
xcrun swift Scripts/create-dmg-background.swift \
  "$MOUNT_DIR/.background/background.png"

osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Ringgo"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 760, 588}

    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"

    set position of item "Ringgo.app" of container window to {170, 205}
    set position of item "Applications" of container window to {490, 205}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"
MOUNTED=0

hdiutil convert "$DMG_RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG"
rm -f "$DMG_RW"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "④ 提交 DMG 公证并装订"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv --type open --context context:primary-signature "$DMG"
hdiutil verify "$DMG"

rm -f "$UPLOAD_ZIP"
shasum -a 256 "$DMG" > "$DMG.sha256"
trap - EXIT

echo "✅ Developer ID 发布物已生成"
echo "   $DMG"
echo "   $DMG.sha256"
