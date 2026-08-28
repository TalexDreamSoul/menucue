# 父任务整体核对台账（2026-08-28 收官）

四份探索报告的问题逐条核对。提交序列：`25a0384`(规划+设计稿) → `c79aca8`(性能热修) → `4f0d58b`(手势 Stage A) → `ee930e8`(手势 Stage B) → `fd5625d`(chore) → `ebd3262`(IA Stage A) → `eab1616`(IA Stage B) → `5f5e028`(IA Stage C) → 导航层提交。最终 547 XCTest + 5 swift-testing 全绿（1 例副屏环境跳过），本地化 1117 键 en/zh 键集一致。

## perf-audit（17 项）

| # | 问题 | 状态 |
|---|---|---|
| 1-5,17 | 1Hz 时钟路径（定时器/CA 重绘/胶囊/appearance/标题/VC 赋值） | ✅ 已修 c79aca8（缓存+脏检查；R1+R3c 实例耦合有双向约束注释） |
| 6 | countryCode 内联字典 | ✅ 已修 + statusTitle 同款（check 自修） |
| 7 | ICU formatter 每秒重建 | ✅ 已修（timeZone 变更判据 (identifier,isSystem)） |
| 8 | 每帧查 frontmostApplication | ✅ 已修（缓存+workspace 通知失效） |
| 9 | 边缘滚动 tap 常驻 | ⏸ 有意保留（功能语义：有启用的 edgeContinuous 规则即需装配；装配条件已声明化） |
| 10 | 点击抑制 tap | ⏸ 保持现状（显式 opt-in 开关，主会话拍板不与规则挂钩） |
| 11 | 每帧 [TrackpadContact] 分配 | ⏸ 未动（有界拷贝，识别正确性路径） |
| 12 | publishLiveContacts 无门控 | ✅ 已修（30Hz 门控 + 引用计数 + 窗口可见性 VisibilityGate 覆盖关窗场景） |
| 13/14 | top/pmset 周期与唤醒采样 | ✅ 收口（powerMonitoring 现有可见开关，可彻底关闭） |
| 15 | NotificationRuntimeStore 无界 | ✅ 已修（上限 1000+有序追加；AlertMonitoring 0 规则未触发） |
| 16 | OverviewSettingsView timer in body | ✅ 已修（后随文件删除） |
| — | clockTimeZones 计算属性重建 | 📋 后续候选（双源失效设计） |

## arch-map（C1-C15 + 三大根因）

| # | 问题 | 状态 |
|---|---|---|
| C1 | 弹窗+设置同文件（2488 行） | ✅ 已修（拆 SettingsWindowViews/ActionCenterView/5 分区文件；主文件 1417 行） |
| C2 | onAppear 隐式永久开启电源监控 | ✅ 已修（显式开关 setPowerMonitoring + 关闭态提示行） |
| C3/C4 | View 直调特权 XPC / helper 挂错宿主 | 📋 后续候选（属 AppModel 拆解） |
| C5 | 同一指标独立采 3-5 遍 | 📋 后续候选（统一采样服务；现门控均正确） |
| C6 | 双更新通道 | 🔶 部分（沿用仓库惯例；根治属 AppModel 拆解） |
| C7 | View 内文件 IO/模态 | 📋 后续候选 |
| C8 | 导航孤岛/重开重置 pane/死 relay | ✅ 已修（AppRouter+Sequenced+hosting 单建+deminiaturize+外观下发协议；仪表盘历史不再清空） |
| C9 | 反馈通道 5 套 | 🔶 部分（ActionAvailability/failure(key|message) 统一词汇；HUD 与面板双通道有意保留） |
| C10 | 手势线程同步模态 | ✅ 已核验（分发路径 async；3 处同步保留有记录理由） |
| C11 | 两套并发模型/协作池忙等 | 📋 后续候选 |
| C12 | configureNotificationServices 竞态 Task | 📋 后续候选 |
| C13 | refreshAll 12 调用点 | 🔶 部分（弹窗重复刷新守卫；其余保留） |
| C14 | 辅助功能判定 3 处重复+死代码 | ✅ 已修（收敛协议+接线） |
| C15 | 后台循环数量 | ✅ 改善（1Hz 瘦身+门控收紧+监控可关） |
| 根因1 导航层缺失 | ✅ 已修（AppRouter） |
| 根因2 AppModel 服务定位器 | 📋 后续候选（本轮有意不动，规模超范围） |
| 根因3 生命周期 View 驱动 | 🔶 部分（VisibilityGate 统一窗口级门控、监控显式开关；统一采样策略对象属后续） |

## ui-inventory（杂乱证据 A/B/C/D）

启动/更新出「关于」入「通用」✅；页签排序+采样出「概览」入「面板」、概览取消 ✅；仪表盘独立窗口、第一项=默认项 ✅；powerMonitoring 可见开关 ✅；pmset 上收设置+弹窗只读摘要 ✅；唤醒历史清除/恢复同归电源分区 ✅；设置页点击即执行取消（显式运行+确认）✅；操作中心来源分段+被引用徽标 ✅；弹窗操作页搜索/分组/折叠/不可用徽标 ✅；日历权限引导收敛权威分区 ✅；时区归属收敛（菜单栏/通用）🔶（参考时区在通用外观组，语义即如此）；深色模式双入口 ⏸（磁贴=动作、设置=模式，语义不同有意保留）；快捷指令仍无重命名/隐藏 📋（管理 UI 候选）。

## trackpad-deep

三份谓词副本→单一 RuleMatcher（补 2 处排序）✅；13 处 kind 分支→Engine/Service 归零、新增族触点 15→6 ✅；识别器协议+注册表+状态盒 ✅；抑制需求声明化 ✅；动作层单向桥→共享 ActionRunners/ActionCatalog/ActionAvailability ✅；5 指 tipTap 死配置关闭 ✅；预设名双语 ✅；HUD 独立文件 ✅；Match 瘦身 ✅；补救入口 UI（规则列表/编辑器）✅。有意保留：胖联合体 16/10 字段（序列化兼容）、识别魔数硬编码、edgeContinuous 双指契约（测试固化）。

## 后续候选任务池（按价值排序）

1. AppModel 拆解 + 服务生命周期策略对象（C3/C4/C5/C6/C7/C11/C12/根因2/3 残留）
2. CI 建设：swift build+test+verify-localizations（带参数）+性能采样基线——本轮全部质量门都靠会话纪律，仓库无强制
3. clockTimeZones 缓存；胖联合体瘦身；Alert 键正名（日程编辑器中文语义错，属既有）；"Edge" 未本地化；AlertMetricProvider RPM 未本地化
4. 触控板规则编辑器弹层化（画板 C 交互形态）；快捷指令管理（重命名/隐藏）
5. 功能域删除清单（锐评项：手势 6 族无预设、通知 4 渠道、进程 renice 的真实使用核对）——产品决策待用户

## 实机待确认（无 GUI 会话无法验证）

弹窗搜索框方向键归属；操作中心「全部」段滚动长度；触控板分区关窗重开后 30Hz 预览恢复；仪表盘 Power 标签关窗后 pmset 停止；系统深浅色切换三窗跟随。

## 增量子任务（2026-08-28 第二批，并行实施）

- **日历个性化**（4dd3bad）：日期距离悬浮/详情行、月度工作日统计、2025/2026 法定节假日+调休内置表（国办发明电〔2024〕12 号 / 〔2025〕7 号，check 逐字核对+手算五个月复核）、三个 portable 偏好。20+2 新单测。
- **触控板规则表格化**（c044efc）：表格行 + 三段式 sheet 草稿编辑（取消零写入、保存单次提交），旧内联编辑器删净，顺带修「规则名每键被 trim」老 bug。9 新单测。
- **并行分派基建发现**（重要，未来多代理并行必读）：① trellis hook 把「当前活动任务」上下文注入**所有**子代理——与 dispatch 首行 Active task 不一致时会串台，代理必须按首行路径自行 Read；② 共享 `.build` 下并行构建会互踩（"input file modified during build" / SwiftPM 锁），单次失败先重试再下结论；③ 并行期间 LocalizationCoverageTests 可能因对方半成品暂红，合流后自愈。
- 实机待确认追加：触控板行尾 controlsWidth=58 在不可用徽标出现时约差 1pt（真机看后再调 62）；sheet 560pt 三段式滚动高度；月历悬浮距离条与统计行的视觉密度。
- **触控板反馈与灵敏度修复**（实机反馈驱动）：HUD 固定屏底+多屏适配（visibleFrame 纯函数布局+6 单测）、tipTap 按住连发（每完整点按一次，0.12s 防抖；check 另修「抹动点按连累下一次」缺陷）、边缘响应参数提升、徽标文案修正。遗留：持锚停顿 >0.65s 后首次点按被超时丢弃（PRD 保持约束不变，实机若觉得"停顿后第一下不灵"即此处）；bottomInset=96 待实机校准。
