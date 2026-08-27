# 触控板手势引擎统一抽象

## 背景

见 `research/trackpad-deep.md`。数据模型层抽象成立（8 手势族 × 9 动作族），但：识别层是 3 条互不共享的硬编码路径（用户要的两个功能各占一条私有分支）；规则匹配谓词复制 3 份，其中 2 份缺 specificity 排序（潜在 bug）；kind 分支散落 5 文件 13 处；动作层与 QuickAction 是「一套主系统 + 一座单向桥」，AppleScript/打开类实现重复、可用性与结果类型不统一。另有死配置（5 指 tipTap 可配但永不触发）与未本地化的预设名。

## 目标

识别、匹配、动作三层各收敛为单一抽象，使「新增一个手势族」的触点从 15 处降到 ≤6 处（新识别器类型 + UI 字段 + 本地化），且现有 4 条预设与全部既有测试行为不变（除声明的 bug 修复）。

## Requirements

### R1. 单一 RuleMatcher（修 2 个潜在 bug）
- 新建统一的规则过滤与排序实现，Engine 的 `eligibleRules`（Engine:554-563）、`TrackpadClickSuppressionPolicy.shouldArm`（Service:52-67）、`matchingEdges`（Service:439-453）三处收敛到它。
- 后两处补上 specificity 排序（声明的行为修复）。
- 共享几何函数（regionMatches / edgeContains(Start) / centroid / 边缘走廊扩张常数）单点化，消除 Engine 与 Service 的逐字重复副本。

### R2. 识别器协议 + 注册表
- 每个手势族一个识别器类型，实现统一协议（per-frame 消费 + 会话结束评估两个钩子，各族按需实现其一）。
- Engine 的 `consume()` 从「3 条硬编码路径 + 显式排除 switch」改为遍历注册表；`case .tipTap, .edgeContinuous: return false`（Engine:523-524）消失。
- 各族中间态从共享 `Session` 裸字段（Engine:68-86）移入按 kind 隔离的识别器状态。
- 识别器声明自己的输入抑制需求；Service 的 `hasEnabledEdgeContinuousRule` 特判（Service:1436-1440）改为查询注册表。
- 评估顺序与首个命中语义保持与现状一致（既有测试全绿是硬约束）。

### R3. 动作层统一
- AppleScript 执行、打开 App/URL/文件 收敛为单一实现，供 QuickActionService 与 TrackpadActionExecutor 共用。
- Trackpad 动作补齐结构化可用性（对齐 `QuickActionAvailability`：isAvailable / reason / settingsURL），失败文案可给出补救入口。
- 触控板侧辅助功能权限判定复用既有 `AccessibilityPermissionRequesting` 协议（QuickActionService.swift:49-55），消除 3 处重复；处理死代码 `SystemAccessibilityPermissionRequester.requestAccess`。
- 引入 `ActionCatalog`：内置 14 项 + Shortcuts + 触控板原生动作（音量/亮度/窗口布局/键鼠合成）统一登记，带 surface 标记（panel / trackpad）。本任务 UI 不变化（popover 仍只显示现状条目）；目录为子任务 3 的「操作中心」提供数据。
- `TrackpadFeedbackHUD` 从 Executor 移出为独立文件（机械搬移）。

### R4. 声明的行为修复
- 5 指 tipTap 死配置：UI 手指数范围与引擎能力对齐（tipTap 限 2…4），并在规则编辑器给出说明。
- 预设规则名本地化（en/zh-Hans）；已保存的用户规则名不迁移，仅新建/重置预设时生效。
- 手势线程同步弹模态（arch C10）：动作执行路径的 `DispatchQueue.main.sync` 改异步派发；仅抑制判定等需要返回值的路径保留同步。
- Match 瘦身：从携带整条 rule 改为携带执行意图（ruleID + action + 所需标记），解除识别结果与完整配置的耦合。

## Acceptance Criteria

- [ ] `swift build`、`swift test` 全绿；`TrackpadGestureTests` 既有用例不修改断言而全部通过（specificity 修复若影响个别断言，需逐条说明并经主会话确认）。
- [ ] 全仓 grep：regionMatches/edgeContains/centroid 只剩单一实现；`hasEnabledEdgeContinuousRule` 不存在；Engine 中无 per-kind 排除 switch。
- [ ] 新增测试：RuleMatcher specificity（含抑制路径）、注册表覆盖全部 kind（穷举一致性）、tipTap 手指范围 UI-引擎一致性、ActionCatalog 登记完整性。
- [ ] 「新增一个手势族」演练文档化：在 design.md 附上触点清单，≤6 处。
- [ ] LocalizationCoverageTests 通过；预设名双语。
- [ ] 4 条预设的实际手势行为不变（tipTap 音量、edgeContinuous 音量/亮度）。

## 范围外

- 设置 UI 的 IA/视觉重排（子任务 3）。
- popover 展示触控板原生动作（子任务 3 决定露出方式）。
- 识别阈值魔数的可配置化（记录为后续任务候选，本次不动默认行为）。
