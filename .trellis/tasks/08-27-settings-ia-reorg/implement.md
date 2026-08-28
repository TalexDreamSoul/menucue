# 执行清单：设置信息架构重组

分三个阶段，每阶段结束全量 build+test 绿后再进下一阶段。

## Stage A：分区骨架与内容迁移

1. [x] 读 research/ui-inventory.md、design.md；grep `SettingsPane` 全部使用点（含深链、持久化、菜单项）列成清单存任务 notes。
2. [x] 新 SettingsPane 枚举（9 case + 分组 + migrating(rawValue:) 映射）；侧边栏分组渲染（组标题小字 + 分区行）。
3. [x] 建 5 个新分区视图文件（MenuBar/Panel/Calendar/Power/General SettingsView），内容从现视图**平移组装**（不重写控件逻辑）；设置窗口类型迁入 SettingsWindowViews.swift。
4. [x] 「关于」瘦身；删除 概览/外观/iCloud/语言/日期与时间 独立分区；OverviewSettingsView.swift 拆解删除。
5. [x] 逐项核对 research/ui-inventory.md 第二节分布表：每个设置项标注新归属，漏项为零。build+test。

## Stage B：行为修复与独立窗口

6. [ ] powerMonitoring 显式开关（电源分区）；移除两处 onAppear 隐式 enable；AppModel.setPowerMonitoring(enabled:)（false 停后台采样）；弹窗电源 tab 顶部关闭态提示行。
7. [ ] 弹窗电源 tab「电源配置卡」→ 状态摘要 + 「在设置中配置」；pmset 卡视图迁入 PowerSettingsView。
8. [ ] 仪表盘独立窗口（StatusBarController.showDashboardWindow）；侧边栏移除仪表盘；全部 deep-link 改道；「恢复唤醒历史」迁到设置>电源。build+test。

## Stage C：操作中心与弹窗操作页

9. [ ] 操作中心重构：来源分段（内置/快捷指令/触控板原生·目录驱动）、行式列表、显式运行按钮（点行不执行）、图钉、被引用徽标（references(of:) 纯函数 + 单测）；电源助手组迁出。
10. [ ] 弹窗操作页：搜索框、内置分类 DisclosureGroup、快捷指令组默认折叠、不可用徽标、底栏「管理操作…」；内置 14 项分类表按 implement 附录。
11. [ ] 承接子任务 2 遗留：a) 触控板动作可用性数据接 UI——规则列表/编辑器对不可用动作显示原因徽标与「打开系统设置」补救按钮（executor.availability(for:) 与 TrackpadActionExecutionResult.settingsURL 目前无生产消费者）；b) TrackpadActionExecutionResult.failure 拆 failure(key:)/failure(message:) 两个入口，消除「参数是 key 还是成品句子」的含糊。
12. [ ] 本地化：全部新键 en/zh-Hans；废键清理（含既有重复键 "System"×2、"Add"×2）；LocalizationCoverageTests。同步修 spec 漂移：.trellis/spec/frontend/state-management.md:326「hide sync pane」改为「General 分区组级 entitled 门控」；弹窗两处旧措辞（PopoverComponents.swift:267 "Quick Actions…"、QuickActionViews.swift:106 "Manage in Settings"）随步骤 10 更新。
12. [ ] 全量 build+test；手动核对清单（新分区可达性、深链、开关行为）写入任务 notes。

## 附录：内置动作分类建议

- 显示与屏幕：保持屏幕常亮 / 关闭显示器 / 屏幕保护程序 / 深色模式 / 隐藏刘海 / 自动隐藏菜单栏 / 隐藏桌面图标
- 系统：锁定屏幕 / 低电量模式 / 合盖不休眠 / 自动隐藏程序坞 / 清空废纸篓
- 清洁：清洁屏幕 / 清洁键盘
（与实际 14 项以代码为准，实现时校对）

## 验证命令

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -40
grep -rn "SettingsPane\." Sources/ | grep -vE "menuBar|panel|calendar|actionCenter|trackpad|alerts|power|general|about|migrating" 
```

## 回滚点

Stage A/B/C 各自独立可回退；Stage C 依赖子任务 2 的 ActionCatalog，若缺失按 design.md 回退路径（两段式）执行。

## 禁止

- 不改任何设置的存储键与默认值（powerMonitoring 语义修复除外，且已开启用户无感）。
- 不动触控板规则编辑器交互形态。不 git commit。
