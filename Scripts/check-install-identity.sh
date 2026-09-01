#!/bin/bash
# 在替换 /Applications/Ringgo.app 前，只读比对 bundle id 与 designated requirement。
# 相同 designated requirement 才是 macOS TCC 可识别的同一代码身份；仅同名或同 bundle id 不够。
set -euo pipefail
cd "$(dirname "$0")/.."

CANDIDATE="${1:-build/Ringgo.app}"
INSTALLED="${2:-/Applications/Ringgo.app}"

fail() {
  echo "❌ $*" >&2
  exit 1
}

[ -d "$CANDIDATE" ] || fail "候选 App 不存在：$CANDIDATE"
[ -d "$INSTALLED" ] || fail "现有安装不存在：$INSTALLED；没有可供继承的签名基线，安装前需要用户确认。"

codesign --verify --deep --strict "$CANDIDATE" 2>/dev/null || fail "候选 App 验签失败：$CANDIDATE"
codesign --verify --deep --strict "$INSTALLED" 2>/dev/null || fail "现有 App 验签失败：$INSTALLED"

bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

designated_requirement() {
  codesign -dr - "$1" 2>&1 | sed -n 's/^designated => /designated => /p'
}

candidate_id="$(bundle_id "$CANDIDATE")"
installed_id="$(bundle_id "$INSTALLED")"
candidate_requirement="$(designated_requirement "$CANDIDATE")"
installed_requirement="$(designated_requirement "$INSTALLED")"

[ -n "$candidate_id" ] || fail "无法读取候选 App 的 bundle id。"
[ -n "$installed_id" ] || fail "无法读取现有 App 的 bundle id。"
[ "$candidate_id" = "$installed_id" ] || fail "bundle id 不一致：候选=$candidate_id，现有=$installed_id"
[ -n "$candidate_requirement" ] || fail "无法读取候选 App 的 designated requirement。"
[ -n "$installed_requirement" ] || fail "无法读取现有 App 的 designated requirement。"

if [ "$candidate_requirement" != "$installed_requirement" ]; then
  echo "❌ 签名身份不一致，禁止覆盖安装。" >&2
  echo "   候选：$candidate_requirement" >&2
  echo "   现有：$installed_requirement" >&2
  echo "   覆盖后不能承诺保留屏幕录制授权；请先告知用户并准备重新授权。" >&2
  exit 1
fi

echo "✅ 安装身份一致"
echo "   bundle id: $candidate_id"
echo "   requirement: $candidate_requirement"
