# 触控板手势子系统调研报告（探索 agent：trackpad-deep，2026-08-27）

**核心结论：问题不是「没有抽象」，而是抽象只做到了数据模型层——识别层和运行时层仍是 per-kind 硬编码，且规则匹配逻辑被复制了三份。**

## 一、现有手势功能清单

用户说的「那两个功能」= 4 条预设规则（TrackpadGestureModels.swift:458-505），分属 2 个手势族：

### 功能 A：双指按住 + 指尖点按 → 音量增减（tipTap，2 条预设）
- 触发：TrackpadGestureEngine.swift:229-247 —— 2 指同时落下，1 指抬起（endedIDs.count==1），按落点 x 排序确定 selectedFingerIndex
- 识别：Engine:249-298 —— 抬起指在原位 0.2 半径内重落再抬；锚定指位移 ≤ movementTolerance；heldDuration ≥ holdDuration(0.18)；间隙 ≤ maximumDuration(0.65)；重触时长 ≤ min(0.35, maximumDuration)
- 动作：TrackpadActionExecutor.swift:113-118 —— .volumeUp/.volumeDown → CoreAudio HAL 直接读写，步长硬编码 0.05

### 功能 B：双指沿边缘滑动 → 音量/亮度连续调节（edgeContinuous，2 条预设：左音量右亮度）
- 触发：Engine:331-351 —— 恰好 2 指，起点与当前点都在 edgeWidth 走廊内
- 识别：Engine:362-419 —— 质心增量累加→量化步进，阈值 minimumDistance/sensitivity，冷却 0.055s，单帧最多 3 步，命中首条规则 break
- 动作：Executor:123-133 —— .continuousVolume/.continuousBrightness，步长 abs(delta)*0.025 钳 0.01…0.2
- 副作用：TrackpadGestureService.swift:251-468, 866-1032 —— 独立 TrackpadEdgeScrollSuppressionPolicy + CGEventTap 吞原生滚动，0.3s 惯性排空

### 另外 6 个手势族走第三条路径
completionMatches（Engine:441-526，仅全部手指抬起时评估）：contact（tap/doubleTap/click/forceClick + 3×3 区域）、swipe、edgeEntrySwipe、pinch、fingerSwipe、drawing（$1 unistroke，Engine:678-743）。**无预设规则，用户手动新建才生效。**

测试佐证：TrackpadGestureTests.swift 中 edgeContinuous 出现 11 次、tipTap 约 10 个专门用例；swipe/edgeEntrySwipe/pinch/fingerSwipe 四族**共用一个**测试（:702）。

## 二、识别层结构

### 原始数据源：私有 MultitouchSupport，运行时 dlopen
- MultitouchTrackpadSource.swift:522 dlopen(".../MultitouchSupport", RTLD_LAZY|RTLD_LOCAL)；解析 7 个符号（:527-535）
- contact 记录按 96 字节 stride 拷贝（:56），loadUnaligned 按观测 ABI offset 解码（:438-467）；不符即整帧丢弃
- C 回调全局函数指针（:633-647），MultitouchCallbackRegistry 弱引用表按设备地址路由（:588-631）
- CGEventTap 只用于抑制不用于识别：TrackpadClickSuppressor（Service:472-861，左键）与 TrackpadEdgeScrollSuppressor（Service:866-1032，scrollWheel）

### Engine「半通用」：1 个通用完成态匹配器 + 2 个手写 per-frame 特例
consume() 主循环（Engine:191-204）：consumeTipTap(:192)、consumeContinuousEdges(:199)、consumeCompletedSession(:207)。completionMatches switch 末尾显式排除（:523-524）`case .tipTap, .edgeContinuous: return false`。
三条路径无共同识别器协议；中间态（PendingTipTap、continuousRemainders、continuousLastFire、continuousLastPositions、continuousCancelledRuleIDs）以裸字段塞进共享 Session（:68-86）——新增有状态手势就得再加字段。

## 三、分层与越界

```
MultitouchSupport C 回调 → MultitouchTrackpadSource（干净）
→ engineQueue → TrackpadGestureService（编排 + 规则过滤(重复) + 几何判定(重复) + 2 个 CGEventTap + 诊断发布）
→ TrackpadGestureEngine（会话状态 + 3 条识别路径 + 规则解析 eligibleRules）
→ TrackpadGestureMatch（携带整条 rule）→ Service.handle() → runOnMain
→ TrackpadActionExecutor（9 种动作 + CoreAudio + DisplayServices + AX + HUD 面板）
→ QuickActionService（仅 .quickAction 一条边）
```

越界点：
1. Service 越界做识别几何：TrackpadClickSuppressionPolicy.shouldArm（Service:41-68）与 matchingEdges（Service:430-454）重实现「规则是否适用」，注释自认 mirror（:39-40）
2. Engine 越界做规则解析：design.md:16 设计的 TrackpadRuleResolver **不存在**（全仓 grep 0 命中），内联进 eligibleRules（Engine:550-570）
3. Executor 越界持有 UI：TrackpadFeedbackHUD 完整 NSPanel 住在执行器里（Executor:970-1038）
4. Match 携带整条 rule（Models:615-622），Service.handle() 读 match.rule.activatesWindowUnderPointer（Service:1287）
5. UI 直接读 Service 的 @Published（liveContacts/lastRecognition/两个 suppression status），写配置走 AppModel——双向绑定跨三层

## 四、硬编码/重复证据

### A. 复制粘贴级重复函数
| 函数 | 副本 1 | 副本 2 |
|---|---|---|
| regionMatches | Engine:659-676 | Service:179-196（逐字相同，同 0.33/0.67 魔数）|
| edgeContainsStart/edgeContains | Engine:638-649 | Service:456-467 |
| centroid | Engine:608-614 | Service:170-177 |
| 边缘走廊扩张 min(0.35, width+0.06) | Engine:656 | Service:438 |
| AppleScript 执行 | Executor:277-292 | QuickActionService:717-726（两套错误处理/返回类型）|

### B. 规则过滤谓词三份实现
（isEnabled + applicationScope.matches + requiredModifiers== + deviceScope switch）
- Engine:554-563（eligibleRules，权威，含 specificity 排序）
- Service:52-67（shouldArm，**缺 specificity 排序**）
- Service:439-453（matchingEdges，**缺 specificity 排序**）
后两份缺排序是潜在 bug。

### C. kind switch/if 散落 5 文件 13 处
Models:252-254（edgeContinuous 强制 2 指）；Engine:192,199,207 / :337 / :452-525 / :523-524 / :585-589；Service:209（DispatchPolicy）/ :442-443 / :1301（contact+tap）/ :1438（hasEnabledEdgeContinuousRule 决定装 tap）；View:943-1094（familyFields 150 行）/ :1097-1129（kindBinding+fingerRange）/ :1941-1963, 2058-2071（settingsSummary/Title）

### D. 胖联合体模型
- TrackpadGestureTrigger（Models:188-207）**16 字段**，任一 kind 只用 3-6 个；.swipe 规则照样序列化 drawingTemplate/tapSpacing/pinchDirection
- TrackpadGestureAction（Models:339-350）**10 字段**
- 后果：normalized（:249-264）无差别钳制全部；View binding 每改任意字段跑全量 normalize（View:1206-1217）

### E. 未走配置的魔数
0.2 重触半径(Engine:255)、0.35 重触上限(:288)、0.23/0.4 指间距(:314-316)、0.004 最小步进(:394)、0.055 冷却(:401)、min(3,…)单帧步数(:405)、1/2/2.2/4 click 密度阈值(:475-477)、0.5 双击间隔(:465)、64 重采样(:689)、0.05 音量亮度步长(Executor:114-121)、0.15 触觉限流(:462)、1.6s HUD(:992)、0.18 抑制窗口(Service:473)、0.3 惯性排空(:867)、1/30 诊断节流(:1397)

### F. 死配置
UI 允许 tipTap fingerCount 2…5（View:1125），引擎拒绝 maxContactCount>4（Engine:226）——**5 指 tipTap 永不触发且无提示**。

## 五、「新增一个手势」触点清单

**前提纠正：「四指下滑→锁屏」今天不需要改代码**（.swipe 支持 2-5 指四方向；动作选 .quickAction builtin:lockScreen）。数据模型层抽象成立。

**新增一个手势族（kind）需改 15 处**：Models:108-119 枚举 case → Models:188-247 联合体加参数 → Models:249-264 normalized → Engine:452-525 加 case 或写新 consumeXxx → Engine:68-86 Session 加裸字段 → Engine:191-204 插调用 → Engine:523-524 排除列表 → Engine:581-590 completionDirection → Service:204-211 DispatchPolicy → Service:1436-1440+1124-1129 hasEnabledXxxRule+装配 → Service:251-468 新 SuppressionPolicy（现有各约 200 行）→ View:943-1094 familyFields → View:1097-1129 kindBinding+fingerRange → View:1941-1963,2058-2071 summary/title → 双语 Localizable.strings（LocalizationCoverageTests 强制）。

**新增动作类型 8 处**：Models 枚举→联合体→Executor 主 switch→Executor 新方法→View actionFields→permissionGuidance→settingsSummary→settingsTitle→双语。

## 六、与 QuickAction 的重复度

**「一套主系统 + 一座单向桥」**。桥：Executor:198-208 .quickAction 携带 QuickActionReference.storageValue 反解并调 quickActionService.perform(reference)。

除桥外 Trackpad 有 8 个私有动作 kind，QuickAction 不认识：
| 能力 | QuickActionService | TrackpadActionExecutor | 性质 |
|---|---|---|---|
| 14 内置+Shortcuts | 权威(:147-151,:246-335) | 经桥 | 无重复 |
| AppleScript | :717-726 | :277-292 | **实现重复** |
| 打开 App/URL/文件 | 局部(:217,243,262) | 完整 4 分支(:162-179,294-327) | 部分重复 |
| 键盘快捷键合成 | 无 | :210-228 | 独有 |
| 鼠标点击/滚动 | 无 | :230-275 | 独有 |
| 窗口布局 12 种 | 无 | :181-196,379-445 | 独有 |
| 音量/亮度直控 | 无 | CoreAudio:627-833 + DisplayServices:835-901 | 独有 |
| 指针下窗口激活 | 无 | :347-377 | 独有 |

结构性不一致：结果类型（setFeedback(String)+QuickActionState vs TrackpadActionExecutionResult）；可用性模型（QuickActionAvailability(isAvailable,reason,settingsURL) vs 散落 requestAccessibilityIfNeeded + 硬编码文案无 settingsURL）；锁屏三条路径（quickAction 走 AppleScript keystroke ⌃⌘Q QuickActionService:280-285 / keyboardShortcut 走 CGEvent / appleScript 走 NSAppleScript）权限检查失败文案全不同；反馈通道（popover vs 独立 NSPanel HUD）。

## 七、常驻成本

总开关关闭时零成本（符号仅启用后解析，isEnabled 默认 false）。开启后常开无按需启停（apply 只按总开关 start/stop，Service:1141-1147）。

每帧（60-125Hz，仅有接触时）：copyContacts 有界拷贝 → engineQueue 派发 → **currentContext() 每帧查 CGEventSource.flagsState + NSWorkspace.frontmostApplication 无缓存**（Service:1461-1473）→ edgeScrollSuppressionPolicy.consume 遍历规则 → clickSuppressionPolicy.shouldArm+consume 再遍历 → publishLiveContacts 30Hz（**设置面板开没开都发**，Service:1395-1400）→ engine.consume 三路径各调 eligibleRules。**一帧最多遍历规则表 5 次**（上限 256 条）。ContactHistory.points 每指 256 点，无 drawing 规则也在采（Engine:41）。

click tap 仅 suppressesClickAfterMultiFingerTap 开启时装（默认 false）；scroll tap 只要有启用的 edgeContinuous 就装——**预设自带 2 条 → 默认开启 Trackpad 即装全局 scrollWheel tap**（Service:1126-1129）。

## 八、设计意图 vs 实现偏差

1. design.md:16 的 TrackpadRuleResolver 不存在（grep 0 命中）
2. design.md:79 说 edgeContinuous 是 one-finger；实现强制 2 指（Models:252-254、Engine:337/341），测试把偏差固化成契约（Tests:258）
3. design.md:67 "avoiding 89 hard-coded recognizers"——模型层做到，识别层仍 3 条硬编码路径
4. design.md:97 discrete disarm 部分实现（didEmitDiscrete 只由 consumeTipTap 置位，Engine:297）
5. design.md:81 阈值可调——click/forceClick 密度阈值 1/2/2.2/4 硬编码不可调、无 unavailable 上报
6. PRD R4 "editable presets" 做到了，但预设名未本地化英文字面量（Models:460,473,486,495）
7. prd.md:69 已勾选的验收「实现或有可见的不支持说明」——5 指 tipTap 可配但永不触发，两者都没有

## 抽象设计三条落点

1. **识别器协议 + 注册表**：每个 GestureRecognizer 自带 parameterSchema（驱动 UI 自动生成）、sessionState（不再塞共享 Session）、requiredSuppression（不再手写 hasEnabledXxxRule 特判）、localizationKeys。消掉 13 处分支中至少 10 处。
2. **单一 RuleMatcher**：Engine 与两个 SuppressionPolicy 共用，顺带修复 2 份缺 specificity 排序的潜在 bug。
3. **合并动作层**：Trackpad 9 个 action kind 与 QuickAction 14 内置共用 ActionCatalog + ActionAvailability(isAvailable,reason,settingsURL) + 统一 ActionResult。音量/亮度/窗口/键鼠注册进目录（popover 与快捷键可复用），不再活在 Executor 私有 switch。
