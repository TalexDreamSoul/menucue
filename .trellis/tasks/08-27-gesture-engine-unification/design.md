# 技术设计：触控板手势引擎统一抽象

目标分层（对应 design/menucue-redesign.pen 画板 F）：

```
MultitouchTrackpadSource（不动）
  → TrackpadGestureService（编排：源生命周期 / 抑制 tap 装配 / 分发。不再含识别几何与规则谓词）
  → TrackpadGestureEngine（会话编排：遍历识别器注册表，不再含 per-kind 路径）
      ├─ TrackpadRuleMatcher（唯一的规则过滤+specificity 排序）
      ├─ TrackpadGeometry（唯一的几何工具：region/edge/centroid/走廊扩张）
      └─ [TrackpadGestureRecognizer]（每族一个，自带状态与抑制需求声明）
  → TrackpadGestureMatch（瘦身：执行意图，不带整条 rule）
  → TrackpadActionExecutor（分发器；执行体逐步下沉到共享实现）
      └─ ActionCatalog / AppleScriptRunner / WorkspaceOpener（与 QuickActionService 共用）
```

## 新文件

| 文件 | 内容 |
|---|---|
| TrackpadRuleMatcher.swift | `TrackpadRuleMatcher.eligible(rules:context:)`（isEnabled + applicationScope + requiredModifiers + deviceScope + specificity 排序）；`RuleContext`（bundleID / modifiers / deviceKind / kind 过滤）。`TrackpadGeometry`（regionMatches、edgeContains、edgeContainsStart、centroid、corridorWidth(edgeWidth) = min(0.35, width+0.06)）。 |
| TrackpadGestureRecognizers.swift | `TrackpadGestureRecognizing` 协议 + 注册表 + 8 个识别器实现（从 Engine 平移逻辑，不改阈值与判定顺序）。 |
| TrackpadFeedbackHUD.swift | 从 Executor:970-1038 整体搬出，接口不变。 |
| ActionCatalog.swift | `ActionCatalogItem { id, title(本地化键), icon, surfaces:[panel/trackpad], availability provider, executor 路由 }`；builtin 14 从 QuickActionService.catalogItems 映射，Shortcuts 动态项保持现有发现机制，触控板原生动作（volume/brightness/window/keyMouse/pointerWindow）登记为 trackpad surface。 |
| AppleScriptRunner.swift（或并入 ActionCatalog.swift） | 单一 AppleScript 执行 + 统一错误映射；QuickActionService.runAppleScript 与 Executor.performAppleScript 均改调它。 |

## 识别器协议（关键契约）

Stage A 已落地的实际契约（`TrackpadGestureRecognizers.swift`）：

```swift
protocol TrackpadGestureRecognizer: AnyObject {
  static var kind: TrackpadGestureKind { get }
  /// 该族启用规则存在时需要的输入抑制（Service 据此装配 CGEventTap）。
  static var suppression: TrackpadInputSuppressionNeed { get }  // .none / .scrollWheel / .optInLeftClick

  /// 该族的会话状态盒（引用类型，避免每帧装箱）；完成态族返回 nil。
  func makeSessionState() -> TrackpadRecognizerSessionState?
  /// 每帧调用；有状态族（tipTap / edgeContinuous）在此消费。state 从 input.state 取。
  func consume(_ input: TrackpadRecognizerInput) -> [TrackpadRecognizedGesture]
  /// 会话结束（全部手指抬起）后**按规则**调用；Engine 保持规则主序遍历，
  /// 所以命中由 specificity 决定，而不是注册顺序。默认实现返回 false —— 这就是
  /// 原 `case .tipTap, .edgeContinuous: return false` 的替代。
  func matchesCompletedSession(rule: TrackpadGestureRule, input: TrackpadRecognizerInput) -> Bool
  func completionDirection(for rule: TrackpadGestureRule) -> TrackpadDirection?
  /// 跨会话状态（doubleTap 的首次 tap）随 Engine.reset 清理。
  func reset(deviceID: UInt64?)
}
```

与初版设计的两处偏差（实现时确定）：
1. 完成态钩子是**按规则**的 `matchesCompletedSession(rule:input:)`，不是按族的 `sessionEnded(...) -> [Match]`。原因：`consumeCompletedSession` 是**规则主序**遍历（specificity 排序后取首个命中）；若改成族主序，跨 kind 竞争时胜者会变（行为漂移）。
2. `state` 用引用类型状态盒 + `input.state`，不是 `inout RecognizerState?`。原因：`PendingTipTap` 远超 3 字，存进 `Any` 会每帧堆分配。

- Engine.consume 顺序遍历注册表（注册顺序固定为现状评估顺序：tipTap → edgeContinuous → 完成态族），保持首个命中/break 语义与 `didEmitDiscrete`、`emittedRuleIDs` 现有约束。
- `TrackpadSessionSnapshot` 暴露 Session 的只读几何/时序数据（含 `orderedHistories`、`duration`）；各族可变状态在自己的状态盒内（`PendingTipTap`、continuous 系列字段已迁入）。
- `eligibleRules` 每帧只算一次，供全部族共享（原来一帧算 3 次）。
- ContactHistory 轨迹采集保持现状（本任务不做按需采集优化，避免与 drawing 行为纠缠）。

## Service 改造

- 两个 SuppressionPolicy 保留结构，但谓词与几何全部改调 TrackpadRuleMatcher/TrackpadGeometry（删除 Service:41-68 / :170-196 / :430-467 的本地副本）。**补 specificity 排序 = 声明的 bug 修复。**
- tap 装配条件：`TrackpadRecognizerRegistry.suppressionNeeds(for: enabledRules)` 替代 `hasEnabledEdgeContinuousRule`（Service:1436-1440 删除）。
- `currentContext()` 使用子任务 1 已落地的 frontmost 缓存。
- 动作分发：`handle(match:)` 的 main.sync → main.async（执行不需要返回值）；tap 回调内需要同步判定的路径不动。

## Match 瘦身

```swift
struct TrackpadGestureMatch {
  let ruleID: UUID
  let ruleName: String            // HUD 展示
  let action: TrackpadGestureAction
  let activatesWindowUnderPointer: Bool
  let feedback: TrackpadFeedbackOptions   // 触觉/HUD 开关
}
```
Service.handle 不再读 `match.rule.*`（Service:1287 改由字段直取）。

## ActionCatalog（本任务只建数据层）

- QuickActionService.catalogItems 改由 ActionCatalog 生成（panel surface 过滤后与现状清单一致——用测试锁定）。
- Executor 的 `.quickAction` 桥不变；触控板原生 kind 的执行体仍在 Executor，但登记进目录并暴露统一 `ActionAvailability(isAvailable, reason, settingsURL)`。
- popover/设置 UI 本任务零变化。

## 风险与兼容

- 最大风险：识别行为漂移。对策：识别器实现是**平移**不是重写；`TrackpadGestureTests` 不改断言全绿为硬门槛；specificity 修复的影响面用新增测试显式覆盖。
- 序列化兼容：TrackpadGestureTrigger/Action 的 16/10 字段联合体**本任务不动**（胖模型瘦身留待后续，避免磁盘格式迁移与 UI binding 大改叠加）。
- 预设名本地化只影响新写入（重置预设/首次启用），已存规则不迁移。

## 「新增一个手势族」触点（改造后目标 ≤6）

1. Models：kind 枚举 + 该族参数（联合体暂存）
2. 新识别器类型（自带状态与抑制需求）+ 注册表登记一行
3. View familyFields 分支
4. View summary/title 文案
5. en/zh-Hans 本地化键
6. 单测

（对照现状 15 处：Engine 4 处、Service 4 处消失。）

Stage A 后实测（`grep "case \.<kind>\|kind == \.<kind>"` 逐文件计数）：

| 文件 | per-kind 分支数 | 说明 |
|---|---|---|
| TrackpadGestureEngine.swift | **0** | 只剩 `recognizersByKind[trigger.kind]` 一次注册表查表 |
| TrackpadGestureService.swift | 3 | 全在两个 SuppressionPolicy 自己的镜像谓词 + `isConfirmedContactTap` 内；新增 `.none` 抑制的手势族**不需要动** |
| TrackpadGestureRecognizers.swift | 2 | 各族在自己的识别器里过滤自己的规则 |
| TrackpadGestureModels.swift | 1 | edgeContinuous 强制 2 指的 `normalized` 钳制（触点 1） |
| TrackpadSettingsView.swift | 34 | 触点 3/4，子任务 3 的 UI 重排范围 |

新增一族的实际触点 = Models 1 + 识别器/注册表 1 + View familyFields 1 + View summary/title 1 + 双语 1 + 单测 1 = **6**（Engine / Service 均为 0）。
