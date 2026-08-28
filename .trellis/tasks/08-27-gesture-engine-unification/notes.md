# 决策记录（Stage B，动作层统一）

## 步骤 12：`SystemAccessibilityPermissionRequester.requestAccess` — 选择「接线」而非删除

原状：该方法全仓 0 调用点（死代码），而 `TrackpadClickSuppressor.requestAccessibility()` 与
`TrackpadEdgeScrollSuppressor.requestAccessibility()` 各自内联写了一份
`AXIsProcessTrustedWithOptions(prompt: true)`，`TrackpadActionExecutor.requestAccessibilityIfNeeded()`
与两个 suppressor 的 `apply()` 又各写了一份 `AXIsProcessTrusted()`。

选择接线的理由：删掉 `requestAccess` 只会消除一个符号，5 处重复判定仍在；接线后
Executor + 两个 suppressor 全部经由注入的 `AccessibilityPermissionRequesting`，
`AXIsProcessTrusted*` 在触控板侧归零，并且权限状态第一次可被测试替身控制
（`ActionCatalogTests` 用一个「被调用即 XCTFail」的替身锁定「手势执行不弹权限弹窗」这条既有约束）。

## 步骤 16：动作执行路径本来就是异步的，本次未改代码

`TrackpadGestureService.handle(_:)` 走 `runOnMain`，其在非主线程分支用的是
`DispatchQueue.main.async`——在本任务的基线提交（25a0384）就已是 async。
arch-map C10 记的 3 处 `DispatchQueue.main.sync` 全部在抑制侧，按主会话边界保留：

| 位置 | 保留理由 |
|---|---|
| `TrackpadClickSuppressor.performOnMainSynchronously` | `armTentatively/confirm/cancel` 必须在下一原始帧判定前完成，异步化会让 tap 状态落后于接触序列 |
| `TrackpadClickSuppressor.replay` | 缓冲的 CGEvent 必须与物理事件流保持顺序 |
| `TrackpadEdgeScrollSuppressor.performOnMainSynchronously` | 仅 `stop()` 使用，需确定性拆除 event tap |

C10 描述的「后台线程同步弹模态」实际链路是
Executor `.quickAction` → `QuickActionService.perform` → `confirmLidSleepRisk()` 的 `alert.runModal()`：
它运行在主线程（因为 `runOnMain` 已把执行搬到主线程），不会死锁引擎队列；模态期间主线程阻塞属 UI 行为，
不在本任务范围（子任务 3 的操作中心决定弹窗形态）。已在 `handle(_:)` 上写明这条不变量。

## 步骤 15 附带：删除死结构 `TrackpadRecognition`

Models 中 `TrackpadRecognition`（ruleID/ruleName/action/direction/timestamp）全仓 0 引用，
且正是 Match 瘦身后的目标形状。保留会让下一位读者面对两个同形结构，故随瘦身一并删除。

## 步骤 15 附带：既有测试的机械改写（非断言变更）

`TrackpadGestureMatch` 不再携带整条 rule，`TrackpadGestureTests.swift` 中 10 处
`$0.rule.action.systemControl` 改为 `$0.action.systemControl`。断言的期望值与语义未变，
仅取值路径变化。`TrackpadPowerHelperSafetyTests` 的构造点零改动——
Match 保留了 `init(id:rule:direction:continuousDelta:timestamp:)` 作为唯一的「规则 → 执行意图」投影点。

## 步骤 17：tipTap 5 指规则不做数据迁移

UI 范围收到 2…4，但 `TrackpadGestureTrigger.normalized` 不钳制 tipTap 的 fingerCount，
已保存的 5 指规则原样保留（不改写用户数据），编辑器新增一句说明它不会触发。
手指范围的唯一来源改为识别器自身声明的 `supportedFingerCounts`，View 两处 per-kind switch
（`fingerRange`、`kindBinding` 的钳制）随之删除。

## 旁路发现（未修，留给后续）

- `QuickActionService.runAppleScript` 原来对 `NSAppleScript(source:)` 用了可选链，
  编译失败会被静默当作成功。收敛到 `AppleScriptRunner` 后编译失败会作为
  `.unavailable` 抛出。现有唯一调用点（锁屏）是常量脚本，实际行为不变。
- `AppearanceService` 还有 2 处 `NSAppleScript`（深色模式读写），不属于动作层，未纳入本次收敛。
- `TrackpadGestureSettings.presetRules` 是 `static let`，预设名的本地化在展示层
  （`settingsDisplayName` / `lastRecognitionTitle`）与 `resetPresets` 写入时完成；
  首次安装写入磁盘的仍是英文键。本任务新增测试锁定两份 catalog 都有译文。
