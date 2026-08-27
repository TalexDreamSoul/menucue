# 资源占用审计报告（探索 agent：perf-audit，2026-08-27）

> 实测对象：运行中的 MenuCue 0.7.1 build 32（PID 856，已运行 2 天 1 小时），macOS 26.5。
> 方法：`sample` 5 秒 + `vmmap` + UserDefaults 解读，非纯静态分析。采样原始文件曾留存 /tmp/menucue-sample.txt（临时，可能已清理）。

## 结论摘要

**占用高的根源不是系统指标采样服务，而是菜单栏时钟的 1 秒定时器。** 所有指标采样服务（SystemMetricsService / DashboardMetricsService / SystemDetailService / PowerDiagnosticsService）的可见性门控写得正确，弹窗关闭后确实不跑。

### 实测数据

| 指标 | 数值 |
|---|---|
| 累计 CPU 时间 | 31 分 02 秒 / 49.3 小时挂钟 = **持续 1.05%** |
| 物理内存占用 | 119.7 MB（峰值 307.3 MB）|
| 堆状态 | 分区 253.5 MB，实际存活 53.0 MB，**碎片 31.0 MB（37%）**，398,923 个存活分配 |
| Mach 端口 | 709/709/711，稳定，无泄漏 |

`sample` 采样 5 秒共 3970 帧，3912 帧空转，**活跃帧 58**。以下占比以 58 为分母。

用户实际配置：触控板已启用、4 条规则全开其中 2 条 edgeContinuous、点击抑制开启、powerMonitoringEnabled=1、appearanceMode=system、2 个时钟、menuBarFormat 高级模式带秒、通知规则 0 条。

## 常驻工作清单（按嫌疑度排序）

| # | 来源 (file:line) | 频率 | 做什么 | 弹窗门控 | 实测占比 | 成本 |
|---|---|---|---|---|---|---|
| 1 | StatusBarController.swift:254-262 | 1 Hz 永久 | 时钟刷新总入口，2/3/4/5 全是它的下游 | 无 | 22/58 + 下游 21 | 高 |
| 2 | CoreAnimation 事务提交与重绘（#5 下游）| 1 Hz | CA::Transaction::commit → 递归 display | 无 | **21/58 (36%)** | 高 |
| 3 | StatusBarController.swift:373-425 dateCapsuleString | 1 Hz | 每秒建 NSImage、lockFocus 开 CGBitmapContext、两次文字测量两次绘制、NSTextAttachment | 无 | **10/58 (17%)** | 高 |
| 4 | AppearanceService.swift:9,27-38（经 AppModel.swift:488-490）| 1 Hz | NSApp.appearance = … → _invalidateWindowAppearances → 每秒对 WindowServer 同步 IPC + 递归遍历视图树 | 无 | **9/58 (16%)** | 高 |
| 5 | StatusBarController.swift:314-339 applyStatusTitle | 1 Hz | setAttributedTitle → _adjustLength → cellSize 重算 + AutoLayout | 无 | 8/58 (14%) | 中高 |
| 6 | AppModels.swift:790,793,835 countryCode(for:) | ~6 次/秒 | **函数内联字典字面量**每次现场构造 36+12 条；ClockTimeZone.custom(:358) 急切求值 flag；clockTimeZones(:210) 计算属性每次重建数组 | 无 | 1/58 | 中（纯浪费）|
| 7 | MenuBarClockRenderer.swift:73-74 | 1 Hz | 每次 render 设 formatter.timeZone → __ResetUDateFormat → **udat_open 重建 ICU formatter** | 无 | 1/58 | 中 |
| 8 | TrackpadGestureService.swift:1461-1473 currentContext() | 每帧 ~125 Hz（触摸时）| 每帧调 NSWorkspace.frontmostApplication + CGEventSource.flagsState，无缓存 | 手势总开关 | — | 高（触摸期间）|
| 9 | TrackpadGestureService.swift:909-933 边缘滚动 tap | 全系统滚动事件 | cgSessionEventTap headInsert，mask=scrollWheel；预设含 2 条 edgeContinuous → 默认装 | — | — | 中高 |
| 10 | TrackpadGestureService.swift:528-554 点击抑制 tap | 全系统左键事件 | 同上 mask=左键 | 用户已开 | — | 中 |
| 11 | MultitouchTrackpadSource.swift:342-357 | ~125 Hz | 每帧堆分配 [TrackpadContact] + deliveryQueue.async | 手势总开关 | — | 中 |
| 12 | TrackpadGestureService.swift:1395-1400 publishLiveContacts | 30 Hz | **设置窗口开没开都发**，每次 main.async + @Published | 无 | — | 中低 |
| 13 | ProcessEnergyService.swift:50-64 + ProcessEnergyProbe.swift:27-29 | 5 分钟 | 起子进程 `top -l 2 -n 40`（约 1 秒挂钟，枚举全进程）| powerMonitoringEnabled（已开）| mtime 证实在跑 | 中（突发）|
| 14 | PowerDiagnosticsService.swift:174-190 | 每次系统唤醒 | `pmset -g log`，实测 3.6-5.7 秒 / 24 MB | 唤醒驱动 | — | 中（突发）|
| 15 | AlertMonitoringService.swift:194-200 | 15-30 秒/规则 | 每条启用规则一个轮询 Task | 规则数 | 该用户 0 条未运行 | 潜在 |
| 16 | OverviewSettingsView.swift:57 | 15 秒 | Timer.publish 写在 body 里，每次 body 求值重建 publisher | 设置面板可见 | — | 低 |
| 17 | StatusBarController.swift:265-267,281 | 1 Hz | 每秒赋三个 VC 的 .appearance + interactionView.frame | 无 | 未命中 | 低 |

已核查为正确门控/无问题：SystemMetricsService（retain/release + StatusSamplingController）、DashboardMetricsService、SystemDetailService（hover 门控）、PowerFlowView（TimelineView paused）、PopoverFooter 计数器（60 秒）、PowerHelperManager（按需，helper 无轮询）、所有 NotificationCenter 观察者有配对移除。指标探针走 sysctl/host_statistics/IOKit，无周期性子进程（唯一例外 #13）。

## 内存

磁盘持久化历史均有界：wake-history 226KB/1686 条（上限 100,000/30 天）、process-energy 32KB/170 条（上限 200）、notification-runtime 63 字节（空）。

| 嫌疑 | 证据 | 判断 |
|---|---|---|
| 高频小对象分配堆碎片 | MALLOC_SMALL 保留 141.6MB/脏 75.5MB + empty 90.4MB 无法归还；253.5MB 分区装 53MB 存活；398,923 个分配 | **确认**，与 1Hz churn + 125Hz 触控板路径吻合 |
| NotificationRuntimeStore.events 无上限 | NotificationRuntimeStore.swift:221 只 append 不删；:227 每次 append 全数组 sort；:233 每次 commit 全量 JSON 落盘；:150/:241 全量遍历 | **真实缺陷，当前未触发**（0 条规则）。配置规则后为 O(n²) 增长 + 无界内存 |
| 峰值 307MB vs 当前 120MB | 无法直接归因 | 大概率设置窗口/Dashboard 或 pmset 24MB 解析，已回落非泄漏 |

## TOP3 CPU（证据链）

1. **StatusBarController.swift:254-262 的 1Hz 定时器整体**：22 帧直接在闭包内 + 21 帧在其触发的 CA 重绘 = 74% 活跃 CPU。采样期间弹窗关闭，重绘全是白烧。
2. **dateCapsuleString（:373-425）10/58**：`:394` lockFocus→CGBitmapContextCreate 每秒建位图；`:387/:388` sizeWithAttributes→CTLine 每秒两次排版测量；`:401/:411` 两次绘制；`:374` 每次 CTFontCreate。**画的是日期，一天变一次，每秒重绘。**
3. **AppearanceService.apply（:9,27-38）9/58**：appearanceMode=system 走 `NSApp.appearance = nil` 也**不是空操作**——setAppearance 无条件 _invalidateWindowAppearances：5 帧 SLSWindowServerClientCopySpacesForWindows→mach_msg（每秒同步 IPC），4 帧递归 15 层 _viewDidChangeAppearance 遍历 SwiftUI 视图树。AppModel.refreshTimeDrivenState()（:488-490）每秒无条件调用。

## TOP3 内存

1. 1Hz 时钟循环分配 churn（37% 碎片主因）。
2. AppModels.swift:790-848 内联字典字面量：约 6 次构造/288 个 String 分配每秒。改 static let 清零。
3. NotificationRuntimeStore.events 无界（潜在）。

## 修复顺序（收益/成本比）

1. dateCapsuleString 按 (text, flag, isDark) 缓存 NSAttributedString —— 砍 ~17% 活跃 CPU + 大部分堆 churn
2. AppearanceService.apply 脏检查（记住上次值，相同直接 return）—— 再砍 16% + 消除每秒 WindowServer IPC
3. countryCode 两个字典提成 static let；clockTimeZones 结果缓存（settings 变了才重建）
4. MenuBarClockRenderer.render 仅 timeZone 变化时赋值，避免重建 ICU formatter
5. 触控板：currentContext() 缓存 frontmostApplication（靠 didActivateApplicationNotification 失效）；publishLiveContacts 加设置窗口可见门控
6. NotificationRuntimeStore.events 补保留策略

**只做前两项，持续 CPU 预计 1.05% → ~0.4%**（CA 重绘 36% 主要由这两条触发）。
