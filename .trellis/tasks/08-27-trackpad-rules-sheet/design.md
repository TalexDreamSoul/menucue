# 技术设计：触控板规则表格化与弹窗编辑器

## 结构

| 文件 | 变化 |
|---|---|
| 新 TrackpadRuleEditorSheet.swift | sheet 编辑器：`@State draft: TrackpadGestureRule` + `let mode: .new/.edit` + `onSave/onDelete` 回调。内部搬入现有 familyFields/actionFields/阈值/范围控件（从 TrackpadSettingsView 平移，绑定从「settings 实时绑定」改为「draft 绑定」——绑定工厂改造为 `binding(for: \.keyPath, in: $draft)` 本地版，normalize 逻辑照旧） |
| TrackpadSettingsView.swift | 规则区重写为表格行组件 `TrackpadRuleRow`（启用/触发器徽标/名/动作/范围/不可用徽标/箭头）；`@State editingRule: SheetTarget?`（`.new` / `.existing(id)`）驱动 `.sheet(item:)`；删除内联展开状态与 811-1588 区间的旧编辑器（行号为重构前参考，以现状为准）；上移/下移/复制保留在行 hover 控件或上下文菜单；删除入口=sheet 内 + 行上下文菜单 |
| Localizable.strings | 新键 `/* Trackpad rule sheet */` 段：新建/编辑标题、保存/取消/删除规则（部分键已存在，先查再加）、Edge 键补齐 |

## 关键决策

- **草稿提交**：`onSave(draft)` → 调用方在 rules 数组中 upsert（按 id 定位替换或 append）→ 一次 `model.updateTrackpadGestureSettings`。可抽 `static func upserting(_ rule: Rule, into rules: [Rule]) -> [Rule]` 纯函数配单测。
- **触发器摘要徽标**：复用既有 `settingsSummary`/`settingsTitle` 文案函数拆出的短语（现有函数产出完整句；徽标取「族名」+「关键参数」两枚，函数化 `triggerBadges(for:) -> [String]`，配 3 个族的单测样例即可）。
- sheet 内手势族切换时草稿参数按现有 normalized 钳制走（与现状一致，不新增迁移逻辑）。
- 行内启用开关**直接生效**（不进草稿——开关是轻操作，维持列表即改即存；只有进 sheet 的字段走草稿）。
- `.sheet(item:)` 用 Identifiable 包装（`.new` 用固定 UUID 占位或独立 bool + item 两态，实现取简）。

## 风险

- TrackpadSettingsView 与另一并行任务（日历）无文件交集，但 **Localizable.strings 两任务都改**：本任务的键放 `/* Trackpad rule sheet */` 独立段、放在最后一步编辑、编辑前重新 Read，失配即重读重试。
- 现有 TrackpadSettingsView 行为测试若引用内联编辑器结构（先 grep 确认），随结构调整只改「取值路径」不改断言语义；识别测试（TrackpadGestureEngineTests 等）不受 UI 影响。
