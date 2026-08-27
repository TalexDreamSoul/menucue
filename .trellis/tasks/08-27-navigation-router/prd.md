# 导航层 Router 化

## 背景

见父任务 `research/arch-map.md` 核心问题 1 与 C8：导航状态散落在各 View 的 `@State`（弹窗 selectedTab、设置 selectedPane、requestedDateTimeSection、Dashboard section），没有对象知道「当前在哪」。跨页跳转靠 5 个闭包一路下传（openSettings / openQuickActionSettings / openDashboard / selectPane / selectDateTimeSection）；深链靠 `showSettingsWindow` 重建整个 contentViewController（StatusBarController.swift:648-685），导致设置窗口开着时再触发任何设置入口，用户当前所在分区被重置；设置窗口的 SwipeRelay 每次重建、多数分区无消费者。

## 目标

单一显式导航对象承载全部导航状态与跳转请求；窗口宿主只创建一次内容控制器；任何深链在窗口已开时只改状态不重建视图树。

## Requirements

### R1. AppRouter
- `@MainActor final class AppRouter: ObservableObject`，由 StatusBarController 持有、以 environmentObject 注入弹窗与设置窗口两棵视图树。
- 状态：`popoverTab`、`settingsPane`、`settingsSectionRequest`（分区内锚点，如菜单栏格式/系统时区，替代 requestedDateTimeSection 机制）、`dashboardSection`。
- 方法：`openPopover(tab:)`、`openSettings(pane:section:)`、`openDashboard(section:)`、`showNewEventWindow()`。窗口显隐由 StatusBarController 订阅 router 请求执行（router 不 import AppKit 窗口逻辑，保持可测）。

### R2. 闭包管道退役
- 5 个跳转闭包参数从全部视图链中移除，调用点改 `router.…`；`StatusPopoverView`/`SettingsWindowView`/各 tab 视图的相应 init 参数删除。
- 弹窗 `selectedTab`、设置 `selectedPane` 改绑 router（拖拽排序决定的默认 tab 逻辑保留：popover 打开时若 router 无显式请求则用首个 tab）。

### R3. 窗口宿主稳定化
- `showSettingsWindow`：hosting controller 只创建一次；窗口已开时深链仅更新 router 状态并前置窗口——**用户当前 pane 不再被重置**（有显式 pane 请求时才切换）。
- SwipeRelay：弹窗与设置窗口各一条，创建一次复用；无消费者分区滑动仍静默（行为不变），但 relay 不再每次重建。
- 深链重复触发可靠（原注释声称重建是为深链重复生效——用 router 的请求序列号机制替代）。

### R4. 与前序任务对齐
- 子任务 3 的 `SettingsPane.migrating` 与仪表盘独立窗口调用点全部改走 router。
- 菜单栏右键菜单、弹窗底栏 ⋯ 菜单、状态卡点击、概览检查行等全部入口收敛到 router 方法（实现时 grep 全部 showSettingsWindow/openSettings 调用点列清单）。

## Acceptance Criteria

- [ ] 全仓 grep：五个跳转闭包名不再作为视图参数存在；`showSettingsWindow` 不再重建 contentViewController。
- [ ] 行为验收（代码路径核验 + 手动清单）：设置窗口开着时从弹窗点任意设置入口 → 窗口前置且切到目标分区；无显式目标时保持用户当前分区；深链连续触发两次都生效。
- [ ] AppRouter 单测：状态转换、请求序列号去重、旧值映射路由。
- [ ] `swift build`、`swift test` 全绿；无本地化新增则无本地化变更。

## 范围外

- AppModel 服务定位器拆解与服务生命周期策略化（arch 问题 2/3 的完整解法，规模超本轮，列为后续候选任务）。
- 弹窗 tab 手势切换逻辑（SwipeRecognizer 本身不动）。
