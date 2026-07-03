# C2S — 功能规格(Product / Functional Spec)

> macOS 版 "Circle to Search"(净室自研,不 fork)。本文定义**做什么**:功能清单、每个功能的行为/状态/边界、技术栈与约束、模块架构、构建顺序。
> 视觉见 [ui-style.md](ui-style.md);底层机制与算法见 [circle2search-core-mechanisms.md](circle2search-core-mechanisms.md)(下称"核心机制")。

---

## 0. 一句话与原则

**在 macOS 上,一个热键/手势即可"冻结屏幕 → 圈/划/点任意文字或图片 → 立即 Google 搜索、Lens 识图、翻译、扫码"的常驻工具。**

原则:隐形常驻 · 所见即所得的选择 · 本地优先(OCR/翻译走 Apple 端上模型)· 顺(感知零延迟)· 原生手感。

---

## 1. 功能清单(MVP → later)

| # | 功能 | 阶段 | 状态 |
|---|---|---|---|
| F1 | 触发/唤起(热键 + 蓄力手势 + 三指双击 + 菜单栏) | MVP(切片A;三指双击=可选增强) | 设计定稿(三指双击已实测框架可用) |
| F2 | 抓屏 + 冻结覆盖层(多屏/Retina 正确) | MVP(切片A) | 定稿,含坐标 P0 |
| F3 | 本地 OCR(单级 accurate,词级框,多语含中文) | MVP(切片A/B) | 已验证 |
| F4 | 选择:笔刷/涂抹(WYSIWYG)+ 轻点选词 + 手柄扩展 | MVP(切片B) | **正解 10/10 验证** |
| F5 | 文本搜索 → 结果底部面板(WKWebView) | MVP(切片A) | 定稿 |
| F6 | 可调矩形选区(图片/无文字区) | 切片B/D | 定稿 |
| F7 | 图像/视觉搜索(直传 Lens + 302 + 面板) | 切片C | 定稿(需修 multipart) |
| F8 | 轻点图片 → 物体吸附(显著性/实例分割) | 切片D | 已验证原型 |
| F9 | 条码/二维码识别 + 原生意图(URL/Wi-Fi/联系人/日历/地图/电话/邮件) | 切片D | 定稿(需补权限串) |
| F10 | 翻译(选区 + 整屏,后续边滚边译) | 切片D | 待实现(Apple Translation) |
| F11 | Multisearch(选区 + 追加文字提问) | 切片D | 定稿 |
| F12 | 复制/分享动作 | 切片B | 定稿 |
| F13 | 设置(触发/外观/搜索/权限) | 切片A/B | 定稿 |
| F14 | 四点渐变微光 + 涟漪(质感层) | 切片E | 原型已出 |
| — | 非目标:整段落跨屏抓取、账号登录、历史记录同步 | out | 明确不做(见 §5) |

---

## 2. 逐功能行为规格

### F1 · 触发/唤起
- **主热键**:Carbon `RegisterEventHotKey`,默认 ⌘⇧S,可在设置里录制修改并持久化。免辅助功能权限。注册失败要**给用户反馈**(原项目静默失败还照存)。
- **蓄力手势(默认新交互)**:按住 ⌘⇧(用 `flagsChanged` 计时,免辅助权限)超过 ~250ms 触发;蓄力期间渐显四点微光作可视反馈;阈值前松开=取消(天然防误触)。这 250ms 正好并行完成抓屏 → **松手即冻结、零空窗**。
- **双击 Shift**:可选、**默认关闭**(它需要辅助功能权限,会破坏免权限卖点;原项目默认开还泄漏 monitor)。开启时才申请权限。
- **三指双击触控板(可选增强,默认关闭)**:全局(任意 App 前台)三指连续两次轻点唤起。
  - *为什么只能私有框架*:公开 API 做不到后台全局多指——`NSTouch`/手势识别器只在本 App 前台且触摸落自己窗口内才有数据;`CGEventTap` 连 swipe/magnify 都拿不到(CGEventType 无任何手势类型);`NSEvent.addGlobalMonitorForEvents` 全局连宏观手势都收不到(仅 mouseMoved/keyDown)。唯一路径 = **私有 `MultitouchSupport.framework`**(BTT/Jitouch/MiddleClick/MiddleDrag 同款,含 2026 新项目仍选此路)。
  - *实现*:**运行时 `dlopen`/`dlsym`,不链接 .tbd**(否则 arm64e PAC bus error + Big Sur 起框架并入 dyld 缓存导致编译期链接失败);`MTDeviceCreateList` 枚举全部设备 → 逐个 `MTRegisterContactFrameCallback` + `MTDeviceStart` 读逐帧逐指;用户态状态机判定(见下)。
  - *三指双击判定状态机*(框架不给 tap 标志,须自己算):手指数**严格 ==3**(出现第 4 指作废)、归一化位移 **<0.05**(超阈=swipe/drag,丢弃)、单 tap **<300ms**、两拍间隔 **<300ms** 且两次质心接近;与三指 swipe(位移+速度门槛)、三指拖移、三指查词(要求"双击",系统查词是单击)区分。
  - *权限*:**只读帧唤起自家 overlay、不合成/不拦截事件 → 零 TCC**(免辅助功能、免输入监控);仅需**非沙盒**(已满足)。
  - *延迟*:双击天然 ~200-300ms 识别延迟(等第二拍)→ **第一拍合格即预热抓屏、第二拍到达即冻结**。
  - *已实测(macOS 26.5.1 开发机)*:框架 `dlopen` 成功、`MTDeviceCreateList` 枚举到触控板、注册+启动成功、**无权限弹窗**。探针见 `docs/reference/MultitouchProbe.reference.c`(可 `clang … -framework CoreFoundation` 直接跑)。
  - *风险管理*:私有 API 无契约、**MTTouch 结构体布局 macOS 26/Tahoe 已改过** → 布局以现行 MiddleClick/OpenMultitouchSupport header 为准、**只用回调直给参数**(numTouches/position/timestamp)、加"符号缺失 / 布局哨兵越界(position∉[0,1])"自检,失效即**自动禁用并引导走热键或外部工具**;睡眠唤醒(`willSleep`→stop / `didWake`→重建)、设备热插拔(IOKit `AppleMultitouchDevice` 通知→重注册)否则回调静默失效。**三指双击永远是可选增强,承重触发是免权限的热键/蓄力/菜单栏/`c2s://capture`。**
- **菜单栏**:「立即圈选」走同一条(优化过的)冻结管线;hover 图标时可预热抓屏管线。
- **外部触发 & 三指双击备路(建议 MVP 即做)**:注册 URL scheme `c2s://capture` + App Intent(Shortcuts)。既方便绑 Raycast/Stream Deck,**也是三指双击的降级落点**——私有框架失效、或未来做 App Store 沙盒版时,引导用户用 **BTT/Jitouch 把三指双击绑到 `open c2s://capture`**(风险落第三方,C2S 保持干净可沙盒)。Karabiner(只给手指数变量)/ Hammerspoon(走公共 NSEvent 仅前台可靠)不满足全局三指双击,不推荐。
- 状态:idle → (蓄力中,可取消) → capturing → overlay active。同一入口去重(capturing 时再触发忽略)。

### F2 · 抓屏 + 冻结
- `SCShareableContent`(**预热并缓存**,随 `didChangeScreenParameters` 失效重建)→ **鼠标所在屏**(非 `displays.first`)→ `SCScreenshotManager.captureImage` 单帧(无录屏红点)。
- **坐标 P0(核心机制 §6)**:全流程一个 `DisplayContext{pointSize=该屏 NSScreen.frame, pixelSize=CGImage 尺寸, scale=backingScaleFactor}`;`config.w/h = display.px × 真实 scale`(**废弃写死 ×2**);overlay 与 capture **同屏**;背景 `Image` 用显式 `.frame(点尺寸)`。
- 冻结覆盖层 = 复用的透明窗口,截图返回只做 alpha 0→1 点亮 + 交叉淡入(不硬切)。权限检查**移出热路径**(启动查一次+缓存)。
- 边界:无显示器/抓屏失败 → 原生提示,不空转;多屏时只在活动屏铺覆盖层。

### F3 · 本地 OCR
- Apple Vision `VNRecognizeTextRequest`,**单级 `.accurate`**(删掉原项目"快扫+精扫重识别"的二次开销),`automaticallyDetectsLanguage=true`,`usesLanguageCorrection=true`,可给 `recognitionLanguages` 提示(中英日韩等,已验证支持 30 语言含中文)。
- **词级框**:对每个 observation 取 `topCandidates(1)`,`enumerateSubstrings(.byWords)` + `recognizedText.boundingBox(for:)` 得每词归一化框(已验证)。中文按 ~2 字块切,选择/回填逻辑要按实际 char box、不假设"词"。
- 抓屏后在 **detached Task** 里全量算一次词框(别在主线程),得 `[SelectableWord]` 发布给覆盖层;仅按同一 CGImage 实例缓存,避免稀疏采样把同尺寸的新截图误判成旧图。
- 选区后**全是内存几何裁词**(纯 O(词) 相交),查询串近乎零延迟。

### F4 · 选择(核心;规则 v4,2026-07-03 定稿)
- **笔刷/涂抹(v4 = 参与区域 × 锚点区间填充,Android 同款)**:
  1. **参与区域** = 触碰词所在 block ∪ **笔画横向带**([path.minX-24, path.maxX+24])扫过(x 重叠 ≥16pt)的 block —— 带只圈定「哪些栏参与」,不裁词;
  2. 选区 = 参与区域词构成的阅读链上 **[首触碰 … 末触碰] 整段区间** —— 锚点语义:首行选到行尾、中间行整行、末行从行首选到锚点。
  侧栏内 Workspace→project 斜划 = 侧栏整行填充(行尾词必在)、正文列不进;表格对角线 = 两列都被带扫到 → 整表;三栏正文划字 = 只有正文参与。触碰词永不丢。
  ~~v3.1 的按词裁带~~ 把行尾裁掉、选出「对角线走廊」,被实测否定(Recents 侧栏截图)。
- **轻点语义(对齐原版;2026-07-03 定稿)**:轻点**永不退出覆盖层**,且**点哪都直接重新搜索**(对称)—— 点文字=重新选区(点已选中词除外,在搜索框编辑);点空白/图片=直接出新框重新搜索(~~先关面板缓冲~~ 因与点文字不对称被移除);只想收面板用下拉或面板 ×。退出 = Esc / 再按一次热键(开关语义)。
- ~~v2:区间不跨 block~~ —— 防住了跨窗口乱选,却把表格(每单元格一个 block)撕成碎片(用户实测截图),被否。block 字段保留给物体吸附/HitRegion(F8)。
- ~~v1:触碰集 + 同行有界回填(maxGap)~~ —— 段内斜划只出碎词,交互被否。
- **轻点选词**:点落在哪个词框就选哪个词(happy path,90% 场景)。
- **手柄扩展**:选中后首/末泪滴手柄可拖,扩展**限定在同 block 阅读链**(与笔刷区间填充同一条链、同一语义)。
- **性能**:空间网格索引词框做候选剔除;`pathIntersectsRect` 只测本帧新增 path 段并缓存已触碰词(增量),避免长划后半程二次卡顿。
- 空触碰(划到无文字区)→ 返回空 → 路由到图搜(F7)。
- 参考实现:`docs/reference/SelectionEngine.reference.swift`(v1 对抗验证,触碰几何/跨块隔离仍有效);**测试真源:`Tests/C2SCoreTests/SelectionEngineTests.swift`(v2)**。

### F5 · 文本搜索 + 结果面板
- 选中文字 → 拼查询串 → `https://www.google.com/search?q=…`(深色参数)→ **手机比例悬浮面板**内 `WKWebView`(伪装 Safari UA)。
- 面板行为见 ui-style §4.6(v3):宽 390pt ≈9:19.5、默认右侧停靠、抓手拖动、× 关闭、搜索条药丸、骨架→无缝替换、不遮目标。
- **Add to your search**:搜索条可追加文字(F11 multisearch)。

### F6 · 可调矩形选区
- 圈/划/点在图片或无文字区 → 收敛成**可调矩形**(非多边形,核心机制 §6 已定);拖边微调,框外压暗。
- **矩形一律图搜(v3,2026-07-03 拍板)**:框一旦出现,不管怎么调整都是搜图(原版 Circle to Search 同款);框内有字交给 Lens 识别,绝不中途翻转成文字搜索。~~v1:矩形内取词=文本搜索~~。
- OCR 未完成时落地的轻点/笔划**挂起**,词框到达后按原始意图定夺(点在词上→选词;划过词→文本选择;否则矩形→图搜);用户手动调整过矩形即视为「框」意图,永远图搜。

### F7 · 图像/视觉搜索(Lens;机制 v2,2026-07-02 实测改版)
- **实测结论(改版依据)**:Lens 结果页与**上传会话绑定** —— 跨会话打开显示 "Image not found … not associated with your account";且部分网络出口(代理/风控 IP)对**匿名客户端**的结果页一律 403(URLSession 直传、cookie 注入、真 WebKit 表单导航逐一验证被拒;已登录的浏览器可过)。
- **机制 v2**:裁图(降采样长边 ≤1600px、JPEG q0.85)→ 生成**自动提交的 multipart 上传表单**(内嵌 base64,DataTransfer 注入 File)→ 面板 `WKWebView` 以 `loadHTMLString` 做**顶层表单 POST 导航**(免 CORS)→ WebView 跟随 303 直落结果页。上传与展示**天然同会话**,无需图床。
- **风控恢复**:WebView `decidePolicyFor` 检测主 frame 403 → 原生错误卡「重试 / 登录 Google」;面板 dataStore 持久化,登录一次后 cookie 留存、403 根治。`/sorry` 验证码页放行(用户可在面板内完成人机验证)。
- ~~v1:URLSession multipart 直传 + `willPerformHTTPRedirection` 拦 302 读 `Location`~~ —— 因会话绑定被实测否定;`MultipartFormData`(修双反斜杠 bug 的字节级正确实现)保留在 C2SCore 备用。
- 端点是逆向的、可能失效 → 做好监控与降级预案。

### F8 · 轻点图片 → 物体吸附(已验证原型)
- 抓屏后预跑:`VNGenerateForegroundInstanceMaskRequest`(macOS14,苹果"抠主体")/ `VNGenerateAttention|ObjectnessBasedSaliency` / `VNDetectRectanglesRequest`。
- 轻点 → 吸附到**含该点、面积最小**的检测框;都没有 → 回退到围绕点的默认框。hover 高亮候选框。
- 与 F4 统一到一个 **HitRegion 模型**(词/物体/矩形/条码一张空间索引,`region.kind` 决定文本 vs 图搜路由),替代脆弱的"裁完再和 OCR 相交"。
- 参考:`docs/reference/ObjectSnap.reference.swift`。

### F9 · 条码 / 二维码 + 原生意图
- `VNDetectBarcodesRequest`(QR/EAN/Code128/PDF417/Aztec 等),与 OCR 并发。
- 解析 → 内容类型(URL/Wi-Fi/电话/短信/邮件/联系人/位置/日程/商品),芯片 UI(ui-style §4.5):点框打开、点胶囊复制。
- 原生意图:`NSWorkspace` 开 URL、Wi-Fi 复制密码+跳设置、`CNContactStore` 加联系人、`EKEventStore` 加日程、Maps 开位置、tel/sms/mailto。
- **必须补**:`NSContactsUsageDescription` / `NSCalendarsUsageDescription`(缺了调 `requestAccess` 会**崩**);解析器要处理 Wi-Fi/vCard 的转义、SMS URL 的 `?` 分隔(原项目这些有 bug)。

### F10 · 翻译(待实现)
- Apple **Translation** 框架(`.translationTask` / `TranslationSession`,本地、免 Key)。
- 选区翻译 → 面板显原译对照;**整屏翻译**一键;**边滚边译**列后续。
- 语言:源自动检测,目标默认系统语言、可设置。

### F11 · Multisearch + 可编辑查询(v2,2026-07-03 实现)
- **图+文**:图搜会话中在搜索框输入文字 → 在**当前结果页 URL**(带 vsrid 等会话参数)上追加/替换 `q=<text>`(`SearchURLBuilder.lensMultisearch`),图不被顶掉 —— 与谷歌移动版「添加更多搜索条件」同机制。面板 WebView 经 onURLChange 上报当前页 URL;无 vsrid 时降级为纯文字搜索。
- **可编辑查询**:面板搜索框 = 唯一查询入口,圈选文字直接进框、可编辑后回车替换查询;轻点**已选中**的词不再新建搜索(在框里改)。

### F12 · 复制/动作
- 选中文字/条码内容一键复制(HUD 反馈);结果面板可复制链接。

### F13 · 设置
- 通用:触发方式(热键录制 / 蓄力开关 / 双击 Shift 开关)、启动登录项。
- 外观:跟随系统/深/浅、减弱动态效果。
- 搜索:默认引擎(Google 起步)、OCR/翻译语言。
- 权限:屏幕录制 / 辅助功能(仅当开双击)/ 通讯录 / 日历 状态展示 + 一键跳系统设置。
- 关于:版本、许可。
- **注意**:Settings 场景要注入所需环境对象(原项目漏了→崩)。

### F14 · 四点渐变微光 + 涟漪(质感层,最后做)
- 见 ui-style §4.2 与核心机制 §8。

---

## 3. 权限矩阵

| 权限 | 何时要 | 关键点 |
|---|---|---|
| 屏幕录制(TCC) | F2 抓屏必需 | `CGPreflight/RequestScreenCaptureAccess`;`SCShareableContent` 做能力探针;macOS 周期性重新授权是既定行为 |
| 辅助功能(AX) | 仅"双击 Shift"开启时 | 默认关,不申请;主热键/蓄力/**三指双击(只读帧)都不需要** |
| 通讯录 / 日历 | 扫 vCard / vEvent 码执行时 | **必须在 Info.plist 加 UsageDescription**,否则崩 |
| 输入监控 | 不需要 | 不用 CGEventTap 做主链路;**三指双击读 MT 帧走私有 C API、不走 IOHIDManager,同样不需要**(Karabiner 需 IM 是因走 driver extension/HID,非同路) |
| App Sandbox | **必须关闭** | 三指双击用私有 MultitouchSupport 要求非沙盒(与直分发一致);代价 = **铁定不能上 Mac App Store**(确定结果,非风险) |

---

## 4. 技术栈与约束

- **语言/框架**:Swift + SwiftUI + AppKit 混合。
- **系统底线**:macOS **14.0**(Translation 需 14.4、SCScreenshotManager 需 14.0、前景实例分割需 14;**不要**沿用原项目写死的 15.4)。
- **依赖**:**零第三方**(热键手写 Carbon;其余全系统框架:Vision、ScreenCaptureKit、WebKit、Translation、Contacts、EventKit、Metal/MetalKit)。三指双击用**系统私有框架 MultitouchSupport**(运行时 dlopen,非第三方库;Apple 无兼容承诺,列可选增强、失效有备路)。私有框架 = 不能沙盒 = 不能上 MAS(确定),故三指双击提供 `c2s://capture` 备路保 App Store 版可行。
- **分发**:非沙盒 + Developer ID 签名 + 公证直分发。菜单栏代理(`LSUIElement=YES` + `.accessory`)。
- **签名**:换掉原项目硬编码的 `DEVELOPMENT_TEAM=48XURFCRP3` 与 `sijan.*` bundle id 为自己的。

---

## 5. 非目标(明确不做)

- 账号登录 / 云同步 / 搜索历史。
- 一次抓取超出可视区的超长内容(单帧截图本质;超长文靠"边滚边译"另算)。
- Windows/移动端。
- 自建搜索后端;我们只是把选区导向 Google/Lens/系统能力。

---

## 6. 模块架构(建议,详见核心机制 §9)

拆掉原项目的上帝对象(CaptureController 600 行 / OverlayView 1450 行):
- `DisplayContext` — 单一坐标真源(贯穿全流程)。
- `HotkeyManager` — 热键 + 蓄力/双击手势 → 触发事件。
- `MultitouchTrigger` — dlopen 私有 MultitouchSupport + 三指双击状态机 + 失效自检 + 睡眠/热插拔重注册;与 `HotkeyManager` 并列同为 F1 触发源,失败降级到 `c2s://capture`。
- `CaptureService` — 预热 + 抓屏 + 冻结帧。
- `OverlayWindowController` — 覆盖层窗口/焦点。
- `OCRService` — 单级 OCR + 词框(detached + 缓存)。
- `SelectionEngine` — **纯逻辑、可单测**:分词/分行/block 聚类/WYSIWYG 选择/手柄/矩形/tap-snap(已验证算法)。
- `HitRegionIndex` — 词/物体/矩形/条码统一空间索引。
- `SearchService` — 文本查询 URL + Lens 直传/302 + 降级。
- `ResultPresenter` — 底部面板 + WKWebView + 骨架/错误态。
- `BarcodeService` + `IntentHandler` — 识别 + 原生意图。
- `TranslationService` — Apple Translation。
- `ShimmerRenderer` — 四点渐变 Metal + 涟漪。
- `SettingsStore` — 持久化配置。

---

## 7. 构建顺序(垂直切片,先打通再加深)

1. **切片 A(打通端到端)**:热键 → `DisplayContext` 抓屏 → 冻结覆盖层 → 矩形框选 → 单级 OCR → 文本查询 → 底部面板 WKWebView。证明链路。
2. **切片 B(选择灵魂)**:`SelectionEngine`(WYSIWYG 笔刷 + 轻点选词 + 手柄 + 可调矩形),接入已验证算法;性能增量化;词高亮/手柄 UI。
3. **切片 C(图搜)**:正确 multipart 直传 + 302 + 面板;错误态/降级。
4. **切片 D(差异化)**:tap-snap 物体吸附、条码意图、翻译、multisearch。
5. **切片 E(质感)**:四点渐变微光 + 涟漪 + 各微交互动效。

---

## 8. 必须避开的坑(原项目实测/审计出来的)

- multipart 双反斜杠 → 图搜死;单级 vs 两级 OCR 重复识别;
- 写死 ×2 缩放 + `displays.first`/`NSScreen.main` 双源 + `.aspectRatio(.fill)` → 多屏/缩放屏选择错位甚至失灵;
- min…max 全局阅读顺序填充 → 跨块混选(已用 WYSIWYG 正解替换);
- 缺通讯录/日历 UsageDescription → 崩;Settings 漏注入环境对象 → 崩;
- 缺 `LSUIElement` → Dock 闪;双击 Shift 默认开 → 无谓要 AX 权限 + 误触 + monitor 泄漏;
- 失败把错误串当搜索词搜;零测试(纯逻辑模块务必补单测)。
- (三指双击/私有框架)别链接 .tbd(arm64e PAC bus error + Big Sur 起框架并入 dyld 缓存致编译期链接失败)→ 用运行时 dlopen;别读 MTTouch 结构体内部偏移、别调 `MTDeviceGetDeviceID`(跨版本断裂);MTTouch 布局 macOS 26 已变,按现行 MiddleClick/OpenMultitouchSupport header 并在 14/15/26 真机校验;睡眠唤醒/热插拔不重注册 → 回调静默失效;三指拖移(辅助功能,默认关)一旦被用户开启会独占三指、令双击难识别 → 做行为自检 + 引导。
