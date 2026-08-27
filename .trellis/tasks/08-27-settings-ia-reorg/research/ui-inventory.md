# MenuCue 完整 UI 盘点（探索 agent：ui-inventory，2026-08-27）

## 一、界面树

```
菜单栏本体  [StatusBarController.swift]
├─ 状态项标题：时钟轮播（日期胶囊+时间，可含国旗）[MenuBarClockRenderer.swift]
│   ├─ 左键 → 切换弹窗；滚轮 → 临时切换相邻时钟；右键 → 上下文菜单
└─ 右键菜单 [StatusBarController.swift:521-573]
    ├─ 显示/隐藏概览、设置…(⌘,)、检查更新、新建日程…(⌘N)
    ├─ 快速选择时区 ▸（自动轮换 + 各时钟勾选固定）← 此状态设置窗口不可见不可改
    └─ 退出 (⌘Q)

弹窗 360×620 [StatusPopoverView.swift]
├─ PopoverTabBar（顺序由「概览」分区拖拽列表决定；默认 状态→日历→电源→操作）[PopoverTabs.swift:3-8]
├─ ① 状态 [StatusTabView.swift]：CPU/内存/磁盘/风扇/网络卡（hover→MetricDetailPanel 浮层；点击→跳设置 Dashboard）+ 快捷操作卡 + All 链接
├─ ② 日历 [StatusPopoverView.swift:210-296]：世界时钟卡、月历（农历/周数/事件点）、日期详情卡（干支/节气/事件）、未来 7 天日程卡 + ⊕ 新建（sheet）、权限引导
├─ ③ 电源 [PowerTabView.swift]：电池流卡(Sankey)、阻止休眠卡、睡眠唤醒卡(含 🗑 清除历史)、电源配置卡(4 个系统级 pmset 开关)、能耗影响卡(进程 sheet：renice/终止/强确认)、进程健康卡、2 个确认 Alert
├─ ④ 操作 [QuickActionViews.swift:44-135]：已固定卡(x/7)、更多操作卡、「在设置中管理」
└─ 底栏 [PopoverComponents.swift:238-301]：运行时间 + ⋯ 菜单 + ⚙︎（与菜单里「设置…」重复）

设置窗口 900×680 NavigationSplitView [StatusPopoverView.swift:612-706]
① 仪表盘（7 横向 tab：CPU/GPU/内存/存储/网络/传感器/电源，全只读，唯一交互=恢复唤醒历史链接）[DashboardView.swift]
② 概览 [OverviewSettingsView.swift]  ③ 日期与时间 [StatusPopoverView.swift:1187-1212 + LanguageRegionSettingsView.swift]
④ 触摸板 [TrackpadSettingsView.swift]  ⑤ 快捷操作 [QuickActionViews.swift:139-425]
⑥ 通知 [NotificationSettingsView.swift]  ⑦ 外观 [StatusPopoverView.swift:1318-1350]
⑧ iCloud 同步（仅 entitled）[:998-1106]  ⑨ 语言 [LanguageRegionSettingsView.swift:117-190]  ⑩ 关于 [:1432-1525]

其他：新建日程独立窗口 540pt[:474-610]；清洁模式全屏覆盖层[CleaningDisplayOverlayCoordinator+QuickActionService:905-931]；触摸板 HUD(跟随鼠标 280×48 NSPanel)[TrackpadActionExecutor:970-1038]；iCloud 引导 NSAlert[StatusBarController:211-252]；合盖不休眠 NSAlert[QuickActionService:512-522]
```

## 二、设置项分布

侧边栏顺序（SettingsPane.allCases，StatusPopoverView.swift:714-724）：仪表盘→概览→日期与时间→触摸板→快捷操作→通知→外观→iCloud 同步→语言→关于。**无可辨识分组逻辑**。

| 分区 | 分组 → 设置项 | 文件 |
|---|---|---|
| 仪表盘 | 7 只读 tab，0 设置项 | DashboardView.swift |
| 概览 | 本机信息(只读)；**弹出面板页签**(拖拽排序，决定弹窗 tab 顺序+默认 tab):91-124；最近读数(只读):128-157；**采样** 5 控件:171-246；当前已开启(只读+管理跳转):319-338；状态 4 检查行:342-385 | OverviewSettingsView.swift |
| 日期与时间 | 菜单栏格式(约 9 控件):818-961；时钟轮播(轮播间隔/列表排序/标签/增删):1231-1316；概览显示:1214-1229；日历与日程(周起始/农历/全天/刷新/日历选择):1352-1430；macOS 系统时区(搜索/应用/助手):LanguageRegion:192-360 | StatusPopoverView + LanguageRegionSettingsView |
| 触摸板 | 运行状态(启用/重试/点击抑制/权限):57-245；实时触控预览:247-277；反馈与边缘控制(触觉/浮层/边缘宽度/灵敏度):279-309；手势规则(添加/启用/上下移/复制/删除/展开):311-381,713-809；内联规则编辑器(15-25 字段/条):811-1588；规则集(导入/导出/重置):383-418 | TrackpadSettingsView.swift |
| 快捷操作 | 已固定(x/7 排序移除):162-234；所有操作(**点磁贴=立即执行**，图钉固定):236-274,344-375；电源助手(安装/移除/刷新/系统设置):285-409 | QuickActionViews.swift |
| 通知 | 设备标识:34-53；4 渠道(飞书/Webhook/Bark/Telegram，凭据 SecureField):55-63,181-371；告警规则(约 12 字段/条):65-153,373-804 | NotificationSettingsView.swift |
| 外观 | 外观模式/参考时区/应用到系统:1318-1350；动画效果:2240-2265（两组均无标题）| StatusPopoverView.swift |
| iCloud 同步 | 1 项:998-1106 | 同上 |
| 语言 | 应用语言+重启:135-174；macOS 语言跳转:176-189 | LanguageRegionSettingsView.swift |
| 关于 | 版本(只读)；**登录时启动**:1443-1478；**自动更新**:1482-1505；链接:1509-1520 | StatusPopoverView.swift |

## 三、杂乱证据

### A. 藏得深/反直觉
1. **「弹出面板页签」排序藏在「概览」**（OverviewSettingsView.swift:91-124）——决定弹窗结构的最重要设置放在杂物页
2. **「登录时启动」「自动更新」在「关于」**（StatusPopoverView.swift:1443-1505）——最反直觉
3. **「采样」在「概览」，仪表盘分区 0 设置**——采样频率决定仪表盘表现，两者分离
4. **powerMonitoringEnabled 无开关**：PowerTabView.swift:40、DashboardPowerSection.swift:22-27 的 onAppear 隐式写 true；AppModel.swift:346-349 **只写 true 无关闭路径**
5. **「macOS 系统时区」在「日期与时间」最底部**，依赖的电源助手安装入口在另一分区
6. **边缘宽度/灵敏度是全局值**，滑块在「反馈与边缘控制」，说明文字却出现在展开的规则编辑器里（TrackpadSettingsView.swift:1083-1093）
7. **「快捷操作」副标题声称 manage Apple Shortcuts**（StatusPopoverView.swift:755）但**无管理 UI**——shortcuts 自动发现直接进目录（QuickActionService.swift:644-657），不能重命名/排序/隐藏

### B. 同一功能分散
1. **快捷操作 3 个执行入口 1 个管理入口**；**设置页点磁贴会真的执行**（含清空废纸篓）
2. **「时区」4 个不同含义设置散在 2 分区**：显示时区 / 时钟轮播列表 / 自动切换参考时区（在外观！）/ macOS 系统时区
3. **电源横跨 3 界面**：pmset 开关只在弹窗；助手安装在设置>快捷操作；监控开关不存在；唤醒历史清除在弹窗、恢复在设置>仪表盘
4. **电源助手是 5 处功能的前置依赖**，唯一入口在「快捷操作」底部
5. **日历权限引导出现 3 次**
6. **深色模式 2 个互相冲突控制点**：外观 Picker vs 快捷操作磁贴

### C. 弹窗内嵌、设置窗口没有的设置
pmset 4 开关+电源来源域（系统级！）、清除唤醒历史（破坏性，撤销在另一窗口）、进程 renice/终止、能耗视图切换、菜单栏时钟固定/轮换（右键菜单独占）

### D. 命名含糊
仪表盘 vs 概览近义且第一项非默认项（默认打开 overview，StatusBarController.swift:649）；概览=杂物抽屉（5 件不相关事）；快捷操作塞电源助手；关于塞启动更新；弹窗状态 tab 与设置概览/仪表盘三处内容重叠但详略频率各异

## 四、统计

设置分区 10 个（非 iCloud 用户 9 个）。仪表盘 0 交互项；概览 6；日期与时间约 16（最重）；触摸板 6 全局+每规则 15-25 字段；快捷操作 3 组；通知 3 组（渠道 4×N + 规则 12 字段×N）；外观 4；iCloud 1；语言 1；关于 2。
弹窗：4 tab、约 15 卡、3 sheet、2 Alert、6 类设置窗口没有的内嵌设置。

**建议先动的三件事**：1. 启动/更新挪出「关于」；2. 页签+采样拆出「概览」并取消该分区；3. powerMonitoringEnabled 补可见开关。
