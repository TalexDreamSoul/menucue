# 技术设计：设置信息架构重组

## 核心改动面

| 文件 | 变化 |
|---|---|
| StatusPopoverView.swift | `SettingsPane` 枚举重写（9 case + 分组元数据 + 旧值映射）；`SettingsWindowView` 侧边栏按组渲染；`SettingsContentView` 路由更新；外观/iCloud/关于内容重分配。**顺势拆文件**：设置窗口相关类型移入新文件 SettingsWindowViews.swift（降低 2488 行单文件，弹窗部分留原文件） |
| 新 MenuBarSettingsView.swift | 菜单栏分区（格式+轮播+显示时区+系统时区，内容从现有视图平移组装） |
| 新 PanelSettingsView.swift | 面板分区（页签排序+采样+动画效果） |
| 新 CalendarSettingsView.swift | 日历分区 |
| 新 PowerSettingsView.swift | 电源分区（pmset 卡迁入 + 助手管理迁入 + 监控开关 + 唤醒历史保留/恢复） |
| 新 GeneralSettingsView.swift | 通用分区（启动/更新/外观/语言/iCloud 组装） |
| QuickActionViews.swift | 操作中心重构（来源分段 + 行式列表 + 显式运行按钮 + 被引用徽标 + 图钉）；弹窗操作页重组（搜索/分组/折叠/管理入口） |
| PowerTabView.swift | 电源配置卡 → 状态摘要 + 设置跳转 |
| StatusBarController.swift | showDashboardWindow()（独立窗口，承载现 DashboardView）；showSettingsWindow 的 initialPane 类型随新枚举 |
| AppModel.swift | enablePowerMonitoring 改为显式 setPowerMonitoring(enabled:)；onAppear 隐式调用点移除 |
| OverviewSettingsView.swift | 拆解后删除（内容分流到 面板/电源/通用/各自权威页） |
| Resources/*/Localizable.strings | 新分区/分组键，废弃键清理 |

## SettingsPane 新枚举

```swift
enum SettingsPane: String, CaseIterable {
  case menuBar, panel, calendar, actionCenter   // 界面
  case trackpad, alerts                          // 输入
  case power, general, about                     // 系统

  static func migrating(rawValue: String) -> SettingsPane? {
    switch rawValue {
    case "dashboard": return nil        // 仪表盘 → 独立窗口，调用方改走 showDashboardWindow
    case "overview": return .panel
    case "dateTime": return .menuBar
    case "quickActions": return .actionCenter
    case "notifications": return .alerts
    case "appearance", "language", "sync", "about旧值按实际 rawValue": return .general/.about
    default: return SettingsPane(rawValue: rawValue)
    }
  }
  var group: SettingsGroup { ... }  // 界面/输入/系统
}
```
实际旧 rawValue 以代码为准（实现时先 grep `SettingsPane` 全部用点与持久化/深链），映射函数集中一处。

## 操作中心「被引用」计算

```swift
struct ActionReference { case pinned; case gestureRule(name: String) }
func references(of item: ActionCatalogItem, settings: AppSettings) -> [ActionReference]
// pinned: settings.pinnedQuickActionIDs 包含
// gestureRule: settings.trackpadGestureSettings.rules 中 action.kind == .quickAction 且 reference.storageValue == item.id
```
纯函数 + 单测。ActionCatalog 数据层来自子任务 2；若其未含 trackpad surface（回退场景），操作中心只显示内置+快捷指令两段。

## 弹窗操作页结构

```
VStack
├─ SearchField(@State query) + 「编辑」→ router/闭包 跳操作中心
├─ PinnedQuickActionGrid（保留现组件）
├─ ForEach(分组)：DisclosureGroup(内置类别…, 快捷指令默认收起)
│    └─ ActionRow：图标盒 + 标题 + spacer + 状态点/运行按钮/不可用徽标
└─ 底栏「管理操作…」
```
内置动作类别：在 QuickAction 目录项上加 `category`（显示与屏幕/系统/清洁与维护——按现 14 项划分，划分表写在实现清单）。搜索过滤对全部组生效，非空查询时强制展开。

## 仪表盘独立窗口

- StatusBarController 新增 dashboardWindow 懒创建（NSWindow + NSHostingController(DashboardView)，风格对齐现设置窗口；关闭即隐藏复用）。
- DashboardView 的 SwipeRelay 由该窗口自持（解决原设置窗口 relay 只有 dashboard 消费的怪状）。
- 原「设置>仪表盘」侧边栏项删除；deep-link 调用点（StatusTabView 卡片点击、概览检查行）改 showDashboardWindow。

## 电源监控开关语义

- `settings.powerMonitoringEnabled` 保持既有存储键；默认值不变（已开启用户无感）。
- 移除 PowerTabView.swift:40 / DashboardPowerSection.swift:22-27 的 onAppear 隐式 enable；改为：开关关闭时，弹窗电源 tab 顶部显示一条「电源监控已关闭 → 打开」提示行（一次点击显式开启）。
- AppModel: `setPowerMonitoring(enabled:)` 统一入口，false 时停止 powerDiagnosticsService/processEnergyService 后台任务（复用现有 stop 路径；确认两个 service 有对称 stop）。

## 风险

- StatusPopoverView 拆文件 + 枚举重写是本任务最大 churn；靠编译器穷举 + 全量 grep 深链调用点收网。
- 迁移映射漏项 → 验收标准 R1 的逐项核对清单兜底。
- 弹窗电源 tab 改动与子任务 1 已改文件（同文件不同区域）存在合并顺序要求：本任务在 1 提交之后进行，无并行冲突。
