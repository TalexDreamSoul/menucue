# 导航层 Router 化 — 实现笔记

## 步骤 1：导航入口清单（改造前，HEAD=5f5e028）

### 设置窗口
| # | 入口 | 代码路径（改造前） | 目标 pane |
|---|------|-----------------|----------|
| 1 | 菜单栏右键「Settings…」/ ⌘, | `StatusBarController.openSettingsFromMenu` → `showSettingsWindow()` | 无（默认 .menuBar） |
| 2 | 弹窗底栏齿轮按钮 | `PopoverFooter.openSettings` ← `StatusPopoverView.openSettings` ← `configurePopover` 闭包 | 无 |
| 3 | 弹窗底栏 ⋯ 菜单 →「Settings…」 | 同上 | 无 |
| 4 | 弹窗底栏 ⋯ 菜单 →「Manage Actions…」 | `PopoverFooter.openQuickActionSettings` ← `StatusPopoverView.openQuickActionSettings` | `.actionCenter` |
| 5 | Actions tab 搜索栏右侧滑杆按钮 | `ActionsTabView.openSettings` ← `StatusPopoverView.openQuickActionSettings` | `.actionCenter` |
| 6 | Actions tab 底部「Manage Actions…」行 | 同上 | `.actionCenter` |
| 7 | Power tab 电源档位卡「Configure in Settings」 | `PowerTabView.openPowerSettings` ← `StatusPopoverView.openPowerSettings` | `.power` |

### 仪表盘窗口
| # | 入口 | 代码路径（改造前） | 目标 section |
|---|------|-----------------|-------------|
| 8 | Status tab 五张指标卡点击（CPU/内存/磁盘/网络/风扇） | `SystemMetricsCards.link(target)` → `StatusTabView.openDashboard` → `StatusPopoverView.openDashboard` → `showDashboardWindow(section:)` | `DashboardSection(target:)` |
| 9 | 指标悬浮详情面板的展开链接 | `MetricDetailPanel.open`（同 8 的闭包） | 同上 |

### 弹窗内跳转
| # | 入口 | 代码路径（改造前） |
|---|------|-----------------|
| 10 | Status tab「Quick Actions」卡右上「All」 | `StatusTabView.openAllActions` → `StatusPopoverView.select(.actions)` |

### 其他窗口
| # | 入口 | 代码路径（改造前） |
|---|------|-----------------|
| 11 | 菜单栏「New Event…」/ ⌘N | `openNewEventFromMenu` → `showQuickEventWindow()` |
| 12 | 弹窗底栏 ⋯ 菜单「New Event…」 | `StatusPopoverView.openQuickEventEditor()` —— **弹窗内 sheet，不是窗口**，不进 router |
| 13 | 状态项左键 / 菜单「Show/Hide Overview」 | `togglePopover()` —— AppKit 显隐机制，留在 controller |

不属于本任务的同名调用：`WorkspaceOpener.openSettings(_:)`（打开**系统**设置 URL，见 QuickActionService / TrackpadGestureService / ActionCenterView / TrackpadSettingsView）与 `CalendarPermissionAction.openSettings`（同为系统设置）。

改造前 prd 提到的 `selectPane` / `selectDateTimeSection` / `requestedDateTimeSection` 已在子任务 3 消亡，全仓无引用。

## 步骤 7：行为核验清单（代码路径核验）

统一路径：入口 → `router.openX(...)` →（1）router 状态即时变更，视图 onChange/binding 跟随；（2）`Sequenced<Route>` 发布 → `StatusBarController.observeRoutes` → 下一轮 runloop `perform(route)` → 窗口显隐。

| # | 场景 | 路径 | 结果 |
|---|------|------|------|
| 1 | 设置窗口开着，弹窗点「Manage Actions…」 | `router.openSettings(pane:.actionCenter)` → `settingsPane` 变更 → `List(selection:$router.settingsPane)` 立即切换 → `presentSettingsWindow()` 走已存在分支，仅 `present(window)` | 前置 + 切到目标分区，视图树不重建 ✓ |
| 2 | 设置窗口开着，无显式目标（⌘, / 右键菜单 / 底栏齿轮 / 底栏「Settings…」） | `router.openSettings()` → 不写 `settingsPane` → 仅前置 | 保持用户当前分区 ✓（单测 `testOpeningWithoutATargetKeepsTheCurrentState`） |
| 3 | 同一深链连续触发两次 | `sequence` 每次自增 → `$route` 两次都发布 → 两次 `perform` | 两次都生效 ✓（单测 `testRepeatingTheSameRequestIsStillObserved`） |
| 4 | 窗口被最小化时触发深链 | `present()` 内 `deminiaturize` 保留 | 还原 + 前置 ✓ |
| 5 | 首次打开设置（新装/重启后） | `settingsPane` 初值 `.menuBar` | 落在 Menu Bar ✓（`DashboardTests` 断言未变） |
| 6 | Power tab「Configure in Settings」 | `router.openSettings(pane:.power)` | ✓ |
| 7 | Actions tab 滑杆按钮 / 底部「Manage Actions…」 | `router.openSettings(pane:.actionCenter)` | ✓ |
| 8 | 状态卡 / 指标详情面板点击 | `router.openDashboard(section:DashboardSection(target:))` | 仪表盘前置并切到对应 tab ✓ |
| 9 | 仪表盘已开且用户手动切到别的 tab，再点同一张卡 | 视图切 tab 时写回 `router.dashboardSection`，故再次深链是「不同值」→ onChange 生效 | ✓ |
| 10 | 仪表盘关掉再重开 | hosting 一次创建；`@StateObject metrics/dashboard` 存活；`release()` 不清历史 | 120 点历史保留（子任务 1 check 遗留项已解决）✓ |
| 11 | 弹窗「All」跳 Actions tab | `router.openPopover(tab:.actions)` → `popoverTab` → 弹窗 `select()` 动画；`perform(.popover)` → `showPopover()` 因已显示直接 return | 切 tab 有动画，且**不触发** refreshCalendarData/refreshAll ✓ |
| 12 | 菜单栏「New Event…」/ ⌘N | `router.openNewEvent()` → `showQuickEventWindow()`（该窗口仍每次重建以拿到空白草稿，属预期） | ✓ |
| 13 | 底栏 ⋯ 菜单「New Event…」 | 仍是弹窗内 sheet，不经 router | 行为不变 ✓ |
| 14 | 关闭设置窗口（仅 orderOut） | `windowWillClose` → `router.setWindow(.settings, visible:false)` → `VisibilityGate` 停 | 触控板 30Hz 预览与 pmset 轮询确实停 ✓ |
| 15 | 关闭/最小化仪表盘窗口 | 同上 → `dashboard.deactivate()` + `metrics.release()` | 采样停 ✓ |
| 16 | 分区内切换（如从触控板切到日历） | 视图 `onDisappear` → `gate.disconnect()`（active 则 release 一次） | retain/release 仍平衡 ✓ |
| 17 | 外观（浅/深色）在窗口开着时切换 | `refreshClockTitle` 现在经 `AppearanceForwarding` 把外观同时下发到 `SwipeForwardingController` 的 hosting 子视图 | 复用 hosting 后外观仍跟随 ✓（顺带修好弹窗既有同类问题） |

无法在无 UI 测试环境自动化的部分：以上 1/4/5/17 为代码路径核验，未做人工点击。

## 与 design.md 的偏差

1. **`sectionRequest` 未单列**：design 设想 `sectionRequest`（pane 内锚点）独立通道，但其唯一前身 `requestedDateTimeSection` 已在子任务 3 删除，当前没有任何 pane 内锚点消费者。改为把目标塞进 `Route` 的关联值（`.settings(SettingsPane?)` / `.dashboard(DashboardSection?)`），仪表盘 section 作为 router 的一等状态双向同步。重复送达由 `Sequenced` 保证，与 design 的机制一致，只是少一个当前无人消费的枚举。
2. **`WindowRequest` → `Route`**：同时覆盖弹窗内 tab 切换（不涉及窗口），故命名为 Route。
3. **窗口可见性放在 router**：`AppRouter.visibleWindows` + `visibility(of:)`，而非新开一个 `PopoverPresentationState` 式单例——router 已经注入两棵视图树，再加一个单例没有收益。
4. **`StatusSamplingController` 更名 `VisibilityGate`** 并移出 StatusTabView.swift 独立成文件：同一套「可见才干活」机制现在服务弹窗 + 两个窗口，旧名字（Status 特指状态 tab）会误导。保留了 `connect(to: PopoverPresentationState, …)` 便利重载，弹窗调用点与既有测试语义未变。
   - 注意：`.trellis/spec/frontend/state-management.md` 仍写着 `StatusSamplingController.update(isVisible:isStatusSelected:)`（签名本就已过期），需后续同步。
5. **顺带修复（超出步骤 6 字面范围）**：
   - hosting 复用后外观下发路径（见核验 17），不修则复用 hosting 会引入深/浅色不跟随的回归；
   - 窗口最小化也视为不可见（`windowDidMiniaturize/DidDeminiaturize`），否则 Dock 里的仪表盘会一直采样；
   - `presentSettingsWindow` 增补 `model.refreshLaunchAtLoginState()`：General 分区原本靠 `onAppear` 读一次，窗口复用后重开不再触发 onAppear。

## check 轮修正（主会话补记）

- 第 15 条「关闭仪表盘时采样全停」在 check 修复 DashboardPowerSection 之前对 pmset 一路不成立：该分区原为裸 onAppear/onDisappear retain/release，关窗不触发 onDisappear → pmset 轮询泄漏。check 已改为 router.visibility(of: .dashboard) 门控并新增整序列收支回归测试（testWindowScopedWorkBalancesAcrossCloseReopenAndMiniaturize）。
- 实机待确认两条：停在触控板分区关窗重开后 30Hz 预览恢复；停在仪表盘 Power 标签关窗后 pmset 停止。
