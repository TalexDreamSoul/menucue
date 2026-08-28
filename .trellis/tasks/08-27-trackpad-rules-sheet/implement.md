# 执行清单：触控板规则表格化与弹窗编辑器

1. [x] 读 prd.md、design.md；读 TrackpadSettingsView.swift 现状（规则区、编辑器区、绑定工厂、availability 消费）；grep 测试对内联编辑器结构的引用。
2. [x] 抽 `upserting(_:into:)` 纯函数 + 单测（新增 append、编辑替换、id 不存在时 append）。
3. [x] 建 TrackpadRuleEditorSheet.swift：草稿绑定工厂 + 平移 familyFields/actionFields/阈值/范围控件 + 三段式布局 + 取消/保存/删除。
4. [x] TrackpadSettingsView 规则区改表格行（TrackpadRuleRow：启用开关直改、触发器徽标 triggerBadges(for:)、动作摘要、范围、不可用徽标、箭头）+ `.sheet(item:)` 接线 + 添加按钮预填默认草稿；删除旧内联编辑器与其状态。
5. [x] 上移/下移/复制/删除可达性收口（行控件或上下文菜单 + sheet 内删除）。
6. [x] triggerBadges 单测（tipTap/edgeContinuous/swipe 三样例）。
7. [x] 本地化：`/* Trackpad rule sheet */` 段新键 + 补 Edge 键。**Localizable.strings 留到最后编辑，编辑前重新 Read**（日历任务代理可能并行改同一文件，失配即重读重试）。
8. [x] 全量 `swift build && swift test`（TrackpadGestureTests 零断言改动）+ `swift test --filter Trackpad 2>&1 | tail -15` + `./scripts/verify-localizations.swift <en> <zh-Hans>`。

## 禁止

- 不动规则数据模型/序列化/识别引擎；不改全局区块（运行状态/预览/反馈边缘控制/导入导出）；不 git commit。
