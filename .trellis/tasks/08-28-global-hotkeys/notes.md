# 任务笔记（main 代记，2026-08-29）

实现者三点偏差/发现：
1. 既有断言唯一改动：SettingsInformationArchitectureTests 的 allCases 与 input 组清单补 .hotkeys（枚举花名册断言，枚举增长的必然代价）。
2. Carbon 实测：macOS 自占组合（如 ⌘Space）RegisterEventHotKey 返回 noErr 但永不触发，无法程序化识别「系统占用」；eventHotKeyExistsErr 仅在自身重复注册时出现。失败文案采用中性「该组合键已被占用」，编辑 sheet 附说明行。
3. 分区名 "Keyboard Shortcuts"/「快捷键」（"Shortcuts" 键已被快捷指令占用）；校验要求至少一个 ⌘/⌃/⌥（fn 在 Carbon 无位、⇧ 单独会吞普通输入）；HUD/触觉反馈沿用触控板开关。

与 rule-editor-advanced-fold 并行实施；合流后 676 tests / 1193 keys 全绿（fold 侧曾见的 2 个分组断言失败即第 1 条所解）。
