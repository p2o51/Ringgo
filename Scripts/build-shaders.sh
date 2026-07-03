#!/bin/bash
# 重新编译切片 E 的 Metal 着色器(改过 OverlayEffects.metal 后运行)。
# 命令行 SwiftPM 不编 Metal,default.metallib 是提交进仓库的预编译产物。
set -euo pipefail
cd "$(dirname "$0")/../Sources/C2SAppKit/Shaders"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun -sdk macosx metal OverlayEffects.metal -o default.metallib
xcrun metal-nm default.metallib | grep c2s || { echo "❌ 没找到 c2s_* 符号"; exit 1; }
echo "✅ default.metallib 已更新"
