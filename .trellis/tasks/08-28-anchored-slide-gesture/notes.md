# 带修 bug：右指 tipTap 不触发

用户实机报告「只有左指轻点有效，右指完全不响」。先写复现测试再动代码，结论是**两条嫌疑都不成立**，
真因是第三条：

- 嫌疑 1（跨会话状态泄漏）：**不成立**。识别器状态存在 `session.recognizerStates`，
  引擎在全部抬手时 `sessions.removeValue`，新会话必得全新 `SessionState`。
  回归测试 `testAFingerThatTappedInOneSessionDoesNotShadowTheOtherInTheNext` 在修复前即通过。
- 嫌疑 2（武装时过早绑定首条规则）：**不成立**。Pending 只记手指序号，规则是在**发射时**
  按 `selectedFingerIndex` 从全部 eligible 规则里筛的。
  回归测试 `testTheFirstLiftOfASessionMayBeEitherFingerWithBothRulesEnabled` 修复前即通过。

## 真因 A：陈旧 Pending 从不失效（用户症状的直接来源）

一次成功轻点后，识别器按「连发」设计重新武装一个绑定**同一手指**的 Pending。
当该手指落回休息时，它落在 `recontactRadius` 内，于是被当作这个 Pending 的 recontact 收下。
此后另一指的每次抬起都不是它等的那个 recontact，被静默吞掉；而武装分支的前置条件是
`state.pending == nil`，永远不再成立 —— **整只手被锁死在第一次轻点的那根手指上，直到全手抬起**。

用户先试了列表第一条（左指）后，右指就再也不响，症状完全吻合。

## 真因 B：手指序号取自会话开局的触点 ID

武装时用 `session.initialOrder.firstIndex(of: endedID)` 定序号。`initialOrder` 存的是会话开局的
触点 ID，而**轻点过一次的手指落回时是全新 ID**，不在其中 → `firstIndex` 返回 nil → 武装失败。
只修 A 时，左→右可以了，右→左仍不行。

## 修法

`TrackpadTipTapRecognizer.consume` 开头新增失效判定：锚指不再全部在板上，或有「非本 Pending 所等
recontact」的手指抬起 → 丢弃 Pending。同一帧内武装分支随即接管这次抬起。该改动是单调的：
原先这两种情形下 Pending 只能挡住武装、不可能促成任何发射，丢弃只会把「永久吞掉」变成「重新武装」。

序号改由 `orderedHand(including:restingOn:in:)` 按**落点 x** 给「当前这只手」（抬起的那指 + 仍在
休息的锚指）排序得出，天然容纳换了 ID 的手指。`spacingMatches` 同步改吃这只手，
消掉文件里最后一处「拿开局阵容当现状」的读法（原实现在 `.near`/`.far` 下会用旧落点量间距；
两条出厂预设都是 `.normal`，且该路径无既有测试）。

## 测试

| 测试 | 修复前 | 修复后 |
|---|---|---|
| `testEitherFingerKeepsTappingWhileTheHandStaysDown`（左→右→左，手不离板） | **失败**，只得到 `[volumeUp]` | 通过，`[volumeUp, volumeDown, volumeUp]` |
| `testAFingerThatTappedInOneSessionDoesNotShadowTheOtherInTheNext`（跨会话） | 通过 | 通过 |
| `testTheFirstLiftOfASessionMayBeEitherFingerWithBothRulesEnabled`（首抬即右指） | 通过 | 通过 |

第三次轻点（右→左）专门覆盖真因 B：那时左指已是会话开局阵容里不存在的触点。
既有 tipTap 测试断言零改动，全部通过。

---

# 触点核算：新增 anchoredSlide 手势族

统一识别器架构承诺「新增一族 ≤6 处改动」。本任务是该承诺的第一次实测，逐处列账如下。

## 实际触点（6 处源码 + 1 处双语文案）

| # | 位置 | 改动内容 | 是否属承诺内 |
|---|---|---|---|
| 1 | `Sources/MenuCue/TrackpadGestureModels.swift` | `TrackpadGestureKind` 加 `anchoredSlide`；新增 `TrackpadSlideAxis`；胖联合体加 `slideAxis` 字段；预设加一条；`TrackpadGestureMatch` 投影 `claimsScrollSuppression` | 是 |
| 2 | `Sources/MenuCue/TrackpadGestureRecognizers.swift` | 新识别器 `TrackpadAnchoredSlideRecognizer`；注册表加一行；新增 `TrackpadInputSuppressionOwnership` 声明 + 注册表投影 | 是 |
| 3 | `Sources/MenuCue/TrackpadGestureService.swift` | 抑制所有权推广（见下） | 是（推广，非本族分支） |
| 4 | `Sources/MenuCue/TrackpadRuleEditorSheet.swift` | `familyFields` 新增 `.anchoredSlide` 分支 | 是 |
| 5 | `Sources/MenuCue/TrackpadSettingsView.swift` | `keyParameter` 徽标、`settingsSummary`、`TrackpadGestureKind.settingsTitle` 三处穷举 switch + `TrackpadSlideAxis` 标题扩展 | 是 |
| 6 | `Sources/MenuCue/Resources/{en,zh-Hans}.lproj/Localizable.strings` | 9 个新键，双语 | 是 |

`TrackpadGestureEngine.swift` 零改动，`TrackpadRuleMatcher.swift` 零改动，
`TrackpadActionExecutor.swift` / `TrackpadFeedbackHUD.swift` 零改动 —— 连续动作
（`continuousVolume` / `continuousBrightness`）与冻结协调器都是按声明消费的，新族接入不需要它们知情。

**结论：6 处，未超承诺。** 其中 3 处（模型枚举、编辑弹窗、设置页展示）是穷举 switch 的必然代价，
编译器会在漏改时报错，属于「加一族必须回答的三个问题」而非架构泄漏。

## 触点 3 的性质：推广而非新增分支

`TrackpadEdgeScrollSuppressionPolicy` 是边缘几何特化的：它在识别之前就能从原始帧判断
「两指在同一边缘走廊」，因此边缘族的滚动抑制先于第一步结果到位。锚定滑动没有这种几何——
「两指静止待滑」与「两指正在滚动」在原始帧里完全一样，无法预判。

按 PRD 要求走「活跃连续会话」路径，把 `edgeGestureOwned` 机制推广为两种所有权来源：

- 新增声明 `TrackpadInputSuppressionOwnership { rawFrameGeometry, activeSession }`，
  默认 `.rawFrameGeometry`（今天唯一的 scrollWheel 族即边缘族，行为不变）。
- 新增纯策略 `TrackpadSessionScrollSuppressionPolicy`：首个结果取得所有权，持有到该设备触点结束，
  结束时触发动量排空。生命周期与 `TrackpadPointerFreezeCoordinator` 完全同构（同样的理由：
  第一步之前无从分辨）。
- `TrackpadMatchDispatchPolicy.shouldDispatch` 读声明而非族名：几何预置族仍必须先被授予才能派发
  （既有断言原样通过），自认领族的结果本身就是授予动作。
- `TrackpadEdgeScrollSuppressionDecision` 更名 `TrackpadScrollSuppressionDecision`（两条路径共用，
  原名已不诚实），并加 `merged(with:)`。

Engine 与 Service 中没有任何一处新增 `case .anchoredSlide` 或按 kind 的判断。

### 一处真实取舍：抑制生效点

边缘族的抑制在识别之前到位，本族只能在第一步之后到位。因此**第一步之前的极少量原生滚动会漏过**
（默认预设约需滑动 5% 触摸板才产生第一步）。这是「无几何可预判」的固有代价，不是实现缺陷；
要消除它只能回到几何镜像谓词，正是 PRD 明确禁止的方向。

配套改动：`edgeScrollSuppressor.setGestureActive(...)` 由「识别前调用」移到「识别后调用」，
因为第二条所有权路径要等结果才存在。两条路径仍在决定它们的同一帧内到达 event tap；
对边缘族而言只是同一个同步函数里晚了几微秒的纯算术。

## 与 tipTap 共存（R2）的实现选择

滑动指的左右序号**每帧按当前落点重算**，而不是锁定 `session.initialOrder`。
原因：tipTap 的抬起—落回会换掉触点 ID，若锁定初始序号，一次点按之后同一只手就再也滑不动了——
那正是 PRD 说的「吞会话」。代价是极近的两指落点顺序理论上可能翻转，实际不可达（落点差 <1 像素）。

姿势临时缺指（点按期间）只**暂停**并清空 `lastPositions`（避免把空档算成位移），不取消规则；
只有锚指越过 `movementTolerance` 才粘性取消——漂移的滚动不该被允许接着完成它误开的调节。

## 假阳性防线（未写进代码的约束，写进了 UI 文案）

两指一起移动 = 滚动，一指移动 = 本手势，二者的唯一分界是「锚指容差 < 每步距离」。
预设取 `movementTolerance 0.025 / minimumDistance 0.05`（2:1）。用户若把步距调到比容差还小，
普通双指滚动就可能蹭出一步。选择不在代码里强制这条不等式（用户有权配置细步长），
改为在规则编辑弹窗直接写明这条关系，并用测试锁定预设自身满足它。

## 既有测试的表格扩展（非断言变更）

新增一族必然使若干「穷举表」失配，以下是补表，不是放宽断言：

| 文件 | 改动 |
|---|---|
| `TrackpadRecognizerRegistryTests` | 3 张 kind→期望字典各加一行（suppression / freezesPointer / fingerCounts）；有状态族集合加 `.anchoredSlide`；`testOnlyTheContinuousEdgeFamilyFreezesThePointer` 更名为 `…ContinuousFamilies…`（名字已不再成立） |
| `TrackpadRuleEditorSheetTests` | 预设徽标期望数组加第 5 条 |
| `TrackpadGestureTests` | `presets.count` 4 → 5 |

`presets.count` 是本次唯一被改写的数值断言，且改写不可避免：PRD R3 要求新增预设。

## 主会话合并前处理（2026-08-28）

- 澄清：本文件早先「四文件零改动」指批次一（本任务）自身的触点；合并态工作区中这四个文件含批次二（用户直接指令驱动的六轮改动，作者 check-pointer-lock，归因见父任务台账）。
- 4 vs 12 裁决：边缘族单帧步数上限 12 → 11，使出厂预设最大突发 11×0.018=0.198 ≤ 执行器单次钳制 0.2，消除快挥时 ~7.4% 的不可恢复截断；新增 TrackpadContinuousClampTests 钉住该不变量（两族出厂预设全覆盖）。
- HUD 布局测试的陈旧面板常量改为引用 TrackpadFeedbackHUDLayout.panelSize。
- 快捷键录制器（批次二第三部分）主会话人工复核：监视器五路径成对；「录制中关窗」会吞掉下一次按键后自愈（局部监视器自限），记录不阻塞。
- 遗留转后续：HUD 连续期间 ~28Hz orderFront 重绘节流。
