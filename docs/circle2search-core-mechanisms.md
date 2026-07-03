# Circle to Search (macOS) — 核心机制与从零重建蓝图

> 本文是对开源项目 `sijan2/Circle2Search` 核心技术的**净室学习笔记**:只记录"用什么 API、怎么串起来、有哪些坑、从零怎么做更好",不照搬其源码。作为我们自己从头实现的设计参考。
>
> 关键结论:它把最难的几块(热键、捕获、OCR、词级选择、直传 Lens、内嵌 WebView、微光)都跑通了,但**真正的"圈选"手势、翻译、多屏都缺**,且有一些结构性缺陷可以在重写时一并解决。

---

## 0. 端到端管线(先建立心智模型)

```
按下热键 / 双击 Shift
   │
   ▼
用 SCScreenshotManager 抓当前屏静帧 (CGImage)
   │
   ├─► 铺一层"透明 borderless 全屏窗口",背景放这张静帧 → 制造"画面冻结"感
   │      同时叠上:涟漪(出现动画) + 微光(Google 四色) + 十字光标
   │
   ├─► 后台并发跑 Vision:①快速全屏 OCR(拿词级框)②条码/二维码检测
   │
   ▼
用户在覆盖层上操作:
   • 笔刷/涂抹划过文字  → 命中词 → 拼成查询串 → google.com/search?q=… → 内嵌 WKWebView
   • 画一个区域(没命中文字)→ 裁图 → 直传 lens.google.com/v3/upload → 抓 302 → 内嵌 WKWebView
   • 点击条码芯片        → 原生 intent(打开 URL / 连 Wi-Fi / 加联系人…)
   │
   ▼
结果显示在锚定到选区的 NSPopover 里(深色 UI + Google 搜索条 + WebView)
```

七个核心子系统:**触发 → 捕获 → 覆盖层窗口 → 异步 OCR → 坐标系 → 选择交互 → 结果(Lens/文本 + WebView)**,再加一层**微光/涟漪**做质感。下面逐个拆。

---

## 1. 触发 & 后台代理

**主热键:Carbon `RegisterEventHotKey`(免辅助功能权限,这是最大优点)**

要点:
- 用一个静态的 `EventHotKeyID`(`signature` 用 FourCharCode,如 `"htk1"`;`id` 用 1)。
- `InstallEventHandler(GetApplicationEventTarget(), handler, …)` 装一个 C 回调;**回调必须是不捕获上下文的纯 C 函数指针**——所以它内部通过单例 + `DispatchQueue.main.async` 把事件转发到一个 Combine `PassthroughSubject`,再由 AppDelegate 订阅触发捕获。
- `RegisterEventHotKey(keyCode, modifiers, hotKeyID, target, 0, &ref)`;`modifiers` 用 Carbon 常量 `cmdKey | shiftKey`(不是 `NSEvent.ModifierFlags`)。
- FourCharCode 需要一个 `init(_ String)` 扩展:`utf16.reduce(0){ ($0<<8)+OSType($1) }`。

**后台菜单栏代理**
- 运行时 `NSApp.setActivationPolicy(.accessory)` + SwiftUI `MenuBarExtra`。
- ⚠️ 改进:同时在 Info.plist 设 `LSUIElement = YES`,否则启动瞬间 Dock 图标会闪一下。

**双击 Shift 触发(可选,像 Android)**
- `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` + local monitor,检测 400ms 内两次"只按了 Shift、无其他修饰键"。
- ⚠️ 这条**需要辅助功能权限**,会破坏"免权限"的卖点。从零做时**默认关闭、设为显式 opt-in**,并且 local monitor 的返回值要保存好以便移除(原项目这里漏了,泄漏 monitor)。

---

## 2. 捕获 & "冻结画面"

```
SCShareableContent.current → 选 display
  → SCStreamConfiguration { width, height, pixelFormat=32BGRA, showsCursor=false }
  → SCContentFilter(display:excludingApplications:exceptingWindows:)
  → SCScreenshotManager.captureImage(contentFilter:configuration:)  // 单帧,无录屏指示器
```

- 用 `SCScreenshotManager`(macOS 14+)而不是弃用的 `CGWindowListCreateImage`。它抓单帧、无"正在共享屏幕"红点。
- "冻结感"就是把这张 CGImage 当作覆盖层的背景铺满,用户操作时底下画面不动。
- 抓完记录 `NSWorkspace.shared.frontmostApplication`,退出时再 `activate()` 回去。

**⚠️ 两个必修的坑(原项目在这里是错的):**
1. **不要硬编码 `width = display.width * 2`**。用该 display 对应 `NSScreen` 的 `backingScaleFactor`。硬编码 2x 在 1x 外接屏 / 3x / 缩放分辨率上全错。
2. **多屏**:原项目 `content.displays.first` 与 `NSScreen.main` 混用,不一致就裁错区域。从零做:先确定**鼠标所在的那块屏**,后面所有坐标、覆盖层、viewport 都统一用它。建议封一个 `DisplayContext { screen, scaleFactor, frame }` 贯穿全流程。

---

## 3. 覆盖层窗口

- 自定义 `NSWindow` 子类(`canBecomeKey`/`canBecomeMain` 返回 `true`,否则 borderless 窗口拿不到键盘焦点)。
- 配置:`styleMask=.borderless`、`isOpaque=false`、`backgroundColor=.clear`、`level=.floating`、`collectionBehavior=[.managed,.transient,.fullScreenAuxiliary]`(能盖在全屏 App 上)、`hasShadow=false`。
- 用一个 `NSHostingView` 子类(重写 `acceptsFirstResponder=true`)托管 SwiftUI 的 `OverlayView`。
- `NSApp.activate(ignoringOtherApps:true)` → `makeKeyAndOrderFront` → `makeFirstResponder(hostingView)`。原项目还写了一套"失焦后重试恢复焦点"的逻辑(app 变 active 时延时 100ms 重新 makeKey)——这是被现实逼出来的,记着可能需要。
- ESC 取消:`NSEvent.addLocalMonitorForEvents(matching:.keyDown)`,`keyCode==53` 时取消并 `return nil` 吃掉事件(防蜂鸣)。
- KVO 观察窗口 `isVisible`,被遮挡时暂停 Metal 渲染省电。

---

## 4. 异步 OCR 管线(关键,决定"选词"体验)

**两级 Vision 识别:**
- **快扫**:抓屏后立刻在**全屏**跑 `VNRecognizeTextRequest`,`recognitionLevel=.fast`、`usesLanguageCorrection=false`、`automaticallyDetectsLanguage=true`。目的是**在用户还没画完之前**就把词级框准备好,发布给覆盖层。
- **精扫**:对最终裁下来的小图跑 `.accurate` + `usesLanguageCorrection=true`,得到要发去搜索的查询串。也可用 `regionOfInterest` 聚焦到笔刷区域提高精度。

**词级 bounding box(整个交互的地基):**
```
对每个 VNRecognizedTextObservation:
  let cand = obs.topCandidates(1).first        // 拿最佳候选
  fullString.enumerateSubstrings(.byWords) { word, swiftRange, … in
      let box = try cand.boundingBox(for: swiftRange)   // ← 关键 API:每个词的框
      // box.boundingBox 是"归一化、左下原点"的矩形
  }
```
`RecognizedText.boundingBox(for: Range)` 是 Vision 里能精确拿到**单词级**框的方法,是"划过就精确高亮那几个词"的前提。

**条码**:`VNDetectBarcodesRequest`,`request.symbologies` 指定格式(`.qr,.ean13,.code128,.pdf417,.aztec…`),与 OCR 并发跑。

---

## 5. 坐标系(最容易翻车的地方,单独拎出来讲清楚)

同时存在**三套坐标**:

| 空间 | 原点 | 单位 |
|---|---|---|
| SwiftUI 覆盖层 | 左上 | 点(= `NSScreen.frame` 的点数) |
| Vision 归一化 | **左下** | 0..1 |
| CGImage 像素 | 左上 | 像素(= 点 × scaleFactor) |

两个必用的换算:

**① Vision 归一化 → 覆盖层屏幕矩形(注意翻 Y):**
```
x = nx * W
y = (1 - ny - nh) * H      // 翻 Y:左下 → 左上
w = nw * W ;  h = nh * H
```

**② 覆盖层路径包围盒 → 图像像素裁剪矩形(翻 Y + 缩放):**
```
scaleX = imageW / screenW          // ← 用真实 scaleFactor,别写死 2
pixelX = boundsX * scaleX
pixelY = (screenH - boundsY - boundsH) * scaleY   // 翻 Y
裁剪:image.cropping(to: rect.intersection(imageRect).integral)   // 夹进图像边界 + 取整
```

**从零做的纪律**:坐标缩放**只认一个来源**(`DisplayContext.scaleFactor`),活动屏**只认一块**。原项目的 retina/多屏 bug 全部源于这两条没守住。

---

## 6. 自由选择交互(灵魂)——算法拆解

**画笔**:`DragGesture(minimumDistance: 2)` 累积 `pathPoints` 和一条 SwiftUI `Path`;用 `Canvas` 画白色 6dp 圆头描边 + 一条更宽的半透明"辉光"描边 + 笔尖圆点。用距离阈值(相邻点 <2pt 跳过)抽稀,降复杂度。

**笔刷 → 命中词(核心算法)**:每次拖动(节流 ~60fps)执行:
1. `brushBounds = pathPoints 的包围盒`,外扩一个 `selectionRadius`。
2. 遍历**预计算好的** `SelectableWord`(有 `screenRect`):先用 `brushBounds.intersects(word.rect)` 粗筛,再用 `pathIntersectsRect(pathPoints, word.rect 外扩 radius)` 精判。
3. `pathIntersectsRect` = 逐段做**线段-矩形相交**:矩形是否含端点,或线段是否与矩形四边相交(用叉积 `segmentsIntersect`)。
4. 收集命中词的 index,取 `min...max` 连续区间,按阅读顺序拼成短语。

**阅读顺序**(`orderSelectableWords`):按词高中位数定一个行阈值 → 按 `midY` 把词分行 → 行内按 `minX` 从左到右 → 重排 `globalIndex`。这样 `min...max` 才是"人读的顺序"。

**选择手柄**(泪滴 handle,像 iOS/macOS 文本选择):
- 确认选择后,在首/末词画泪滴 handle(`Canvas` 画圆+杆)。
- `handleDragGesture`:先在 handle 中心 20pt 半径内命中,再在拖动中找**同一行**(垂直距离 ≤ 行阈值)里水平最近的词 → 扩展 `[start,end]` 区间 → 重建文本。

**点击语义**(有个精妙的两段式):
- popover 开着时:点词 → 换查询。
- popover 刚被"点外部"关掉时:用一个 `needsConfirmTapToExit` 标志,**第一次点只清标志、不退出**(因为这一下点击本来是用来关 popover 的),第二次点才真正退出覆盖层。避免"一次点击既关面板又退出"。

**✅ 选择模型(已用真实 Vision 验证 → 定稿,2026-07-01)**

> 纠正:不要做多边形/非矩形抠图。谷歌的"圈"最终也**收敛成一个可调的矩形框**(调研独立印证:"adjustable bounding box")。

- **四种手势(圈/划/涂/点)最终都归一成一个矩形框**:圈/划/涂 → 取所碰/所围内容的**外接矩形**;点 → 见下。之后允许用户**拖边微调**这个矩形。**不做 point-in-polygon,不做非矩形蒙版裁图**——省一大块复杂度。
- **轻点即搜 + 吸附(关键交互)**:
  - 点**文字** → 选中那个词。用 Vision `boundingBox(for:)` 分词,**已验证**:一张图 34 词全部拿到精确框,中文按 2 字切块(本地/文字/识别/测试)。轻点落在哪个词框里就选哪个。
  - 点**图片** → 吸附到该物体的分区。macOS 原生可做,**已在真实照片验证**:
    - `VNGenerateForegroundInstanceMaskRequest`(macOS 14+,苹果"抠主体"同款)→ 前景实例 → 点中即吸附;
    - `VNGenerateAttentionBasedSaliencyImageRequest` → 主体紧框;`...ObjectnessBased...` → 多物体框;
    - `VNDetectRectanglesRequest` → 网页/UI 截图里的卡片/缩略图矩形(真实图上 conf=1.00 检出 6 个)。
    - **落地策略**:抓屏后预跑上述检测;点击时吸附到"**包含该点、面积最小**"的框;都没有则回退到围绕点的默认框。
- **文字 vs 图片的分支**由"矩形落在什么区"决定:命中 OCR 词区 → 文本搜索/复制/翻译;命中物体/矩形区 → Lens 图搜。
- **已验证通过(8/8)**:选单词/短语、一笔快划选整段(跨多行 min…max 自动补全)、无文字区→0 命中→路由图搜、小范围精确吸附。测试代码在 scratchpad 的 `SelectionTest.swift` / `ObjectSnapTest.swift`。

**🔁 v3 修订(2026-07-03,用户拍板,现行)**:选择规则收敛为**全局阅读链区间填充**——全屏词按视觉行聚成一条链(行聚类局部阈值 0.6×min(词高,行均高),混合字号安全),选区 = [首触碰…末触碰] 连续区间。表格/多栏/跨段一笔全选(v2 的 block 隔离把表格撕碎,用户实测截图后被否);跨区域对角线连带中间内容 = 谷歌同款、已明示接受的权衡。矩形选区一律图搜(框=图,调整不翻转)。实现 `Sources/C2SCore/SelectionEngine.swift`,测试真源 `Tests/C2SCoreTests/SelectionEngineTests.swift`。

**🔁 v2 修订(2026-07-02,已被 v3 取代)**:选区 = 各 block 阅读链上 [首触碰…末触碰] 区间;跨 block 永不合并。v1 的"同行有界回填(maxGap)"防住了跨块乱选,但段内斜划只出碎词。下文保留作 v1 历史依据(其触碰集几何、坐标 P0 结论仍然有效)。

**🔴 选词手势 bug 与修复(用户实测复现 → 对抗验证 → 正解 10/10 通过,`SelectionFixV2.swift`)**

> 注:第一版"主簇+按行补齐"被对抗验证打穿(它会**丢弃笔画真正碰到的词**、且挡不住同 y 双栏)。下面是收敛后的**单一正解规则**,已过全部对抗场景。

- **病根**:原 `updateBrushedTextSelection` 用**全局阅读顺序 `min…max` 填充**——笔画碰到"靠上词"和"靠下词",就把两者之间(按 y→x 全局排序)的所有词全选进来;`orderSelectableWords` 又把全屏词拉平成一条 globalIndex,使 index 区间毫无空间意义。杂乱屏上对角线蹭两块 → **跨块混选一大片**(实测 8~11 个跨块乱词,正是你截图的症状)。次要根因:坐标写死 2x、`displays.first`/`NSScreen.main` 双源、背景 `.aspectRatio(.fill)` → 缩放/多屏下"划这里选那里"甚至选到空。
- **正解:单一规则(WYSIWYG)** —— 最终选区 = **触碰集** ∪ **{同一 block、同一行、夹在相邻已保留词之间、且离前一个已保留词水平间距 ≤ maxGap 的词}**。三条硬不变式:
  1. **笔画几何穿过的词永远保留,绝不 break 丢弃**(修 ADV-2:"swiftc … done" 不再只剩 swiftc)。
  2. **只在相邻已保留词之后、gap 合法时回填**;弧线绕过、gap 过大的词一律不进(修 ADV-7);跳过时**不 break、不更新链**,后面的触碰词照样保留。
  3. **一切分组/回填强制不跨 block**(用 `sourceRegionIndex`/几何聚出的 block);**同 y** 的聊天块与终端块因 block 不同而物理隔离(修 ADV-8 双栏桥接)。
  4. **maxGap = 该行相邻词间距的中位数 × k(≈1.4)+ radius**,而非"字形高度×系数"——自适应两端对齐/终端宽制表符/CJK 方块字(修 ADV-6)。
  5. handle 拖拽用**同一核心**,但 `startIdx…endIdx` 限定在**同 block 阅读链**内(不复制补丁)。
  6. **热路径性能**:空间网格索引词 rect 做候选剔除;`pathIntersectsRect` 只测**本帧新增 path 段**并缓存已触碰词(增量),避免每帧 O(词×path 段)在长划后半程二次增长。
- **坐标规则(P0)**:贯穿全流程一个 `DisplayContext{pointSize=capture 屏 NSScreen.frame, pixelSize=CGImage 尺寸, scale=backingScaleFactor}`;抓屏用**鼠标所在屏**(非 `displays.first`)、`config.w/h = display.px × 真实 scale`(废弃 ×2);overlay 与 capture **同屏**;背景 `Image` 用**显式 `.frame(点尺寸)`**(废弃 `.aspectRatio(.fill)`,否则像素与词框错位会让相交全 miss、返回空选)。
- **验证结果(10/10,含对抗)**:S1 用户 bug(旧 8 词跨块 → 新 3 词只留触碰)、ADV-2 远距同行两词都留、ADV-4 斜穿段落只留触碰不成碎片、ADV-6 宽字距整行不砍断、ADV-8 V 形笔画双栏不桥接、正常沿行划/长段/轻点/弧线绕过回归全过。

---

## 7. 图搜:直传 Lens + 抓 302 + 内嵌 WebView(你最爱的那块)

> **🔁 v2 修订(2026-07-02,实测否定本节传输方案)**:本节的 URLSession 直传 + 拦 302 机制在 2026 年实测不可用 —— Lens 结果页与**上传会话绑定**(跨会话 = "Image not found"),风控网络下匿名客户端结果页一律 403。新方案:**面板 WKWebView 内自动提交 multipart 表单做顶层 POST 导航**(免 CORS,WebView 跟随 303 直落结果页,上传/展示同会话),持久 dataStore + 403 → 「登录 Google」恢复。见 features.md §F7 与 `Sources/C2SAppKit/Search/LensService.swift`。本节余下内容(multipart 正确性、UA、/sorry、错误态原则)仍有效。

**机制(比调研报告的"图床+浏览器"聪明,不需要任何第三方图床):**
1. 把裁下来的图编码成 JPEG/PNG。
2. `POST https://lens.google.com/v3/upload?ep=…&st=<毫秒时间戳>&hl=<语言>&vpw=<视口宽>&vph=<视口高>`,`multipart/form-data`:
   - 字段 `encoded_image`(文件名 + `Content-Type: image/jpeg` + 图像字节);
   - 可选字段 `processed_image_dimensions` = `"宽,高"`。
   - 头:浏览器 `User-Agent`、`Referer`/`Origin` 指向 `https://www.google.com/`。
3. **关键技巧**:用一个 `URLSessionTaskDelegate`,在 `willPerformHTTPRedirection` 里 `completionHandler(nil)` **阻止自动跟随重定向**。这样能拿到 `302/303` 响应,读它的 **`Location` 头 —— 那就是 Lens 结果页 URL**。
4. 把这个 URL 丢进内嵌 `WKWebView` 渲染。

**文本路**:`https://www.google.com/search?q=…&gsc=2&cs=1&biw=<w>&bih=<h>`(`cs=1` 深色),同一个 WebView 加载。

**WebView 封装**:`NSViewRepresentable` 包 `WKWebView`,设伪装的 Safari `customUserAgent`;记录 `lastLoadedLink` 去重避免重复加载;处理 `/sorry`(验证码页)避免重载循环;完整实现 navigation delegate 生命周期。

**结果面板**:`NSPopover`(`contentSize≈360×500`,`behavior=.semitransient` 点外部即关),`show(relativeTo: 选区rect, of: 覆盖层视图, preferredEdge:)`;选区在屏幕上半就往下弹、下半就往上弹。深色 UI:面板底 `#101217`、搜索条药丸 `#3F4454`、放 Google logo。

**⚠️ 风险与改进(这是最不耐用的一块):**
- `v3/upload` 是**未公开、逆向**出来的端点,随时可能变;匿名请求(无 cookie、缺 client-hint 头)很容易撞 `/sorry` 验证码。
- 原项目实际调用的上传方法因为**双反斜杠转义 bug** 生成了损坏的 multipart body(`\(boundary)` 和 `\r\n` 变成字面量)——从零写时**正确写 multipart**(单反斜杠插值、真正的 `\r\n`、header 里的 boundary 与 body 里的分隔符必须一致)。
- 从零加:cookie/会话预热、client-hint 头、真正的错误态(别把错误串当搜索词)、以及一个降级方案(如失败回退到 `uploadbyurl` + 图床)。

---

## 8. 微光 & 涟漪(质感层,可后置)

**出现涟漪**:SwiftUI 的 `layerEffect` + `[[stitchable]]` Metal 着色器(`RippleShader`),用 `keyframeAnimator` 在 ~1.2s 内驱动 `time`;着色器按有机正弦波×衰减对采样位置做位移,作用在截图 `Image` 上。

**Google 四色微光**:一个全屏 `MTKView` 叠在上面。fragment shader:
- 画 8 个高斯"光斑"绕屏幕中心公转 + 多谐波"android wiggle"抖动,出现时有 bloom 脉冲;
- 一个 `trackingAmount` uniform 从 0→1,把"全屏光斑"渐变成"只在笔尖的单点辉光";
- `saturation` uniform 控制彩色↔单色(ambient 模式);`opacity` 控制显隐。
- 由一个控制器用**弹簧物理**逐帧驱动 uniform,状态机很干净:`showIdle / startTracking(at) / updateTracking(at) / showAmbient / hide`。

这层纯粹是质感,可以最后做;但那套 `idle→tracking→ambient→hidden` 的状态 API 概念值得借鉴。

---

## 9. 从零做的架构建议(把它的结构缺陷一并修掉)

- **拆掉上帝对象**:原 `CaptureController`(600 行)和 `OverlayView`(1450 行)什么都往里塞。拆成:
  - `SelectionEngine`(纯逻辑、可单测:分词、分行、笔刷命中、圈选 point-in-polygon、handle)
  - `CaptureService` / `LensService` / `ResultPresenter` / `OverlayWindowController`
- **一个 `DisplayContext` 贯穿全流程**,根治多屏 + retina 缩放 bug。
- **补齐缺失**:轻点吸附(文字分词 / 图片物体,见 §6)+ 可调矩形框、翻译(Apple `Translation` 框架 `translationTask`,含整屏/边滚边译)、multisearch(选区 + 追加文字提问)、正经错误态、对纯函数(选择/坐标/解析)写测试。
- **结果呈现**:考虑改成**底部上滑面板**(谷歌就是 bottom sheet,可上滑展开、可拖开以免遮住目标),而不是原项目锚定选区的 popover。
- **部署门槛降到 macOS 14.0**(`Translation` 需 14.4、`SCScreenshotManager` 需 14.0;原项目写死 15.4 没必要)。
- **权限文案**:Info.plist 用正确的 `NSScreenCaptureUsageDescription`;若做条码的联系人/日历 intent,必须加 `NSContactsUsageDescription`/`NSCalendarsUsageDescription`,否则调 `requestAccess` 会崩。

---

## 10. 建议的从零构建顺序(垂直切片优先)

1. **切片 A(打通链路)**:热键 → 抓屏 → 透明覆盖层显示静帧 → 矩形框选 → 裁图 → 文本 OCR → `google.com/search` 塞进 WKWebView 弹窗。证明端到端可行。
2. **切片 B(选择灵魂)**:词级 OCR + 笔刷划词高亮 + 泪滴 handle;把 `DisplayContext` 和坐标换算做对。
3. **切片 C(图搜)**:正确实现 `v3/upload` 直传 + 302 + WebView;加错误态与降级。
4. **切片 D(差异化)**:轻点吸附(文字分词 / 图片物体)、可调矩形框、条码 intent、翻译。
5. **切片 E(质感)**:涟漪 + Google 四色微光。
