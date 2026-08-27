# 性能热修：1Hz 时钟路径

## 背景

实测采样（见 `research/perf-audit.md`）：持续 CPU 1.05%，74% 活跃 CPU 在菜单栏时钟的 1 秒定时器路径；内存 120MB 中 37% 是堆碎片，来自该路径每秒制造短命对象。指标采样服务门控正确，无需改动。

## 目标

在不改变任何可见行为的前提下，消除 1Hz 路径的重复计算与分配，并顺手处理触控板帧路径的两处无谓开销和一个无界存储缺陷。目标：持续 CPU 降到 ~0.4%。

## Requirements

### R1. 日期胶囊缓存（最大头，17% + 触发的大部分重绘）
- `StatusBarController.dateCapsuleString`（:373-425）按 (胶囊文本, 深浅色, 相关样式输入) 缓存生成的 NSAttributedString/NSImage；命中时零绘制。
- 外观变化、设置变化（menuBarFormat 等）必须使缓存失效。
- `NSFont.monospacedDigitSystemFont` 等字体查找提为 static。

### R2. Appearance 脏检查（16% + 每秒 WindowServer IPC）
- `AppearanceService.apply`（AppearanceService.swift:9,27-38）记录上次已应用值（含 nil），相同直接 return。
- `AppModel.refreshTimeDrivenState`（:488-490）每秒调用路径保持不变——由 service 层脏检查兜底。
- StatusBarController 定时器内每秒给 3 个 VC 赋 `.appearance` 与重设 `interactionView.frame`（:265-267,281）同样加变更判断。

### R3. 时钟渲染微修
- `AppModels.countryCode(for:)`（:790,793,835）两个函数内联字典 → `static let`。
- `MenuBarClockRenderer`（:73-74）仅在 timeZone 实际变化时给 formatter 赋值，避免每秒重建 ICU formatter。
- `applyStatusTitle`（:314-339）当新标题与当前一致时跳过 `setAttributedTitle`（无秒格式时完全静默）。

### R4. 触控板帧路径减负
- `TrackpadGestureService.currentContext()`（:1461-1473）：frontmostApplication 改为缓存值，用 `NSWorkspace.didActivateApplicationNotification` 失效；`flagsState` 保留每帧读取（正确性需要）。
- `publishLiveContacts`（:1395-1400）：仅在触控板设置页可见（有订阅者）时发布；由 TrackpadSettingsView onAppear/onDisappear 显式开关。

### R5. 通知运行时存储保留策略（潜在 O(n²)/无界）
- `NotificationRuntimeStore.events`（:221-235）：append 后按上限裁剪（保留最新 1000 条），并消除每次 append 的全量 sort（追加有序或仅乱序时排序）。
- 现有磁盘格式向后兼容：超限旧文件加载后首次 commit 即被裁剪。

### R6. 顺手项（低风险）
- `OverviewSettingsView.swift:57` 的 `Timer.publish(...).autoconnect()` 移出 body，避免每次求值重建。

## Acceptance Criteria

- [ ] `swift build` 与 `swift test` 全绿。
- [ ] 菜单栏渲染结果与修改前一致（同输入同输出；缓存键覆盖全部渲染输入）。
- [ ] 新增测试：NotificationRuntimeStore 保留策略（上限裁剪 + 顺序保持）；缓存键失效逻辑（若抽成可测纯类型）。
- [ ] 深浅色切换、时钟格式修改、时区增删后菜单栏立即正确刷新（实现者自查 + check 复核代码路径）。
- [ ] 无新增第三方依赖，无行为开关变化。

## 范围外

- 指标采样架构（门控已正确）。
- 触控板识别逻辑（归子任务 2）。
- pmset/top 子进程采样频率调整。
