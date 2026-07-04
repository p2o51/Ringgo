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
| F1 | 触发/唤起(热键 + 蓄力手势 + 三指双击 + 菜单栏) | MVP(切片A;三指双击=可选增强) | **已实现(三指双击为 Developer ID 实验开关)** |
| F2 | 抓屏 + 冻结覆盖层(多屏/Retina 正确) | MVP(切片A) | 定稿,含坐标 P0 |
| F3 | 本地 OCR(单级 accurate,词级框,多语含中文) | MVP(切片A/B) | 已验证 |
| F4 | 选择:笔刷/涂抹(WYSIWYG)+ 轻点选词 + 手柄扩展 | MVP(切片B) | **正解 10/10 验证** |
| F5 | 文本搜索 → 结果底部面板(WKWebView) | MVP(切片A) | 定稿 |
| F6 | 可调矩形选区(图片/无文字区) | 切片B/D | 定稿 |
| F7 | 图像/视觉搜索(直传 Lens + 302 + 面板) | 切片C | 定稿(需修 multipart) |
| F8 | 轻点图片 → 物体吸附 | 切片D | **已回退(2026-07-03 实测:显著性候选在桌面截图上噪声大、吸附随机)** |
| F9 | 条码/二维码识别 + 原生意图(URL/Wi-Fi/联系人/日历/地图/电话/邮件) | 切片D | 定稿(需补权限串) |
| F10 | 翻译(选区 + 整屏,后续边滚边译) | 切片D | **首刀已实现(2026-07-03,macOS 15+)** |
| F11 | Multisearch(选区 + 追加文字提问) | 切片D | 定稿 |
| F12 | 复制/分享动作 | 切片B | 定稿 |
| F13 | 设置 + 首次欢迎引导 | 切片A/B | **已实现(2026-07-03)** |
| F14 | 四点渐变微光 + 涟漪(质感层) | 切片E | **已实现(2026-07-03,SwiftUI Shader)** |
| F15 | 可视化(文字/图片)+ 图片编辑(nano banana,AI Mode) | 增强 | **已实现(2026-07-03)** |
| — | 非目标:整段落跨屏抓取、账号登录、历史记录同步 | out | 明确不做(见 §5) |

---

## 2. 逐功能行为规格

### F1 · 触发/唤起
- **主热键**:Carbon `RegisterEventHotKey`,默认 ⌘⇧S,可在设置里录制修改并持久化。免辅助功能权限。注册失败要**给用户反馈**(原项目静默失败还照存)。
- **蓄力手势(2026-07-03 改为默认关,opt-in)**:按住 ⌘⇧ 超过 ~250ms 触发(`flagsChanged` 计时,免辅助权限)——实测普通 ⌘⇧ 前缀快捷键(⌘⇧Z 等)按慢即误触发,故默认关闭、设置里开启;蓄力期间渐显四点微光作可视反馈;阈值前松开=取消(天然防误触)。这 250ms 正好并行完成抓屏 → **松手即冻结、零空窗**。
- **双击 Shift**:可选、**默认关闭**(它需要辅助功能权限,会破坏免权限卖点;原项目默认开还泄漏 monitor)。开启时才申请权限。
- **三指双击触控板(Developer ID 实验增强,默认关闭;已实现)**:设置 → 通用打开后，全局(任意 App 前台)三指连续两次轻点唤起；设置页实时显示设备数/休眠/失败状态并支持重试。
  - *为什么只能私有框架*:公开 API 做不到后台全局多指——`NSTouch`/手势识别器只在本 App 前台且触摸落自己窗口内才有数据;`CGEventTap` 连 swipe/magnify 都拿不到(CGEventType 无任何手势类型);`NSEvent.addGlobalMonitorForEvents` 全局连宏观手势都收不到(仅 mouseMoved/keyDown)。唯一路径 = **私有 `MultitouchSupport.framework`**(BTT/Jitouch/MiddleClick/MiddleDrag 同款,含 2026 新项目仍选此路)。
  - *实现*:`C2SMultitouchShim` **运行时 `dlopen`/`dlsym`,不链接 .tbd**;`MTDeviceCreateList` 枚举全部设备 → 逐个 `MTRegisterContactFrameCallback` + `MTDeviceStart`。C 层只把独立的手指数/时间戳转给 Swift，绝不读取跨系统易变的 `MTTouch` 结构体。
  - *三指双击判定状态机*:手指数**严格 ==3**(出现第 4 指作废)、单 tap **≤260ms**、两拍间隔 **25–340ms**；既处理 n=0 尾帧，也用 75ms 静默计时器兼容“抬手后停止产帧”的系统行为。第一拍预热抓屏，第二拍触发；65 项测试中含 5 个状态机边界测试。
  - *权限*:**只读帧唤起自家 overlay、不合成/不拦截事件 → 零 TCC**(免辅助功能、免输入监控);仅需**非沙盒**(已满足)。
  - *延迟*:双击天然 ~200-300ms 识别延迟(等第二拍)→ **第一拍合格即预热抓屏、第二拍到达即冻结**。
  - *已实测(macOS 26.5.1 开发机)*:框架 `dlopen` 成功、`MTDeviceCreateList` 枚举到触控板、注册+启动成功、**无权限弹窗**。探针见 `docs/reference/MultitouchProbe.reference.c`(可 `clang … -framework CoreFoundation` 直接跑)。
  - *风险管理*:私有 API 无契约、**MTTouch 结构体布局 macOS 26/Tahoe 已改过** → 当前实现完全不读该结构体；符号缺失/无设备时显示失败原因并保留重试，睡眠前 stop、唤醒后重新枚举。**三指双击永远是可选增强,承重触发仍是热键/蓄力/菜单栏。**
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
- **分块识别(F18,2026-07-04)**:整屏单 pass 时 Vision 对大图内部降采样,小字在部分机器/系统上**补丁式漏词**(朋友实测:同一 Finder 侧栏同字号,「图片/影片」认出、「桌面/文稿/下载」认不出,笔刷选区中间开洞;~~对比度/台前调度理论~~ 被该截图推翻)。大图切 ≤2048px 瓦片(重叠 128px 防切词)**并发**识别(≤3 路在飞),跨瓦片词级去重(IoU>0.6 判同,保留所在行更完整者)后全局聚 block;小图仍单 pass。骑缝长行被切成两段行,SelectionEngine 按 midY 聚行时自动合回,阅读链/选择语义不受影响。补刀 OCR(F17)沿用单 pass 路径。
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

### F8 · 轻点图片 → 物体吸附(已回退 2026-07-03)
> **回退记录**:显著性(objectness/attention)+ 矩形检测在**桌面 UI 截图**上产出的候选框
> 噪声大,轻点吸附体感随机,用户实测否定 → 整条链路(检测服务/吸附纯函数/hover 提示/
> 圈选贴合)已移除(git 历史可寻)。重做前提:前景实例分割(掩膜→bbox)或更强的
> UI 元素分割信号;届时按下述原设计演进。
- **实现**:`ObjectDetectionService`(actor)与 OCR 并发预跑 objectness/attention 显著性 + 矩形检测(前景实例掩膜转 bbox 成本高,留 TODO);候选 → `ObjectSnap.filtered + dedupe`(IoU 去重留小框)。
- **轻点**:吸附「含点、面积最小」候选框;**hover**:候选框 accent 20% 描边 + 极轻辉光提示。
- **圈选闭合 → 贴合轮廓**(原版"形态转化"):笔画包围盒经 `ObjectSnap.bestMatch`(被包住的最大候选,IoU 兜底)吸附到物体真实边界;白色四角括号裁剪框 + 光谱辉光环(ui-style §4.3 v2)。
- 原设计(供演进):`VNGenerateForegroundInstanceMaskRequest`(macOS14,苹果"抠主体")/ `VNGenerateAttention|ObjectnessBasedSaliency` / `VNDetectRectanglesRequest`。
- 轻点 → 吸附到**含该点、面积最小**的检测框;都没有 → 回退到围绕点的默认框。hover 高亮候选框。
- 与 F4 统一到一个 **HitRegion 模型**(词/物体/矩形/条码一张空间索引,`region.kind` 决定文本 vs 图搜路由),替代脆弱的"裁完再和 OCR 相交"。
- 参考:`docs/reference/ObjectSnap.reference.swift`。

### F9 · 条码 / 二维码 + 原生意图
- `VNDetectBarcodesRequest`(QR/EAN/Code128/PDF417/Aztec 等),与 OCR 并发。
- 解析 → 内容类型(URL/Wi-Fi/电话/短信/邮件/联系人/位置/日程/商品),芯片 UI(ui-style §4.5):点框打开、点胶囊复制。
- 原生意图:`NSWorkspace` 开 URL、Wi-Fi 复制密码+跳设置、`CNContactStore` 加联系人、`EKEventStore` 加日程、Maps 开位置、tel/sms/mailto。
- **必须补**:`NSContactsUsageDescription` / `NSCalendarsUsageDescription`(缺了调 `requestAccess` 会**崩**);解析器要处理 Wi-Fi/vCard 的转义、SMS URL 的 `?` 分隔(原项目这些有 bug)。

### F10 · 翻译(首刀已实现 2026-07-03;macOS 15+,旧系统按钮禁用)
- Apple **Translation** 框架(`TranslationSession`,本地、免 Key;`.translationTask` 宿主视图桥接,同目标重译需 `Configuration.invalidate()`)。
- **整屏翻译**:底部工具条「翻译」点按 = 开关;OCR 视觉行(engine.visualLines)→ Lens 式**原位盖板**(thinMaterial 板 + 自适应字号译文贴回原行);进度胶囊「翻译中 n/N」+ 错误卡重试。
- **选区翻译(v2,2026-07-03 拍板)**:迷你工具条「翻译」= 开关 —— 开:真实查询 = 「将下面的文字翻译成 {目标语言}:{选中文字}」+ **Google AI Mode**(udm=50),药丸显示**原文**(可编辑回车重译)+ 「翻译 · 语言」chip,按钮高亮;再点/任何新搜索 = 退回普通搜索。~~Apple Translation 选区盖板~~ 改为整屏翻译专用。
- **语言 UX**:目标默认 = 上次选择(persisted `c2s.translationTarget`)∨ 系统首选;hover 翻译按钮弹语言菜单(排序 = 用户偏好语言序列 → 常用语言);源语言自动检测。
- 边滚边译列后续。

### F11 · Multisearch + 可编辑查询 + 整屏提问(v3,2026-07-03)
- **整屏提问(底部工具条,安卓同款)**:输入问题(可用系统听写)→ **整张截图**发 Lens(面板内表单上传)→ 结果页 vsrid URL 就绪的瞬间自动以 multisearch 挂上问题 → 图+文 AI 问答;药丸显示整屏缩略图 + 问题。
- **图+文**:图搜会话中在搜索框输入文字 → 在**当前结果页 URL**(带 vsrid 等会话参数)上追加/替换 `q=<text>`(`SearchURLBuilder.lensMultisearch`),图不被顶掉 —— 与谷歌移动版「添加更多搜索条件」同机制。面板 WebView 经 onURLChange 上报当前页 URL;无 vsrid 时降级为纯文字搜索。
- **可编辑查询**:面板搜索框 = 唯一查询入口,圈选文字直接进框、可编辑后回车替换查询;轻点**已选中**的词不再新建搜索(在框里改)。

### F12 · 复制/动作(2026-07-03 v2:统一 ⌘C)
- **⌘C 复制当前选区**:文字选区 → 文本;矩形选区 → 按坐标真源裁剪的图片(触觉确认);面板/工具条输入框聚焦时放行系统复制不劫持。~~迷你工具条复制按钮~~ 已移除(与 ⌘C 重复)。
- 条码内容复制(F9)后续;结果面板可复制链接。

### F13 · 设置 + 欢迎引导(已实现 2026-07-03)
- **设置骨架**:标准 SwiftUI `Settings` 场景 + 5 个工具栏 tab + grouped Form，固定 560×430；全部使用系统语义色/系统控件。
- **通用**:键帽式热键录制器(实时修饰键预览、Esc/失焦取消、无修饰键报错、条件式还原默认)；**录制期间暂停 Carbon 热键与蓄力监听**，避免当前组合被全局注册先消费并误唤起覆盖层；另含蓄力/双击 Shift 与登录启动。
- **外观**:浅色/深色/跟随系统三张原生样片 + 减弱动态效果。
- **搜索**:Google/OCR 静态能力说明；翻译目标语言 Picker 直接绑定 `translationTargetCode`，首项跟随系统并补持久化语言码兜底。选区/图片翻译在 macOS 14 可用，只有整屏 Apple Translation 需要 macOS 15+。
- **权限**:屏幕录制与按需出现的辅助功能状态；屏幕授权请求后明确提示“需要重新启动”，复用 `AppCoordinator.relaunch()`，绝不让授权流程陷入重复请求。
- **关于**:Ringgo 图标、0.6.0 版本与「查看欢迎引导」入口。
- **首次欢迎引导**:AppKit 手持 500×590 accessory 窗口，两步（产品介绍 → 权限/热键/登录项）；首次启动自动显示、关闭即不再打扰，可从菜单栏/关于页重开。屏幕授权重启前写一次性 resume 标记，新进程直接回第二步；已授权时「开始使用」收尾到一次真实圈选。
- **接线约束**:Settings/MenuBar/Welcome 都必须注入同一组 `settings`、`coordinator`、`welcome` environment objects。

### F14 · 四点渐变微光 + 涟漪(已实现 2026-07-03)
- **实现**:SwiftUI Shader(stitchable Metal)而非 MTKView —— `c2s_fourPointGradient`(四色点 Lissajous + 高斯加权,trackingAmount 收敛笔尖,saturation 降饱和)+ `c2s_ripple`(出现涟漪 1.1s 一次);状态机 idle → tracking(笔刷)→ ambient(定格)由选择状态派生。
- **工程注意**:命令行 SwiftPM 不编 Metal → `default.metallib` 预编译进仓库(`Scripts/build-shaders.sh` 重新生成);减弱动态 → 静态渐变 + 无涟漪无跟随。
- 设计规格见 ui-style §4.2 与核心机制 §8;蓄力阶段的微光预显(F1)待做。

### F15 · 可视化 + 图片编辑(nano banana,2026-07-03)
- **统一机制**:prompt 包装 + Google **AI Mode**(udm=50),复用 F10 选区翻译的「chip + 药丸可编辑重发」模式(`QueryPromptMode`/`QueryModeChip` 泛化了原 translateChip);任何新普通搜索退出模式。
- **可视化(文字选区)**:迷你工具条「可视化」= 开关(与「翻译」并排)—— 真实查询 = 「请可视化下面的内容:适合数据或结构就生成可视化图表…更适合画面就用 nano banana 生成一张图片:{选中文字}」;药丸显示原文(可编辑回车重发)+「可视化」chip。
- **可视化(图片选区)**:迷你工具条「可视化」= 一次性动作 —— 在**当前 Lens 会话**(vsrid)上 multisearch 挂可视化 prompt 并切 **udm=50**(`lensMultisearch(aiMode:)` 替换原 udm=26,图随会话参数保留,Gemini 能看到圈出的图;**已实测可用**);会话 URL 未就绪(上传在飞)→ 挂起(`PendingLensPrompt`,与整屏提问同机制),vsrid 就绪自动发出。后续搜索框输入 = 同会话 AI Mode 追问。
- **翻译(图片选区)**:迷你工具条「翻译」= 一次性动作,同上机制 —— prompt = 「请把这张图片里的所有文字翻译成{目标语言},按原文的结构和顺序输出译文」,目标语言与文字翻译共用同一设置(F10 语言 UX);chip「翻译 · 语言」。
- **编辑(图片选区,v4 内联输入)**:点「编辑」→ 迷你工具条**就地展开**为 [编辑(高亮,点击收起)][指令输入框(自动聚焦)][↑ 提交],摆位随展开宽度重算(不出屏),换框/调框即收起;指令回车/点 ↑ = 「请用 nano banana 编辑这张图片,直接生成编辑后的图片。编辑要求:{指令}」+ 当前 Lens 会话 multisearch + AI Mode,结果进面板 + 「编辑 · Nano Banana」chip;模式保持,面板药丸里改指令回车 = 对原图重新编辑;草稿保留,再次展开可微调重发。~~v3 聚焦面板搜索框方案~~ 已废(输入离选区太远,2026-07-03 用户否定;focusQueryToken 机制一并移除)。
- **会话安全**:coordinator 以 `lensSessionURL` 跟踪当前圈图的 vsrid 结果页,新图搜/新文字搜/整屏提问一律清空 —— 可视化/编辑绝不挂到上一张图的旧会话上。
- **迷你工具条 v3**:.text = [翻译][可视化],.image = [翻译][可视化][编辑](图片选区自 v2 无按钮后重新有了工具条);多键并存 → v2 整胶囊 accent 高亮改为**按钮级 accent 前景高亮**(胶囊内塞小胶囊依旧不做)。
- **选区类型切换(「改选」chip,2026-07-04)**:迷你工具条动作胶囊左侧隔 8pt 加一枚**独立小胶囊**(次要前景,语义是「换选法」不是「做事情」)——文字选区 → 「改选图片」(图上文字被 OCR 误选时,外接框外扩 8pt 转可调矩形并立即图搜);图片选区 → 「改选文字」(框内词——词中心落框内——按阅读序整体选中发文字搜索,`SelectionEngine.words(inRect:)`);框内没有已知词 → **定向补刀 OCR**(F17,2026-07-04):裁剪选区、小图放大(≤4×,目标 ~512px)后单独重识别——整屏识别对小字/低对比字会漏(Vision 对大图降采样;实测毛玻璃侧栏文字的识别成功率随台前调度侧条显隐变化,机制 = 背后背景变 → 像素对比度变),补刀几乎必中;补刀期间 chip 图标位转圈。补刀词经 OCRWordMerger 并入词表(IoU>0.5 去重、id 重排、block 偏移)并被记忆,整屏 OCR 晚到时重新并入 + 选区按词框映射保住(不冲掉刚定格的选区)。真没有文字(或补刀也空)→ chip 原地**摇头动画**(±5pt 三个来回,减弱动态跳过)+ 上方浮出「未识别到文字」玻璃气泡 1.6s 自动隐去,选区原地不动;编辑输入展开时 chip 让位隐藏。

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
