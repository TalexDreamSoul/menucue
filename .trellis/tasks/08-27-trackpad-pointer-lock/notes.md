# 决策记录（边缘手势期间锁定鼠标指针）

## 挂钩点：用「族声明 + match 投影」而不是在识别器里调 CG

识别器是纯逻辑层，`TrackpadEdgeContinuousRecognizer` 里不出现任何 CG 调用。沿用仓库既有的
`suppressionNeed` 通道：识别器声明 `static let freezesPointer = true` → `TrackpadRecognizerRegistry`
汇总 → `TrackpadGestureMatch.freezesPointer` 投影 → Service 消费。Service 只读 match 的布尔位，
不重新解释 trigger.kind，与 `suppressionNeed`/`confirmsSuppressedClick` 的既有形状一致。

冻结起点取 `dispatchableMatches.contains(where: \.freezesPointer)`——即「已通过 dispatch 策略、
真的要执行动作的那一步」。走廊内但因未取得滚动所有权而被 `TrackpadMatchDispatchPolicy` 拦下的帧
不冻结，普通两指滚动因此不会误伤。

## 恢复路径与 `stop()` 的同步释放

`release()` 幂等，加在全部 6 个 `engine.reset*` 现场（invalidFrameHandler / apply / retry / stop /
handleWake / handleSleep），外加 `stop()` 开头的一次**同步**调用。

同步那一次不是冗余：`stop()` 里原有的清理都在 `engineQueue.async { [weak self] ... }` 内，而
`AppModel.deinit` 也会调 `stop()`——此时 weak self 已为 nil，队列块整体被跳过。若只在块里释放，
deinit 路径会漏掉恢复。`applicationWillTerminate` 走的是活对象，两条路径现在都被覆盖。

协调器因此需要跨线程可调用，采用 `NSLock`（与 `TrackpadEdgeScrollSuppressor` 同一模式）。
freezer 调用发生在持锁期间，`SystemPointerFreezer` 一律 `DispatchQueue.main.async`（不做
「已在主线程就同步执行」的分支），以主队列 FIFO 保证跨线程决定的 freeze/unfreeze 不会换序。

## 看门狗时钟：不用 `frame.timestamp`

`TrackpadFrame.timestamp` 来自 MultitouchSupport 回调的设备时钟，与 `ProcessInfo.systemUptime`
不保证同基准。失效定时器与「最后一帧时刻」若跨时钟比较会误判，故协调器自带注入的 `now` 闭包，
生产环境统一用 `systemUptime`，帧只提供「有没有接触」这一位信息。定时器同样注入
（`engineQueue.asyncAfter`），单测里手动推进时钟并手动触发，1.5s 路径无需真实等待。

## `unfreeze` 里的 warp：顺序是 warp → associate(1)

`CGWarpMouseCursorPosition` 之后有默认 0.25s 的本地事件抑制间隔，Apple 文档给出的解法正是紧接着
调 `CGAssociateMouseAndMouseCursorPosition(true)` 立即恢复。按此顺序写，warp 只用于消除
「重新关联后指针跳到硬件漂移位置」的可能，不引入恢复延迟。

出处校核（check 阶段）：该 0.25s 说法出自 Quartz Display Services 在线参考，**不在** SDK 头文件里
——`CGRemoteOperation.h:220-223` 对 warp 只写了「不产生事件地移动指针」。代码注释里给的是另一条
同向理由（把指针钉在原处），两条都指向同一顺序，故实现无需改动；仅记录引用来源以免后人误以为
头文件背书。

## 权限与副作用（实测前的确认项）

- 无新增权限：本仓非沙盒（`Resources/MenuCue.entitlements` 只有 ubiquity-kvstore），
  `CGAssociateMouseAndMouseCursorPosition` / `CGWarpMouseCursorPosition` 属 Quartz Display
  Services，不需要辅助功能；`CGEvent(source: nil)?.location` 读当前指针位置同样不需要。
- 该 API 的固有副作用：解关联是**全局**的，冻结期间外接鼠标同样不动。PRD 首选方案即此 API，
  会话最长约一次连续调节，实机若觉得不可接受，回退方案（每帧 warp 回弹）只影响
  `SystemPointerFreezer`，协调器与挂钩点不动。
- 0.3s 惯性排空未受影响：冻结随会话结束即止，排空继续吞它的滚动事件（PRD R1 指定的优先级）。

### 实机第一项要验的不是「会不会卡死」，是「会不会根本不生效」（check 阶段补记）

`CGRemoteOperation.h:235-236` 对该 API 的原话是「Connect or disconnect the mouse and cursor
**while an application is in the foreground**」。MenuCue 是 `LSUIElement` 菜单栏 App
（`Scripts/build-app.sh:161`），做边缘手势时前台几乎总是别人。头文件没有说明非前台调用是「不生效」
还是「照常生效」，本机无法跑 GUI 验证，所以这是实机第一个要看的现象：

- 冻结不生效 → 失败方向是安全的（指针照旧能动，不会卡死），走 PRD R2 的回退方案（每帧 warp 回弹），
  只换 `SystemPointerFreezer`，协调器与挂钩点不动。
- 冻结生效 → 按已上报用户的知情项，冻结期间外接鼠标同样不动。

另一条同源的待观察项：若系统在 App 失活时自动恢复关联，冻结会在会话中途悄悄失效——表现为指针中途
「解冻」，不是卡死。

### 退出路径：`main.async` 的解冻块在终止时可能排不到（check 阶段发现，未改代码）

`applicationWillTerminate` → `stop()` → `release()` → `freezer.unfreeze()` → `DispatchQueue.main.async`。
此时正在主线程的 run loop 回调里，函数返回后 AppKit 直接退出进程，这个块通常**不会**被排空。
同一个 `stop()` 里的抑制器关闭走的是 `runOnMain`（主线程即同步执行），所以只有解冻这一步被推迟。

是否要紧完全取决于「进程退出时 WindowServer 会不会自动恢复鼠标关联」——普遍认为会（该状态按连接
维护，崩溃的全屏游戏不会永久留下断开的指针），但 SDK 头文件没写，无法在本机证实。

实机第二项要验的就是它：**冻结期间直接退出 App，指针还能不能动**。

- 能动 → 无需改代码，本条结案。
- 不能动 → 需要一条终止专用的同步解冻（给 `PointerFreezing` 加一个同步入口，仅在 `stop()` 末尾走）。
  它不违反「一律 async」的保序前提：终止之后没有任何块会再执行，同步解冻不可能被后到的 freeze 覆盖。
  但这是给注入口加 API，属选型层改动，留给 lead 定夺，未擅自实现。

## R4（sheet Esc 关闭）：未改代码，因为要求的改动已经在仓库里

R4 的前提「取消按钮未接 cancelAction」与现状不符，**照做会是一行重复修饰符，并让「已修复」这个
结论失真**，故停下来记录。证据：

- `Sources/MenuCue/TrackpadRuleEditorSheet.swift:157-158` 已是
  `Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)`；
  `:160-165` 已是 `Button("Save") { … }.keyboardShortcut(.defaultAction)`。
- `git log -S "keyboardShortcut(.cancelAction)" -- <该文件>` 只有 `c044efc`（创建该 sheet 的那次提交，
  2026-08-27）；`git status` / `git diff HEAD` 显示该文件无本地改动。

### 已排除的原因

| 假设 | 排除依据 |
|---|---|
| 设置窗口不是 key window，键等价物根本不触发 | 普通 titled `NSWindow`，`present(_:)` 走 `makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps:)`（`StatusBarController.swift:798-805, 844-864`） |
| 全局吞 Esc 的事件监视器泄漏 | `CleaningModeController` 确实装了「Esc 一律返回 nil」的 local monitor（`QuickActionService.swift:878-890`），但 `stop()` 里成对移除（`:854-857`），`start()` 先调 `stop()`，且 1s 倒计时到点强制 `stop()`——不泄漏 |
| sheet 上挂了 `.interactiveDismissDisabled` | 全仓无该修饰符 |
| 用户碰到的是另一个规则编辑入口 | 触控板侧只有 `TrackpadSettingsView.swift:54` 一处 `.sheet(item:)`；其余 sheet 在 PowerTabView / StatusPopoverView |

### 最可能的真实原因（需实机确认，本机无法跑 GUI 验证）

按下 Esc 时键盘焦点在文本控件里。sheet 的首个可聚焦控件就是 header 的「Rule name」`TextField`
（`:97-100`），即**刚打开时焦点已经在输入框**；另有 Note 的 `TextEditor`（`:133`）。macOS 上
field editor / NSTextView 自己处理 Esc（补全或 abort editing），SwiftUI 的 `.cancelAction` 在这种
焦点状态下不触发是已知现象，与「按 Esc 关不掉」的症状吻合。

**30 秒判别实验**：打开 sheet → 点一下非文本控件（如「Trackpad devices」下拉或空白处）把焦点移出
输入框 → 按 Esc。
- 能关 → 确认是焦点吞键，修法在焦点层（sheet 根加 `.onExitCommand { dismiss() }`，或显式管理
  `@FocusState`），不在按钮层。
- 仍不能关 → 说明按钮的键等价物压根没装上，是另一类问题，修法也不同。

两条分支的修法不同，所以在判别之前不动代码。

### 关于「保存」绑 `.defaultAction` 的回车语义（lead 的确认项）

现状已绑，语义是：「Rule name」`TextField` 没有 `.onSubmit`，回车会执行默认按钮 → 保存并关闭；
Note 的 `TextEditor` 吃掉回车用于换行，不会触发保存。也就是**回车保存今天就是线上行为**，不是本次
引入的。是否算「误触」属产品判断；R4 给的兜底（「保存不绑快捷键」）前提是这次新绑，与现状不符，
故未改动线上行为。
