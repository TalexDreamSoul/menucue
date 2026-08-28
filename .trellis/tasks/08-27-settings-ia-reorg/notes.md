# 任务笔记：设置信息架构重组

## Stage A（分区骨架与内容迁移）

### 步骤 1：SettingsPane 全部使用点（重写前基线）

`grep -rn "SettingsPane" Sources/ Tests/`（HEAD = fd5625d 之后的工作树）：

| 位置 | 用途 | 类别 |
|---|---|---|
| StatusPopoverView.swift:616 | `@State private var selectedPane` | 窗口导航状态 |
| StatusPopoverView.swift:630 | `SettingsWindowView.init(initialPane: = .overview)` | **深链入口 + 默认分区** |
| StatusPopoverView.swift:691 | `selectedPaneBinding` | 侧边栏 selection |
| StatusPopoverView.swift:701-705 | `availablePanes` = allCases 过滤 `.iCloud`（未 entitled 时隐藏） | 侧边栏数据源 |
| StatusPopoverView.swift:714-783 | 枚举本体（title / subtitle / systemImage） | 定义 |
| StatusPopoverView.swift:1113 / 1117 | `SettingsContentView.pane` + `selectPane` 闭包 | 路由 |
| StatusPopoverView.swift:1133 / 1638-1651 | `SettingsPaneHeader(pane:)` | 分区标题渲染 |
| OverviewSettingsView.swift:10 | `static let calendarStatusDestination: SettingsPane = .dateAndTime` | **深链常量（有测试断言）** |
| OverviewSettingsView.swift:18/33 | `selectPane` 闭包透传 | 路由 |
| OverviewSettingsView.swift:329 | `selectPane(.quickActions)`（「当前已开启」的 Manage 链接） | 分区内深链 |
| OverviewSettingsView.swift:366 | 检查行 → `.quickActions`（Power Helper） | 分区内深链 |
| OverviewSettingsView.swift:375 | 检查行 → `.iCloud` | 分区内深链 |
| OverviewSettingsView.swift:386 | 检查行 → `.about`（自动更新） | 分区内深链 |
| OverviewSettingsView.swift:423-424 | `OverviewCheckRow.destination` | 深链载体 |
| StatusBarController.swift:723 | `showSettingsWindow(initialPane: = .overview)` | **窗口入口默认值** |
| StatusBarController.swift:204 | 弹窗底栏 ⚙︎ / 右键菜单「设置…」→ `showSettingsWindow()` | 无参深链 |
| StatusBarController.swift:209 | 弹窗操作页「在设置中管理」→ `.quickActions` | **深链** |
| StatusBarController.swift:214 | 弹窗状态卡点击 → `.dashboard` + `dashboardSection` | **深链** |
| Tests/SettingsInformationArchitectureTests.swift:8-33 | 断言 allCases 顺序、`.dateAndTime` 标题/图标、`.language` 标题/图标、`OverviewSettingsView.calendarStatusDestination` | 测试 |
| Tests/NotificationSettingsTests.swift:56-59 | 断言 `.notifications` 存在 + 标题/图标 | 测试 |
| Tests/DashboardTests.swift:33-34 | 断言 `allCases.first == .dashboard` | 测试 |

**持久化结论**：`SettingsPane` 的 rawValue **没有任何持久化写入**。`grep` 未在 SettingsStore.swift / AppSettings / UserDefaults 路径中出现；窗口每次 `showSettingsWindow` 重建视图并用参数决定初始分区（StatusPopoverView.swift:619 的注释也确认这一点）。
→ `migrating(rawValue:)` 因此**只服务于外部/未来的字符串深链**（例如 URL scheme、脚本），不是数据迁移必需。仍按 design.md 提供，集中在一处，并配单测。

### 步骤 2：新旧 pane 映射

| 旧 rawValue | 新归属 | 说明 |
|---|---|---|
| `dashboard` | `.dashboard`（临时保留） | Stage B 步骤 8 改独立窗口后删除该 case，`migrating` 返回 nil |
| `overview` | `.panel` | 概览的两项真设置（页签排序、采样）迁入面板 |
| `dateAndTime` | `.menuBar` | 前半（格式/轮播/显示时区/系统时区）留菜单栏；日历部分单独成 `.calendar` |
| `trackpad` | `.trackpad` | 不变（rawValue 相同） |
| `quickActions` | `.actionCenter` | |
| `notifications` | `.alerts` | |
| `appearance` | `.general` | 外观模式组入通用；动画效果入面板 |
| `iCloud` | `.general` | |
| `language` | `.general` | |
| `about` | `.about` | 瘦身为版本 + 链接 |

新枚举 rawValue：`menuBar` `panel` `calendar` `actionCenter` `trackpad` `alerts` `power` `general` `about`（+ 临时 `dashboard`）。

### 步骤 5：逐项迁移核对清单（对照 research/ui-inventory.md 第二节）

| 旧分区 | 旧分组 / 设置项 | 旧位置 | 新归属 | 状态 |
|---|---|---|---|---|
| 仪表盘 | 7 只读 tab（0 设置项） | DashboardView.swift | `.dashboard`（Stage B 转独立窗口） | 保留 |
| 概览 | 本机信息（只读） | OverviewSettingsView:68-91 | — | **移除（见下「读-only 块处置」）** |
| 概览 | **弹出面板页签**（拖拽排序） | :95-128 | `.panel` → PanelSettingsView.popoverTabsGroup | ✅ |
| 概览 | 最近读数（只读） | :132-169 | — | **移除** |
| 概览 | **采样** 5 控件（isAdaptive + 2 interval + 2 percent） | :175-251 | `.panel` → PanelSettingsView.samplingGroup | ✅ 5/5 |
| 概览 | 当前已开启（只读 chips + Manage 跳转） | :323-342 | — | **移除**（Stage C 操作中心行内状态取代） |
| 概览 | 状态 4 检查行（只读 + 跳转） | :346-389 | — | **移除**（4 个主体各有权威分区） |
| 日期与时间 | 菜单栏格式（Reset/Mode/Cycle/Seconds/Date/Weekday/Order/2×Pattern + 预览） | StatusPopoverView:818-961 | `.menuBar` → MenuBarSettingsView（MenuBarFormatSettingsView 整体搬迁） | ✅ |
| 日期与时间 | 时钟轮播（轮播间隔/排序/标签/增删/加系统时钟） | :1231-1316 | `.menuBar` → clockCarouselSection | ✅ |
| 日期与时间 | 概览显示（显示时区） | :1214-1229 | `.menuBar` → overviewDisplaySection | ✅ |
| 日期与时间 | 日历与日程（周起始/农历/全天/刷新/权限/日历选择） | :1352-1430 | `.calendar` → CalendarSettingsView | ✅ |
| 日期与时间 | macOS 系统时区（搜索/列表/应用/助手） | LanguageRegionSettingsView:192-360 | `.menuBar` → 复用 SystemTimeZoneSettingsView | ✅ |
| 触摸板 | 6 组全局 + 规则编辑器 | TrackpadSettingsView.swift | `.trackpad` | ✅ 整体平移，文件零改动 |
| 快捷操作 | 已固定（计数/上下移/移除） | QuickActionViews:162-234 | `.actionCenter` | ✅ |
| 快捷操作 | 所有操作（磁贴 + 图钉） | :236-274 | `.actionCenter` | ✅（点击即执行的修复属 Stage C） |
| 快捷操作 | 电源助手（安装/移除/取消/刷新/系统设置） | :285-424 | `.power` → PowerSettingsView | ✅ 5 个按钮分支全搬 |
| 通知 | 设备标识 / 4 渠道 / 告警规则 | NotificationSettingsView.swift | `.alerts` | ✅ 整体平移，文件零改动 |
| 外观 | 外观模式 / 参考时区 / 应用到系统 | StatusPopoverView:1318-1350 | `.general` → appearanceSection（新增「外观」组标题） | ✅ 3/3 |
| 外观 | 动画效果 | :2240-2265 | `.panel` → AnimationQualitySettingsView（原地复用） | ✅ |
| iCloud 同步 | 同步开关 + 引导 + 冲突选择 + 重试 | :998-1106 | `.general` → PreferenceSyncSettingsView（**保持 `isEntitled` 条件显示**，从分区级过滤改为组级 if） | ✅ |
| 语言 | 应用语言 + 重启 / macOS 语言跳转 | LanguageRegionSettingsView:117-190 | `.general` → 复用 LanguageSettingsView | ✅ |
| 关于 | 版本（只读） | StatusPopoverView:1434-1439 | `.about` → AboutSettingsView | ✅ |
| 关于 | **登录时启动**（4 状态分支 + 打开登录项设置） | :1443-1478 | `.general` → startupSection | ✅ |
| 关于 | **自动更新**（开关 + 状态 + 手动检查） | :1482-1505 | `.general` → updatesSection | ✅ |
| 关于 | 链接（仓库 / 发行说明） | :1509-1520 | `.about` | ✅ |

**零丢失机械核验**（脚本对比 HEAD 版本的三个源文件 vs 当前 Sources/）：
- 51 个带标签的控件（Toggle/Picker/Stepper/Button/TextField/SecureField/Slider）中 50 个在新代码里仍有调用点；唯一缺席的是 `Button("Manage")`（概览「当前已开启」里的跳转链接，非设置项）。
- 9 个 `AppSettings` 键路径绑定全部存活（allDayEventDatePolicy / appearanceMode / appearanceTimeZoneID / appliesSystemAppearance / calendarSelectionMode / calendarWeekStartDay / overviewTimeZoneID / showsLunarCalendar / statusBarSwitchIntervalSeconds）。
- 30 个 model / service 变更调用全部存活；trailing-closure 形式的 `updateMetricsSampling`（5 处）、`updateSettings`（日历选择）、`removeHelper` 另行 grep 确认。
- 存储键与默认值零改动。

**只读块处置说明**（这 4 块不是设置项，inventory 第四节把「概览」的交互项数记为 6 = 页签排序 1 + 采样 5，与本清单一致）：
- 本机信息、最近读数：与仪表盘/弹窗状态 tab 完全重复，且概览刻意读缓存不采样——权威视图已存在，删除。
- 当前已开启 chips：Stage C 的操作中心行式列表会给每个动作显示开关态与「被引用」，功能上取代它。
- 状态 4 检查行：日历权限 → `.calendar` 分区自带状态与引导；电源助手 → `.power`；iCloud 与自动更新 → `.general`。检查行本身是聚合器，主体各归其位后即为冗余。

### Stage A 其他决策与偏差

1. **`DateTimeSettingsSection` 及其滚动锚点机制删除**。它唯一的深链消费者是概览的日历检查行；日历升为顶层分区后目标就是分区本身，锚点无消费者。导航/深链机制重构本就属子任务 4。
2. **侧边栏 `availablePanes` 过滤删除**。iCloud 不再是分区，entitled 条件下沉到「通用」里的组级 `if`，行为等价。
3. **`.dashboard` 暂留在「系统」组末尾**，枚举里有注释标注 Stage B 删除；`DashboardTests` 相应断言改为「首项 = 菜单栏、末项 = 仪表盘」。
4. **`"User Interface"` 作为「界面」组标题的键**：`"Interface"` 已被 MetricDetailPanel 的网络接口行占用，一个 .strings 键只能有一个译文，故另起键（en 值仍显示 "Interface"）。代码处有注释说明。
5. **`"Trackpad"` 的中文仍是「触摸板」**（PRD 表格写「触控板」）。这是一个跨分区共用的既有译文键，改它会顺带改动触控板分区内的其他文案，超出 Stage A「平移不重写」的范围，留给后续统一处理。
6. **新增 `AppModel.settingsBinding(_:)`**（SettingsWindowViews.swift）取代原先 `SettingsContentView` 私有的 `binding(_:)`，避免在 3 个新分区文件里各抄一份；实现与原来逐字一致（走 `updateSettings`）。
7. `SettingsContentView` 里 `.dateAndTime` 分区顶部那组「Menu Bar & Display」标题被删除——分区标题栏已经说了同一件事。它是标题不是设置项。

## Stage B（行为修复与独立窗口）

### 步骤 6：电源监控显式开关

- `AppModel.enablePowerMonitoring()` → `setPowerMonitoring(enabled:)`（AppModel.swift:337-361）。停启对称：
  | 方向 | PowerDiagnosticsService | ProcessEnergyService |
  |---|---|---|
  | on | `startBackgroundMonitoring()`（注册 wake observer + 一次 backfill） | `startBackgroundSampling()`（建 5 分钟 Timer） |
  | off | `stopBackgroundMonitoring()`（`isBackgroundMonitoringEnabled=false` + `updateWakeObservers()`，引用计数归零即摘 observer） | `stopBackgroundSampling()`（`backgroundTimer.invalidate()` + 置 nil） |
  两个 stop 方法**原本就存在**（PowerDiagnosticsService.swift:107、ProcessEnergyService.swift:66），此前只是没有生产调用者。两者都只操作主线程创建的 Timer / NotificationCenter observer，调用点是 SwiftUI 动作与 `onAppear`，均在主线程。
- **PRD R2 的二选一：选「依赖开关默认值 + 关闭态提示行」，不做首次进入弹窗提示**。理由：默认值 false 不变，已开启用户（`powerMonitoringEnabled.v1` 为 true）在启动时仍由 `StatusBarController.configurePowerMonitoring` 照常启动，完全无感；未开启用户看到提示行，一次点击即开。存储键与默认值零改动。
- 隐式 enable 两处已删：PowerTabView 的 `onAppear`、DashboardPowerSection 的 `onAppear`（后者保留 `diagnostics.retain()`）。
- 提示行放在弹窗电源 tab 顶部（PowerTabView.monitoringNotice）。**偏差（增量）**：仪表盘电源 tab 也加了同一条提示（DashboardPowerSection.monitoringNotice，复用同一本地化键）。仪表盘同样失去了隐式 enable，而「持续运行」卡完全依赖后台采样；没有提示的话它会永久空着且不说明原因。

### 步骤 7：pmset 卡迁入设置

- 迁移内容（PowerTabView → PowerSettingsView，逻辑逐字搬运）：`displayedProfile` / `profileToggle` / `setPowerSetting` / `applyPowerSetting` / `hasMixedValue` / `settingValue` / `common` / `powerModeText` + 电源域 Picker + 「同时应用到电池与电源」确认 Alert。仅表现层改为设置页字号（去掉 `.controlSize(.mini)` 与 9/10pt 字号）。
- 弹窗原位置改为只读摘要：按当前实际电源（`battery.isOnAC`）显示 4 项开关状态 + 功耗模式，helper 未启用时显示 `registrationState.detail`（helper 依赖状态保留），底部「在设置中配置」跳 `.power`。
- 新增导航闭包 `openPowerSettings: () -> Void`，与既有 `openQuickActionSettings` 完全同构（StatusBarController → StatusPopoverView → PowerTabView）。**没有**改动导航闭包机制本身（子任务 4 范围）。
- PowerSettingsView 新增 `diagnostics.retain()/release()`：读 profiles 必须刷新，代价是进入该分区会触发一次 `pmset -g log`（与弹窗电源 tab 打开时的代价相同）。

### 步骤 8：仪表盘独立窗口

- `StatusBarController.showDashboardWindow(section:)` + `makeDashboardWindow`：懒创建、`isReleasedWhenClosed=false`、关闭复用、frame autosave `MenuCueDashboardWindow`、内容尺寸沿用设置窗口的 900×680 与 720×540 最小尺寸。**不带 `.fullSizeContentView`**（设置窗口靠 NavigationSplitView 自带 titlebar inset，仪表盘没有侧栏，带上会让内容钻到标题栏下）。
- SwipeRelay 归属调整：仪表盘窗口用 `SwipeForwardingController` 自持 relay；设置窗口改为普通 `NSHostingController`，`SettingsWindowView` 的 `swipeRelay` / `initialDashboardSection` 两个参数一并删除（relay 在设置窗口里本来就只有 dashboard 一个消费者）。
- `SettingsPane.dashboard` 已删；`migrating(rawValue: "dashboard")` 返回 nil 并注明去向。deep-link 改道证据（`grep -rn "\.dashboard\b" Sources/ Tests/` 只剩 `dashboard-metrics` 队列标签这一无关命中；`grep -rn "SettingsPane\." Sources/` 排除新 9 个 case 后只剩 `SettingsPane.allCases`）。唯一的仪表盘入口是弹窗状态卡 → `openDashboard(DashboardSection)` → `showDashboardWindow(section:)`。
- 双窗共用 activation policy：`windowWillClose` 只在**另一扇窗既不可见也未最小化**时才落回 `.accessory`，否则最小化的那扇会失去 Dock 图标而无法恢复。
- 唤醒历史：设置>电源新增「Wake History」组（保留说明 + 文件占用 + 清除 + 恢复）。**偏差**：清除按钮从弹窗电源 tab 一并迁入（原来只迁「恢复」）。PRD R4 要求「撤销与操作同一归属」，而 R4 同时要求恢复入口落在设置>电源，两者只能都在设置里才成立。仪表盘保留「N 条被隐藏」的说明句（`ClearedHistoryNote.restore` 改为可选，仅隐藏按钮），数据在哪就在哪说明，撤销与操作同处。

### Stage B 旁路发现（未处理，留 Stage C 或后续）

1. 本地化孤儿键：`"Clear local history"`（弹窗垃圾桶按钮的 tooltip）随按钮迁移后失去调用点。Stage C 步骤 12 的废键清理一并处理。
2. 既有重复键（`"System"`×2、`"Add"`×2 等共 10 组）本次未动，同属 Stage C 步骤 12。
3. `configurePowerMonitoring`（StatusBarController.swift:186-192）与 `setPowerMonitoring` 的启动分支逻辑重复。两者语义不同（一个是启动时按持久化值恢复，一个是用户切换），暂不合并；服务生命周期统一属子任务 3/4 的范围。
4. 仪表盘窗口标题与视图内大标题都是「仪表盘」，与设置窗口「MenuCue 设置」+ 分区标题的既有形态一致，未改。

### Stage B 复核（trellis-check）

自修 1 处：`showSettingsWindow` / `showDashboardWindow` 的收尾三行提为 `present(_:)`，并在 `makeKeyAndOrderFront` 前补 `deminiaturize`。`makeKeyAndOrderFront` 不会把最小化的窗口从 Dock 里取回来，所以窗口最小化后再点状态卡（或再开设置），只会给一个仍是 Dock 图标的窗口换掉 contentViewController，点击看上去毫无反应。此前只有设置窗口一扇，问题同样存在但少见；仪表盘作为常驻窗口后，最小化再深链是常规路径。

复核未处理（记录，非缺陷）：

1. 重开窗口时 contentViewController 整体重建，`DashboardView` 的 `@StateObject metrics`（120 点历史）随之清空。这正是 section 深链每次都生效的机制，与 Stage A 设置窗口一致；要两者兼得需把 section 提成外部可观察状态，属子任务 4 的导航状态范围。
2. `powerModeText` 在 PowerTabView 与 PowerSettingsView 各存一份（各自 private，弹窗版仍带 9/10pt 字号）。8 行重复，可在 Stage C 合并为 `PowerMode` 的共享格式化。**Stage C 未做**：两处属电源分区，与本阶段（操作中心/弹窗操作页/触控板可用性）无交集，合并需同时改两个视图的字号约定，留给后续电源相关任务。

## Stage C（操作中心与弹窗操作页）

### 步骤 9：操作中心（设置 > 操作中心）

- **文件拆分**：`QuickActionSettingsView` → 新文件 `ActionCenterView.swift` 的 `ActionCenterSettingsView`（命名与其余分区 `<Pane>SettingsView` 对齐；`SettingsWindowViews.swift:209` 是唯一调用点）。QuickActionViews.swift 只留弹窗侧（网格 + 分组行 + 磁贴），469 → 约 430 行。design.md 表格写「QuickActionViews.swift 内重构」，此处偏差为拆文件，理由与 Stage A 拆 SettingsWindowViews.swift 一致。
- **数据来源**：`ActionCatalog.allItems(shortcuts:)`（新增；`items(surface:)` 改为它的 filter），因此三段来源全部目录驱动：
  | 段 | 来源 | 条目数 |
  |---|---|---|
  | 内置 Built-in | `builtInQuickActions` | 14 |
  | 快捷指令 Shortcuts | `shortcutActions(service.shortcuts)` | 运行时发现 |
  | 触摸板原生 Trackpad Native | `trackpadNativeActions` | 30（7 系统控制 + 12 窗口 + 3 鼠标 + 4 滚动 + 键盘/打开/AppleScript 各 1 + 指针窗口 1） |
  `ActionCatalogItem` 新增 `source: ActionSource`，分段不靠视图猜。分段选择器为「全部/内置/快捷指令/触摸板原生」。
- **点行不执行**：行不是 Button，只有图钉与「运行」两个显式控件；`Empty Trash` 走 confirmationDialog（与弹窗一致）。触控板原生行**不给运行/图钉**——它们只能由手势触发，段落说明一次而不是每行重复。
- **被引用**：`ActionCatalog.references(of:pinned:rules:)` 纯函数，返回 `[ActionReference]`（`.pinned` / `.gestureRule(name:)`）。**签名偏差**：design.md 写 `(item, settings)`，实现改为传 `pinned` + `rules` 两个集合，避免把 `AppSettings` 拖进目录层，且单测无需构造整个 AppSettings。
- **规则 → 目录条目的反查**：新增 `ActionCatalog.itemID(for: TrackpadGestureAction)`，与 `trackpadNativeActions` 的注册共用同一个 id 构造器（原先 id 在注册处硬编码字符串）。`activatesWindowUnderPointer == true` 的规则算作引用 `trackpad:pointerWindow`。
- **单测**（ActionCatalogTests +5）：
  1. `testEveryTrackpadEntryIsFoundAgainFromTheActionARuleStores` — 30 个触控板条目里带 `.trackpad` route 的 29 个 round-trip（注册 id == itemID(for: route 里的 action)），防注册与反查漂移；指针窗口条目走 `.trackpadPointerWindow` route，由第 4 条单测覆盖。
  2. `testAnActionReportsBeingPinnedAndEveryRuleThatSelectsIt` — 固定 + 两条规则引用同一 Quick Action，顺序为 pinned 在前；另一动作被固定时返回空。
  3. `testATrackpadEntryReportsTheRulesThatSelectedIt` — volumeUp 命中、leftHalf 不误命中（防「整段点亮」）。
  4. `testThePointerWindowEntryIsReferencedByTheRulesThatRunItFirst`。
  5. `testEveryBuiltInActionIsInExactlyOneCategory` — 14 项分类无遗漏无重复。
- **性能**：`entries` 每次 body 只算一遍（`catalogGroup` 里 `let entries = self.entries`），触控板可用性走新的批量入口 `availabilities(for:)`（整段一次 `AXIsProcessTrusted`，而不是每行一次）。`ActionCenterSettingsView` **不** `@ObservedObject` TrackpadGestureService——可用性不来自它的 @Published 状态，订阅只会被 30 Hz 的 liveContacts 白白重绘。

### 步骤 10：弹窗操作页

- 顶部固定搜索行（在 PopoverHapticScrollView 之外，不随内容滚走）+ 右侧「编辑」图标按钮 → 操作中心（design.md 画板 E 的「编辑」入口）；底栏「管理操作…」保留，两处同一目的地。
- 已固定网格保留（磁贴仍点击即执行——弹窗是执行面）。其余动作按内置类别 + 快捷指令分组，组头即折叠开关；**快捷指令组默认折叠**，内置三组默认展开；查询非空时**强制展开全部**并隐藏空组，无命中时显示占位句。
- 行内不可用徽标 `ActionUnavailableBadge`（`QuickActionAvailability.reason` 作 tooltip/accessibility；带 settingsURL 时徽标本身就是「打开系统设置」按钮）。不可用行**仍可点**，`service.perform` 会解释原因并跳系统设置——与旧磁贴行为一致，未收紧。
- 内置 14 项分类（`BuiltInQuickActionID.category`，与 implement.md 附录逐项核对一致）：
  - 显示与屏幕（7）：keepScreenOn / turnOffDisplays / screenSaver / darkMode / hideNotch / autoHideMenuBar / hideDesktopIcons
  - 系统操作（5）：lockScreen / lowPowerMode / preventLidSleep / autoHideDock / emptyTrash
  - 清洁（2）：cleanScreen / cleanKeyboard
- `QuickActionTileStyle` 删除：`.catalog` 样式的唯一使用者是旧设置页磁贴，随重构消失，`QuickActionTile` 只剩弹窗紧凑形态（原 `.compact` 数值内联）。

### 步骤 11：承接子任务 2 遗留

a) **可用性数据接 UI**（此前 `executor.availability(for:)` 无生产消费者）：
- `TrackpadGestureService.availability(for:)` / `availabilities(for:)` 转发 executor（不新开单例，走既有服务链路）。
- 规则列表行：动作不可用时显示橙色徽标，tooltip 是原因；有 settingsURL 时徽标即「打开系统设置」按钮。整列表一次权限读取。
- 规则编辑器：新增 `availabilityNotice`（真实可用性 → 橙色原因 + 「打开系统设置」按钮，按钮目标来自 `availability.settingsURL`）。原先 keyboardShortcut/mouse/scroll/window 分支**无条件**显示的「打开系统设置」按钮删除（权限已授予时它是噪音），静态说明文案保留；`.quickAction` 分支原先自己拼的不可用文案与按钮也删除，统一由 notice 承担。
- **执行侧仍未消费 settingsURL**：HUD 只显示 message（TrackpadFeedbackHUD 无按钮）。HUD 是短暂无交互浮层，加按钮属新交互形态，未做。

b) **`failure` 拆分**：`failure(key:)`（本文件写的英文字面量 = 目录键，出口 `L10n.string`）与 `failure(message:)`（下层已成句：AppleScriptRunner / WorkspaceOpener 的 `failure.message`，原样透传，不再二次查表）。调用点归类：14 处 key（无动作/QuickAction 失效/事件创建失败/窗口放置全家族），2 处 message（AppleScript、opened()），2 处转发 `TrackpadBackendResult`（CoreAudio/DisplayServices 的字面量 → key）。`TrackpadBackendResult.failure` 的载荷同步改为 `failure(key:)` 并加注释说明它是键不是系统消息。
- **未拆 `success(_:)`**：同样的含糊在成功路径存在（`success("Sent mouse click.")` 是键，`success(L10n.format("Ran %@.", title))` 是成句，后者被二次查表——查不到即原样返回，行为无害）。步骤 11 只点名 failure，未扩大改动面；如需对称，是一个同形状的小改动。

### 步骤 12：本地化

- 新增 20 键 × 2 语言（`/* Action Center and the popover actions page */` / `/* 操作中心与面板操作页 */` 段）：Built-in / Shortcuts / Trackpad Native / Display & Screen / System Actions / Cleaning / Search actions / Clear search / Collapse group / Expand group / No action matches this search. / Manage Actions… / Source / Run / Run %@ / Run an action with its Run button.… / No actions are registered here yet. / Not used yet / Discovered from Apple Shortcuts on this Mac. / These run from a trackpad gesture rule… （zh 沿用既有「触摸板」译法，不引入「触控板」）。
- **删除 95 行 = 84 个孤儿键 + 11 个重复键**。判定方法（脚本，非人工挑选）：把 `Sources/MenuCue/*.swift` 全文拼接，逐键检查字面量 `"key"` 是否出现；未出现即孤儿。旁证：`Sources/MenuCueHelper` 与 `Sources/MenuCueHelperProtocol` 不引用 L10n/Localizable（grep 为空），Tests 对这 84 键的字面量引用也为空（脚本核对），故删除不会破坏测试或另一 target。动态查表点（`L10n.string(变量)`）的取值全部来自源码内字面量或系统运行时文本（sensor label / metric rawValue / pmset 文本 / helper 消息），与孤儿集无交集。
  - 本阶段新产生的孤儿 5 个（对 eab1616 逐键 `git grep` 核定）：`Manage in Settings`、`Quick Actions…`、`More Actions`、`Every available action is pinned.`、`Click a tile to run it now. Use the pin button to show it in the menu-bar popover.`。（`More Quick Actions` 在 Stage C 之前就已无引用，归入下面两类。）
  - Stage A/B 产生的孤儿：旧分区标题与副标题（Overview / Notifications / Language / Language & Region / Date & Time / Date & Events / Calendars / Calendar access / System Time Zone / Menu Bar & Display 及各自副标题）、`Clear local history`（Stage B 已记录）、`Currently on` / `No toggles are currently on.` / `Last reading` / `No reading cached yet.…` / `Manage`（概览只读块）。
  - 更早的历史死键：`Daily Guide` 整族 21 个（Focus / Rest / Travel / Exercise / Learning / Socializing / Reflection / Planning / Organizing / Communication / Distraction / Procrastination / Avoid / Good for / Hasty decisions / Impulse spending / Overcommitting / Risk-taking / Sitting too long / Staying up late / Forcing outcomes + 说明句）、相对时间族（`Just now` / `%@ ago` / `up %@` / `in the last 30 days`）、`%@ RPM`（AlertMetricProvider.swift:440 现在直接插值 `"\(Int(...)) RPM"`，未本地化——**旁路发现，未修**）、旧快捷操作窗族（`Open Quick Actions Window` / `Open all Quick Actions` / `All Quick Actions…` / `MenuCue Quick Actions` / `Available actions` / `Arguments`）等。
- **重复键 11 组**（不是 10 组）：Action / Add / Alert / Critical / Enabled / Normal / Preview / Rule name / System / Warning / "macOS denied the requested Automation action."。CFPropertyList 对重复键取**最后一个**（已用 Swift 脚本实测确认）。除 `Alert` 外 10 组两处译文相同 → 删后一处、保留字母序正文那条，行为零变化。
  - **`Alert` 是真冲突**：line 75 = 「提醒」（StatusPopoverView:568 日程编辑器的提醒设置），line 681 = 「告警」（NotificationSettingsView:515 的告警状态）。当前生效值是「告警」，故删掉「提醒」那条以保持现状。**遗留问题（未修，需产品决策）**：日程编辑器里那个 Picker 中文显示为「告警」，语义错误；正解是给日程那处换一个独立键（如 `Event Alert` = 「提醒」）。改可见文案超出「废键清理」范围，故只记录。
- spec 漂移：`.trellis/spec/frontend/state-management.md` 的「hide sync pane」改为「hide the iCloud group inside the General pane」。

### 步骤 13：验证

命令结果（全部在最终代码上重跑）：
- `swift build`：Build complete，零 error 零 warning。
- `swift test`：538 XCTest 通过（1 skipped，既有环境跳过）+ 5 swift-testing 通过，0 失败。
- `swift test --filter Localization`：7 通过（LocalizationCoverageTests 3 + LocalizationResourceTests 4）。
- `./scripts/verify-localizations.swift …`：`Verified 1117 localization keys.`（基线 1192 行 − 删 95 行 + 新增 20 键 = 1117；按去重后的唯一键算是 1181 − 84 孤儿 + 20 新键）。

核对清单（**代码路径核验**，非 GUI 实机点击——本会话无法观察 GUI）：

| 项 | 结论 | 证据 |
|---|---|---|
| 设置页无「点击即执行」入口 | ✅ | ActionCenterView 中行体不是 Button；`service.perform` 的调用点只有 `run(_:)`，其唯一触发者是「运行」按钮（destructive 走确认框） |
| 弹窗保留点击执行 | ✅ | PinnedQuickActionGrid / ActionsTabView 磁贴与分组行均为 Button → `service.perform` |
| 操作中心三段可达且目录驱动 | ✅ | `ActionCatalog.allItems` + `source` 分段；`items(surface:)` 改为其 filter，ActionCatalogTests 仍保证 panel 段内容与顺序不变 |
| 被引用徽标 | ✅ | 5 条单测覆盖 pinned / 多规则 / 不误命中 / pointerWindow / 分类完备 |
| 弹窗搜索过滤全部来源 | ✅ | `matching(_:)` 同时作用于已固定网格与全部分组；非空查询强制展开、隐藏空组 |
| 「管理操作…」与「编辑」跳操作中心 | ✅ | 均调 `openSettings` 闭包 → StatusBarController:210 `showSettingsWindow(initialPane: .actionCenter)` |
| 底栏溢出菜单措辞 | ✅ | PopoverComponents.swift:267 「Quick Actions…」→「Manage Actions…」，目标不变 |
| 触控板规则不可用提示 | ✅ | 规则行徽标 + 编辑器 notice，二者都读 `service.availability(...)`；settingsURL 存在时才给按钮 |
| 电源监控开关（Stage B） | ✅ 未回归 | 本阶段未触碰 AppModel/PowerSettingsView |

需人工实机确认（无法在此会话验证）：
1. 弹窗搜索框获得焦点后，左右方向键是编辑光标还是切 tab（`menuCueHorizontalArrowNavigation` 挂在容器上，SwiftUI 应先给焦点 TextField，未实测）。
2. 操作中心「全部」段一次列出 44+ 行（14 内置 + 快捷指令 + 30 触控板原生），滚动长度是否可接受；若过长，分段选择器默认值可改为「内置」。
3. 分段选择器 + 三段标题的中文排版宽度（560pt SettingsGroup 内）。

### Stage C 旁路发现（未处理）

1. `QuickActionService.openRemediation(for:)` 无任何调用点（Stage C 之前就已如此，非本阶段造成）。低电量模式/合盖不休眠不可用时的补救入口现在只有设置 > 电源里的助手安装流程，语义上正确，故未强行给操作中心接回去。
2. `AlertMetricProvider.swift:440` 的 `"\(Int(number.rounded())) RPM"` 未本地化（对应键 `%@ RPM` 已随废键删除）。
3. `TrackpadSettingsView` 里 `Text("Edge")`（区域选择器标签）在两份 catalog 中都没有条目，中文界面会显示英文 "Edge"。属既有缺口，不在本阶段改动面内。
4. `ActionCatalog.trackpadItem` 的 `id: itemID(for: action) ?? action.kind.rawValue` 有一个理论上到不了的兜底分支（只有 `.none`/空 quickAction 才会走到，而那两者从不注册）；round-trip 单测覆盖了真实分支。

