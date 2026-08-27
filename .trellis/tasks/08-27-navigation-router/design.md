# 技术设计：导航层 Router 化

## AppRouter

```swift
@MainActor
final class AppRouter: ObservableObject {
  enum WindowRequest: Equatable { case popover(PopoverTab?), settings(SettingsPane?, SettingsSection?), dashboard(DashboardSection?), newEvent }

  @Published var popoverTab: PopoverTab?          // nil = 由排序首项决定
  @Published var settingsPane: SettingsPane = .menuBar
  @Published private(set) var sectionRequest: SectionRequest?   // {pane 内锚点, sequence: Int}
  @Published private(set) var windowRequest: Sequenced<WindowRequest>?  // StatusBarController 订阅执行

  func openSettings(pane: SettingsPane? = nil, section: SettingsSection? = nil)
  func openDashboard(section: DashboardSection? = nil)
  func openPopover(tab: PopoverTab? = nil)
  func openNewEvent()
}
```

- `Sequenced<T> { value: T; sequence: Int }`：同一目标连续两次请求也能被观察到（替代「重建视图树保证深链重复生效」的旧机制；对应 SwipeRelay.Command 既有先例）。
- Router 是纯状态机，不 import AppKit 窗口 API → 可单测。窗口显隐由 StatusBarController `router.$windowRequest.sink` 执行（show/前置/创建窗口）。

## StatusBarController 改造

- 持有 `let router = AppRouter()`；popover 与设置窗口的 hosting controller 懒创建一次（`configurePopover` 现状已是一次，设置窗口改为同样模式），root view 注入 `.environmentObject(router)`。
- `showSettingsWindow(initialPane:)` 退役为 `router.openSettings(pane:)` 的执行端：窗口不存在→创建；存在→`makeKeyAndOrderFront` + 不touch视图树。
- 设置窗口 SwipeRelay 移入窗口宿主一次性创建（dashboard 独立窗口后，设置窗口若无滑动消费者可直接去掉该 relay——实现时确认消费者清单再定）。
- 右键菜单/底栏菜单/⌘, 快捷键等入口全部改调 router。

## 视图接线

- `StatusPopoverView`：`@EnvironmentObject var router`；`selectedTab` @State 保留作本地驱动，但与 `router.popoverTab` 双向同步（onChange 双向、打开时消费 router 值）；跳转闭包参数删除。
- `SettingsWindowView`：`selectedPane` 改直接绑 `router.settingsPane`；`sectionRequest` 由各分区视图 `onReceive` 消费（滚动到锚点/展开分组），替代 requestedDateTimeSection 专用管道。
- 各 tab/分区视图：删除 openSettings 等参数，调用点改 `router.openSettings(...)`。

## 迁移步骤要点

先立 Router 与执行端（新旧并存：旧闭包内部改调 router），再逐视图删参数收网，最后删除旧 API。这样每一步都可编译、行为可对比。

## 风险

- 双向同步（@State ↔ router）在 SwiftUI 更新循环里的回环：用值比较守卫（仅不同才写回）。
- 设置窗口 hosting 复用后，环境值（appearance）更新路径要保留（applyAppearance 现有调用点核对）。
- 深链行为回归面广：验收清单逐条过（arch C8 列出的每个入口）。
