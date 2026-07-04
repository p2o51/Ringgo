#!/bin/bash
# 重新编译切片 E 的 Metal 着色器(改过 OverlayEffects.metal 后运行)。
# 命令行 SwiftPM 不编 Metal,default.metallib 是提交进仓库的预编译产物。
set -euo pipefail
cd "$(dirname "$0")/../Sources/C2SAppKit/Shaders"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# -mmacosx-version-min 必须显式给,不然 xcrun metal 会按构建机当前 SDK 版本
# 打最低系统要求(实测在 macOS 26 机器上编译,产物被打上"最低要求 26.0",
# 在更旧的系统上整条 shader 直接加载失败——SwiftUI 的 colorEffect 静默跳过
# 特效,只剩裸 fill 颜色,表现为"全屏变白、渐变消失"而不是崩溃,比崩溃更难
# 定位)。这里对齐 Package.swift 的 .macOS(.v14) 和 Info.plist 的
# LSMinimumSystemVersion,不能想当然改这两处而漏掉这里。
xcrun -sdk macosx metal -mmacosx-version-min=14.0 OverlayEffects.metal -o default.metallib
xcrun metal-nm default.metallib | grep c2s || { echo "❌ 没找到 c2s_* 符号"; exit 1; }
echo "✅ default.metallib 已更新"
