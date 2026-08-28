# 决策记录：触控板规则表格化与弹窗编辑器

## 偏差 1：行内列顺序与 PRD R1 不同（宽度所迫）

PRD R1 列为「启用 | 触发器徽标 | 规则名 | 动作 | 生效范围 | 不可用徽标 | 箭头」。
实测：规则区在 `SettingsGroup` 里被钳到 560pt，按固定列排下来（触发器 168 + 动作 132 +
范围 84 + 尾部控件 58 + 开关 32 + 列间距）留给规则名只剩约 130pt，
「Left finger tap · Volume Up」这类预设名会被截成「Left finger tap · V…」。

改为：`[开关] [规则名 / 触发器徽标（两行，弹性列）] [动作 132] [范围 84] [不可用+菜单+箭头 58]`，
表头同宽（Rule / Action / Scope）。元素一个不少，只是徽标改排在名称下一行，
名称拿到 ~215pt。徽标行与范围列各挂 `.help()` 给出完整文案。

## 偏差 2：上移/下移改入菜单

旧行上有独立的 ↑/↓ 按钮；表格化后行尾只留「⋯ 菜单 + 箭头」，
菜单与右键上下文菜单都含【编辑 / 上移 / 下移 / 复制 / 删除】，sheet 内另有「删除规则」。
上移/下移在首尾行按 index 置灰，与旧按钮的 disabled 条件一致。

## 偏差 3：复制规则不再自动打开编辑器

旧行为：复制后自动展开副本的内联编辑器。现在复制只做列表插入（立即生效，与旧写入等价），
不自动弹 sheet——否则「复制后取消」会让用户以为副本被撤销，而副本其实已经落盘。

## 偏差 4：两处字段归属调整（语义未动）

- 「所需修饰键」从旧的【规则详情】段移入 sheet 的【触发器】段：它是触发前置条件。
- 应用范围编辑器内部的 "Applications" 标题从 `subheadline` 降为 `caption` 次级标题，
  给新的第三段标题 "Scope" 让位。

字段本身、`normalized` 钳制、序列化、识别引擎均未改动。

## 可见性调整（无实现变更）

`TrackpadSettingsLayout` / `TrackpadLabeledSlider` / `TrackpadUIFormat` 与 19 个
`settingsTitle` / `settingsSummary` 扩展由 `private` 改为 internal，
因为它们现在被 `TrackpadSettingsView.swift` 与 `TrackpadRuleEditorSheet.swift` 共用。
`triggerBadges` / `upserting` 也是 internal，用于单测。

## 文案

新增 8 键（`/* Trackpad rule sheet */` 段，en/zh 成对）：
`Rule`、`Edit Rule`、`New Gesture Rule`、`Edit Gesture Rule`、`Scope`、
`Edge`（PRD 点名的既有缺口）、`%d fingers · %@`、`Finger %d · %@`。

删除 3 键（随内联编辑器一起失效，全仓 0 引用）：
`Collapse rule editor`、`Rule Details`、`%@ → %@`。

## 旁路发现（并行分派）

1. **注入上下文串台**：本代理收到的 `<!-- trellis-hook-injected -->` 段落里是
   **日历任务**（08-27-calendar-personalization）的 prd/design/implement 全文，
   与 dispatch 首行 `Active task: .trellis/tasks/08-27-trackpad-rules-sheet` 不一致。
   实际任务文档是按首行路径自行 Read 的。多代理并行时 hook 注入似乎不按 agent 隔离，
   若无「先看 Active task 路径再 Read」的纪律，代理会照着别人的 PRD 干活。

2. **共享 `.build` 目录**：与日历代理并行时，一次 `swift build` 因对方在编译中途改写
   `SettingsStore.swift` 直接失败（`error: input file ... was modified during the build`），
   重跑即恢复；另一次 SwiftPM 提示等待对方实例释放 `.build` 锁。
   并行代理的构建/测试结果需要复跑确认，不能凭单次失败下结论。

3. 全量 `swift test` 中途出现过一次 `LocalizationCoverageTests` 失败，
   缺的键全部来自日历代理尚未落地的 `ChineseHolidayCalendar.swift` / `StatusPopoverView.swift`，
   对方补完文案后自愈。本任务两个文件在该测试里始终零缺键。
