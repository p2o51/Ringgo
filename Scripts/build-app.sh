#!/bin/bash
# 构建 C2S.app(SPM 可执行 + 手工组装 bundle + ad-hoc 签名)
# 用法: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/C2S"
APP="build/C2S.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/C2S"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SPM 资源 bundle(如后续加 .metal/资源文件)
for bundle in ".build/$CONFIG"/*.bundle; do
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
  codesign --force --sign - \
    --requirements '=designated => identifier "dev.c2s.C2S"' \
    "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi
echo "✅ 构建完成: $APP"
echo "   运行: open $APP"
