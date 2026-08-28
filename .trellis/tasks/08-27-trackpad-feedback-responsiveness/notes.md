# 实现笔记

## R1 需求中途修订：从"删除 HUD"改为"固定屏底"

第一版按初版 PRD 把 HUD 整条链路删了（含 `TrackpadFeedbackHUD.swift`、`TrackpadFeedbackPolicy`、
`feedbackHUDEnabled` 字段/开关/本地化键、以及一条证明旧 JSON 未知键可忽略的解码测试）。
用户第二条消息澄清"不是不要浮层，是不要跟随鼠标"后，上述删除**已全部还原**（从 HEAD 取回两个文件，
其余按原样重建），当前分支相对 HEAD 在 R1 上只有以下净变更：

- `TrackpadFeedbackHUDLayout`（新增，与面板同文件）：纯函数 `origin(panelSize:in:)`，在给定
  `visibleFrame` 内做底部居中，抬高 `bottomInset = 96`（系统音量 bezel 所在高度带）。
  `visibleFrame` 本身已排除菜单栏与 Dock，所以三种 Dock 位置不需要分支；面板放不下时钳到近侧
  边角而不是居中溢出屏幕。
- `TrackpadFeedbackHUD.position(_:)`：`NSEvent.mouseLocation` **只用于选屏**（命中失败回退
  `NSScreen.main`，旧实现是直接 return、可能留在上一次的位置），面板原点完全来自该屏 `visibleFrame`。
  每次 `show` 重算，Dock 移动/拔插显示器无需额外失效逻辑。
- 文案：`"Volume %d%%."` → `"Volume %d%%"`，`"Brightness %d%%."` → `"Brightness %d%%"`，
  `"Muted output."` → `"Muted output"`（en/zh 同步，键名随值一起改）。
- 新增 `TrackpadFeedbackHUDLayoutTests`（4 例）：Dock 底/左/右三种 `visibleFrame` 形态、
  副屏在主屏左侧（负坐标）与上方（y 偏移）、同屏两次调用结果一致、面板超宽/屏幕过矮时的钳制。

被还原的那条 `testLegacyExportCarryingTheRemovedFeedbackOverlayFlagStillImports` 已删除：字段
既然保留，"未知键被忽略"的前提不复存在，留着会误导。

### 偏差：句号一次去了三处
PRD 只点名「音量 34%。」，但 `Muted output.` 与 `Brightness %d%%.` 是同一个读数在同一块面板里的
另外两种取值。只改一个会让同一浮层出现"有的带句号有的不带"，因此三处一起去。

## R2 声明的行为变更：tipTap 按住连发

### 旧语义
- `TrackpadTipTapRecognizer.consume` 开头 `guard !session.didEmitDiscrete`：会话内一旦发射过离散手势，本族此后全程静默。
- 候选规则过滤含 `!session.emittedRuleIDs.contains($0.id)`：同一条规则一个会话内只能命中一次。
- 判定成功后 `defer { state.pending = nil }`：pending 被清空且不再重建，锚指仍按住时第二次点按无从武装。

### 新语义
- 移除上述两处限制；判定完成时立刻用**同一锚指集合**重建 pending（`initialPosition` 取本次重触的 `history.start`，`gapBeganAt` 与 `heldDuration` 按当前帧重算，`initialTravel` 归零见下）。重建发生在成败判定之前，因此被防抖丢弃或不匹配的一次点按也不会卡死会话。
- 新增 `repeatCooldown = 0.12s`：相邻两次**发射**间隔小于该值时丢弃本次点按，且不刷新 `lastEmittedAt`（会话状态 `SessionState.lastEmittedAt`）。
- 仍返回 `isDiscrete: true`：引擎照旧置位 `didEmitDiscrete`，完成型手势族（contact/swipe/pinch/…）在抬手时依然不会被 tipTap 会话额外触发——**其他族的一次性语义未动**。
- 会话内其余约束（movementTolerance、recontactRadius 0.2、maximumRecontactDuration 0.35、holdDuration、maximumDuration）全部保持。

### 断言变更清单

既有断言**没有一条失效**：全部 tipTap 测试原本只喂了一次点按，"一次点按 → 一次动作"在新语义下依旧成立（改动前后 `--filter Trackpad` 均 0 失败）。只做了两处**测试命名**修正，避免名字继续宣称已废弃的契约：

| 项 | 旧 | 新 | 说明 |
|---|---|---|---|
| 测试名 | `testHeldRightAndCompletedLeftRecontactEmitsVolumeUpExactlyOnce` | `…EmitsVolumeUpOncePerTap` | 断言体一字未改；"每会话一次" → "每次点按一次" |
| 测试名 | `testHeldLeftAndCompletedRightRecontactEmitsVolumeDownExactlyOnce` | `…EmitsVolumeDownOncePerTap` | 同上 |

新增三条测试（`TrackpadGestureEngineTests`）：
- `testHeldAnchorTakesEveryTapWithoutLiftingTheWholeHand`：锚指不抬，连点 3 次 → 恰好 3 次 volumeUp。
- `testTapsInsideTheRepeatCooldownAreDebouncedWithoutDisarmingTheSession`：3 次点按，第 2 次落在冷却内被丢弃，第 3 次照常发射（断言发射时间戳为 `[0.32, 0.60]`）。
- `testLiftingTheWholeHandAndPressingAgainStillRecognizesATipTap`：全部抬手重按仍正常。

### 复核修正：重建 pending 的 `initialTravel` 归零

复核（trellis-check）发现并已修：重建时原本写 `initialTravel: history.maxTravel`，把**刚结束那次点按**的位移带进了下一次点按的判定。该位移在本次点按评估时已由 `history.maxTravel <= movementTolerance` 检过一遍，带到下一轮即同一约束被应用两次——后果是**一次抹动的点按会连带吞掉紧随其后的干净点按**（实测：第 2 次点按位移 0.06 > 容差 0.035 时，第 3 次完全干净的点按也不发射）。

首次武装（`state.pending == nil` 那条路径）的 `initialTravel` **保持不变**：那里量的是手指静置期间的漂移，除此之外无人检查，是真实约束。重建路径改为 `initialTravel: 0`；锚指是否走动仍由每轮重算的 `anchorsStayedStill` 兜底，无覆盖缺口。

新增回归测试 `testATapThatDriftsTooFarDoesNotDisqualifyTheTapAfterIt`：三次点按中间那次抹动 0.06，断言发射时间戳为 `[0.32, 0.76]`（只丢抹动的那一次）。

### 已知的语义边界（非回归）
重建的 pending 锁定在**首个抬起的手指**上。锚指未全部抬起时无法中途换成另一根手指连发（换手指仍需全部抬手重来）。改动前该场景同样不成立（`didEmitDiscrete` 已让整个会话静默），故不是回归。

## R3 断言变更

`testContinuousEdgeCancelsWhenEitherFingerLeavesCorridorAndRateLimitsTwoFingerCentroidSteps`
中 `afterCooldown` 的期望由 `[3]` 改为 `[4]`（附带文案 "capped to three steps" → "four steps"），这是单帧步数上限 3→4 的直接结果。同一测试的"冷却期内不发射"用例在 0.055→0.035 后仍然成立（该帧间隔 0.02s，仍短于新冷却），未改。

## 偏差与旁路发现

1. **`TrackpadActionExecutionResult.settingsURL` 仍然无人读取。** `message` 由浮层消费、`isFailure` 由触觉与浮层配色消费，只有 `settingsURL`（失败时"去哪儿授权"的落点）构造了却从未被读——浮层是无交互的短暂面板，没有放按钮的地方。这条在 08-27-settings-ia-reorg 的笔记里已被记过一次，本次仍未处理：给浮层加可点按钮属于新交互形态，超出"改位置"的范围。

2. **R4 的"所有族只在参数非默认时展示"按字面执行会伤害可读性。** 徽标里出现的参数中，只有 tipTap 的 `tapSpacing` 属于"容差/调参"；其余（contact 的 contactGesture、swipe/fingerSwipe 的 direction、pinch 的 pinchDirection、edge 的 edge、drawing 的 activation）是该族**触发器身份**的一部分。若一并隐藏默认值，"3 指向上轻扫"会退化成"3 指"，兄弟规则将无法区分。因此实现为：tipTap 的 spacing 仅在非 `.normal` 时展示（今天这条规则的唯一落点），其余族照旧。

3. **`settingsSummary`（行内 `.help()` 提示）里的边缘文案仍然别扭，未动。** zh 模板自带"边缘"二字（`"%d-finger continuous %@ edge" = "%d 指%@边缘连续手势"`），传入 `settingsTitle` 的"向左"会拼出"2 指向左边缘连续手势"。R4 只点名了表格徽标，改提示需要同时改 en/zh 的格式串语义，留作后续。新增的 `TrackpadEdge.badgeTitle`（"左边缘/右边缘/上边缘/下边缘"）只服务徽标；编辑器的边缘选择器仍用 `settingsTitle`，因为那里紧邻"边缘"标签，不会被读成方向。

4. **`bottomInset = 96` 是估值，不是量出来的。** 系统音量 bezel 的实际高度没有公开 API，96pt 是照截图对齐的"同一条带"。若实机觉得偏高/偏低，改这一个常量即可，单测里的期望值会跟着算术一起失败并指出新值。
