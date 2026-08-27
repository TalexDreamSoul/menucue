# 执行清单：导航层 Router 化

1. [ ] 读父任务 research/arch-map.md（C8 与核心问题 1）、design.md；grep 全部导航入口（showSettingsWindow / openSettings / openQuickActionSettings / openDashboard / selectPane / selectDateTimeSection / showDashboardWindow）列清单存任务 notes。
2. [ ] 新建 AppRouter.swift（状态机 + Sequenced 请求 + 单测：状态转换、序列号、popoverTab 默认逻辑）。
3. [ ] StatusBarController 持有 router 并订阅 windowRequest 执行窗口显隐；设置窗口 hosting 一次性创建；旧 showSettingsWindow 内部改调 router（新旧并存，行为等价）。build+test。
4. [ ] StatusPopoverView / SettingsWindowView 接 environmentObject；selectedTab/selectedPane 与 router 同步；sectionRequest 消费替代 requestedDateTimeSection。build+test。
5. [ ] 逐视图删除 5 个跳转闭包参数，调用点改 router（按步骤 1 清单收网）；删除旧 showSettingsWindow 公开入口与冗余 SwipeRelay 重建。
6. [ ] 窗口关闭生命周期：设置窗口 `isReleasedWhenClosed=false` 导致关闭仅 orderOut、SwiftUI `onDisappear` 未必触发（触控板 30Hz 预览门控、指标 retain/release 同受影响；来源：子任务 1 check 遗留）。在窗口宿主 `windowWillClose` 统一挂点通知视图树拆除订阅。
7. [ ] 行为核验清单（写入任务 notes）：窗口开着时深链切分区不重置、无目标深链保持当前分区、深链连续两次生效、⌘, / 右键菜单 / 底栏 / 状态卡 / 检查行全部入口正常。
8. [ ] 全量 `swift build && swift test`；grep 验收（闭包参数清零、contentViewController 重建点消失）。

## 验证命令

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -40
grep -rn "openQuickActionSettings\|selectDateTimeSection\|requestedDateTimeSection" Sources/
```

## 回滚点

步骤 3 后新旧并存可安全停留；步骤 5 是不可逆收网，前置全部核验通过再做。

## 禁止

- 不改 SwipeRecognizer 判定逻辑。
- 不顺手拆 AppModel（后续任务）。不 git commit。
