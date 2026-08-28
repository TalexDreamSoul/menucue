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

