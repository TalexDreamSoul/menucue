# 全局快捷键触发动作

## 背景

用户需求（2026-08-28）：「按住某个快捷键录入之后，它可以快速把当前应用切换到下一个屏幕之类的。」两部分：①全局快捷键录制与绑定（绑定统一动作库的任意动作）；②新增「窗口移到下一个显示器」动作。这是 ActionCatalog 设计时预留的 hotkey surface 的落地。

## Requirements

### R1. 快捷键设置分区（输入组新分区「快捷键」）
- 绑定列表：快捷键 chip（⌃⌥⌘K 样式）+ 动作（图标+名）+ 启用开关 + 行菜单（编辑/删除）。
- 添加/编辑：录制控件（进入录制态捕获 modifiers+key，Esc 取消录制；要求至少一个修饰键，避免裸键劫持）+ 统一动作选择器（ActionCatalog 全量：内置 / 快捷指令 / 触控板原生动作，含 availability 徽标与补救入口）+ 保存/取消（草稿式，与触控板 sheet 同模式）。
- 冲突检测：与本 App 既有绑定重复即拒绝保存并提示；系统占用（注册失败）在行上显示不可用原因。

### R2. HotkeyService（运行时）
- Carbon RegisterEventHotKey 实现（无需辅助功能权限）；绑定变更即时重注册；App 退出注销；注册失败逐条可见（不可用状态入行）。
- 触发路径复用现有动作执行链（QuickActionService/executor 路由 + 触觉/HUD 反馈一致）。

### R3. 新动作：窗口移到下一个显示器
- 窗口布局动作族新增 nextDisplay：AX 取前台 App 焦点窗口 → 移动到下一 NSScreen（循环序），按目标屏 visibleFrame 等比适配并钳制；单显示器时返回不可用原因。
- 需要辅助功能权限：复用既有 ActionAvailability(settingsURL) 机制；触控板窗口动作与快捷键共用该实现（登记进 ActionCatalog，操作中心可见）。

### R4. 存储与引用
- AppSettings 新增 hotkeyBindings（机器本地，不进 iCloud portable——与触控板规则同规格；理由：快捷指令目录与显示器拓扑跨机不同）。
- 操作中心「被引用」徽标扩展：显示动作被哪些快捷键绑定引用。

## Acceptance Criteria
- [ ] build/test 全绿；本地化双语齐备。
- [ ] 单测：绑定编解码与旧设置兼容、冲突检测、references(of:) 含 hotkey、nextDisplay 目标屏几何换算（多屏 mock 场景：右移循环/等比钳制/单屏不可用）。
- [ ] HotkeyService 注册/注销成对（协议注入 mock 断言，模式对齐 PointerFreeze 测试）。
- [ ] 无新增权限提示的意外弹窗：AX 权限只在执行窗口动作且未授权时经 availability 提示。
