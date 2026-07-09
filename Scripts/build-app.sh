#!/bin/bash
# 构建 Ringgo.app(SPM 可执行 + 手工组装 bundle + ad-hoc 签名;SPM 产物名仍为 C2S)
# 用法: Scripts/build-app.sh [debug|release]
#
# release 产出通用二进制(arm64 + x86_64):早期版本只编译宿主架构(本机
# arm64),Intel Mac 用户双击后进程直接不存在(不进活动监视器、无菜单栏图标,
# 且往往连"架构不兼容"提示都被用户划走误认成"没反应")。debug 仍只编译宿主
# 架构,保持日常迭代速度。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Ringgo.app"

case "$(uname -m)" in
  arm64) HOST_TRIPLE="arm64-apple-macosx" ;;
  x86_64) HOST_TRIPLE="x86_64-apple-macosx" ;;
  *) echo "❌ 未知宿主架构: $(uname -m)" >&2; exit 1 ;;
esac

if [ "$CONFIG" = "release" ]; then
  swift build -c release --triple arm64-apple-macosx
  swift build -c release --triple x86_64-apple-macosx
  BUNDLE_DIR=".build/$HOST_TRIPLE/release"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  lipo -create \
    ".build/arm64-apple-macosx/release/C2S" \
    ".build/x86_64-apple-macosx/release/C2S" \
    -output "$APP/Contents/MacOS/Ringgo"
else
  swift build -c "$CONFIG" --triple "$HOST_TRIPLE"
  BUNDLE_DIR=".build/$HOST_TRIPLE/$CONFIG"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BUNDLE_DIR/C2S" "$APP/Contents/MacOS/Ringgo"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 本地化资源(zh-Hans/en/ja):.lproj 直接放 .app 的 Contents/Resources,
# 由 Bundle.main(见 Localization.swift 的 L10n)按系统首选语言 / 按 App 语言偏好查表。
# 由 Scripts/l10n/gen-strings.py 从 Scripts/l10n/l10n.json 生成,改文案先重跑它。
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/" || true
done

# SPM 资源 bundle(纯数据,和架构无关,任一 triple 产物都一样)。放标准位置
# Contents/Resources —— SwiftPM 给可执行 target 生成的 resource_bundle_accessor
# .swift 只认 Bundle.main.bundleURL(.app 包根)拼 bundle 名,压根不知道
# Contents/Resources 这层 macOS 约定,曾经导致 Bundle.module 在任何非开发机上
# 都找不到、直接 fatalError 崩溃(MenuBarIcon.swift 已改用手写查找,不再依赖
# Bundle.module,见该文件注释)。放去 .app 包根会让 codesign 报
# "unsealed contents present in the bundle root" 且验签失败,所以老老实实按
# 标准位置放。
for bundle in "$BUNDLE_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/" || true
done

# 本地开发默认用 ad-hoc 签名，但显式写入稳定 designated requirement。
# 否则 codesign 会把每次构建的 cdhash 当作身份，Screen Recording 的 TCC
# 授权会在每次二进制变化后看似“已开启”却实际失效。
#
# 正式分发时传入 Apple 签名身份，例如：
#   C2S_SIGN_IDENTITY="Developer ID Application: ..." Scripts/build-app.sh release
SIGN_IDENTITY="${C2S_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --options runtime --sign - \
    --requirements '=designated => identifier "dev.ringgo.Ringgo"' \
    "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✅ 构建完成: $APP ($(lipo -archs "$APP/Contents/MacOS/Ringgo" 2>/dev/null || echo "$(uname -m)"))"
echo "   运行: open $APP"
