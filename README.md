# C2S — macOS "Circle to Search"(净室自研)

一个常驻 macOS 的圈选搜索工具:**热键/手势 → 冻结屏幕 → 圈/划/点任意文字或图片 → Google 搜索 / Lens 识图 / 翻译 / 扫码**。

> 决策:**从零净室重建**,不 fork 开源的 `sijan2/Circle2Search`(无 LICENSE=保留所有权利,且有多处实现缺陷)。我们只把它当参考规格,吸收其技术思路、避开其坑。

---

## 新 Session 从这里开始

按顺序读这三份文档,即可开工,无需上下文:

1. **[docs/features.md](docs/features.md)** — 做什么:功能清单、逐功能行为、权限矩阵、技术栈、模块架构、**构建顺序(切片 A→E)**、必避的坑。
2. **[docs/ui-style.md](docs/ui-style.md)** — 长什么样:设计原则、颜色/字体/间距 token、核心组件规格、动效时序、无障碍。
3. **[docs/circle2search-core-mechanisms.md](docs/circle2search-core-mechanisms.md)** — 怎么实现:每个块业务的底层机制、三套坐标系与换算、**选词手势正解算法(§6)**、Lens 直传 302 技巧、微光 Metal 要点、架构建议。

参考实现(**已用 `swiftc` 真编真跑验证**,可直接 `swiftc xxx.reference.swift && ./a.out`):
- **[docs/reference/SelectionEngine.reference.swift](docs/reference/SelectionEngine.reference.swift)** — 选词手势 v1(有界回填)的对抗验证,其中触碰集几何与跨块隔离仍有效;**段内填充规则已被 v2(区间填充)取代**,以 `Tests/C2SCoreTests/SelectionEngineTests.swift` 为准。
- **[docs/reference/VisionWordSelection.reference.swift](docs/reference/VisionWordSelection.reference.swift)** — Vision 词级框提取 + 选择算法端到端(真 OCR)。
- **[docs/reference/ObjectSnap.reference.swift](docs/reference/ObjectSnap.reference.swift)** — 轻点图片→物体吸附(显著性/实例分割/矩形)。
- **[docs/reference/MultitouchProbe.reference.c](docs/reference/MultitouchProbe.reference.c)** — 三指触发的私有框架探针(`clang mt.c -framework CoreFoundation`);已在 macOS 26.5.1 验证框架可加载、枚举触控板、零权限弹窗。

---

## 关键决策(已定稿,勿再纠结)

- **选区 = 可调矩形**,不做多边形/非矩形蒙版;**矩形一律图搜(v3)**——框一旦出现,不管怎么调整都是搜图,框里有字交给 Lens 自己认,绝不中途翻转成文字搜索(想搜文字用笔刷划词)。
- **选词 = 参与区域 × 锚点区间填充(v4,2026-07-03 定稿,Android 同款)**:参与区域 = 触碰词所在 block ∪ 笔画横向带扫过的 block(带只圈栏、不裁词);选区 = 参与区域阅读链上 [首触碰…末触碰] **整段区间**(首行到行尾、中间行整行、末行从行首)。侧栏斜划=整行填充不串正文;表格对角线=整表;~~v2 block 隔离~~(撕碎表格)、~~v3 纯全局区间~~(三栏串选)、~~v3.1 按词裁带~~(裁掉行尾成"对角线走廊")先后被实测否定。触发/退出:热键=开关;轻点永不退出(点空白=新框)。测试真源:`Tests/C2SCoreTests/SelectionEngineTests.swift`。
- **坐标 = 单一 `DisplayContext`**(鼠标所在屏 `backingScaleFactor`;废弃写死 ×2 与 `displays.first`/`NSScreen.main` 双源;背景用显式 frame 而非 `.aspectRatio(.fill)`)。
- **触发**:Carbon 热键(默认 ⌘⇧S)+ 蓄力唤起(按住 ⌘⇧ ~250ms,免辅助权限);双击 Shift 默认关。**三指双击触控板**已作为 Developer ID 版实验开关落地:运行时加载私有 MultitouchSupport、只读帧零权限、失败自动降级到热键/菜单栏。详见 features.md §F1。
- **结果(v3,2026-07-03)**:**手机比例(390pt,≈9:19.5)独立悬浮面板**,默认停靠右侧、抓手可拖动、× 关闭;WKWebView + 骨架/错误态。不是锚定 popover;底部上滑面板因全宽利用率低被否。
- **图搜(v2,2026-07-02 实测改版)**:结果页与**上传会话绑定**(跨会话="Image not found"),且风控网络下匿名客户端一律 403 → **上传搬进面板 WKWebView**:自动提交 multipart 表单做顶层 POST 导航(免 CORS),WebView 跟随 303 落结果页;dataStore 持久化,403 → 错误卡「重试 / 登录 Google」。URLSession 直传+拦 302 方案废弃。
- **物体吸附**:`VNGenerateForegroundInstanceMask`/显著性/矩形检测,轻点吸附到含点最小框。
- **翻译**:选区/图片走 Google AI Mode;整屏走 Apple Translation 框架(本地免 Key)。
- **动画**:四点渐变(AE 4-color)+ 涟漪已落地,取代原项目 8 光斑公转。

---

## 技术栈

Swift + SwiftUI/AppKit · macOS **14.0+** · **零第三方依赖** · Vision / ScreenCaptureKit / WebKit / Translation / Contacts / EventKit / Metal · 非沙盒 + Developer ID 签名公证 · 菜单栏代理(`LSUIElement`)。

新建 Xcode 工程后记得:换掉自己的 `DEVELOPMENT_TEAM` 与 bundle id;部署目标设 14.0;`LSUIElement=YES`;加 `NSScreenCaptureUsageDescription` / `NSContactsUsageDescription` / `NSCalendarsUsageDescription`。

---

## 构建顺序

A 打通端到端(热键→抓屏→覆盖层→矩形框选→OCR→文本搜索→底部面板) → B 选择灵魂(SelectionEngine + 手柄 + 可调矩形) → C 图搜(multipart 直传+302+错误态) → D 差异化(物体吸附/条码意图/翻译/multisearch) → E 质感(四点渐变微光+涟漪)。

---

## 构建与运行

SPM 工程(无 .xcodeproj;Xcode 可直接打开 `Package.swift`):

```bash
# 本机 xcode-select 若指向 CommandLineTools,需要指定 Xcode 工具链(XCTest 依赖)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build                 # 编译
swift test                  # 全部单测(SelectionEngine 对抗场景 / 坐标 / multipart / OCR 冒烟)
Scripts/build-app.sh        # 组装 build/Ringgo.app(含 Info.plist,稳定身份的本地 ad-hoc 签名)
open build/Ringgo.app       # 运行(菜单栏代理;首次抓屏会申请屏幕录制权限)
```

目标结构:`C2SCore`(纯逻辑,可单测)→ `C2SAppKit`(服务与 UI)→ `C2S`(@main 薄壳)。
产品名/bundle id 为 Ringgo / `dev.ringgo.Ringgo`;C2S 仅作为代号保留在 SPM
目标名与仓库名中。本地脚本会给 ad-hoc 构建写入稳定的 designated requirement，
避免每次改二进制后屏幕录制授权因 cdhash 变化而失效。正式分发时通过
`C2S_SIGN_IDENTITY="Developer ID Application: …"` 使用 Developer ID 签名 + 公证。

Developer ID 正式发布（需要钥匙串证书与 `notarytool` profile）：

```bash
C2S_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="ringgo-notary" \
Scripts/release-developer-id.sh
```
