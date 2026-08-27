# MenuCue 架构全景与耦合梳理（探索 agent：arch-map，2026-08-27）

预期修正：**不存在「NotificationCenter 广播满天飞」**——全仓 0 个自定义 Notification.Name、0 处 post（测试除外）。实际通道：直接强引用（主）、闭包回调注册（AppModel.swift:163-171、:532-542）、Combine sink（StatusBarController.swift:189/192、QuickActionService.swift:121 手动转发 objectWillChange）、一个单例（PopoverPresentationState.shared，StatusTabView.swift:57 / PowerTabView.swift:9 / PowerFlowView.swift:12 直取）。

## 一、模块地图

### 入口层
- MenuCueMain.swift:5 —— @main 手写 NSApplication + .accessory，非 SwiftUI App
- MenuCueMain.swift:18 AppDelegate —— applicationDidFinishLaunching(:22) 手工组装：SettingsStore → CalendarService → AppearanceService → NotificationRuntimeStore(:29) → AppModel(:38) → StatusBarController(:49)；applicationWillTerminate(:60) 只 stop 触控板
- StatusBarController.swift:57 —— 764 行 AppKit 总控：状态栏 item、NSPopover、设置窗口 NSWindow、新建日程窗口、右键菜单、1 秒时钟定时器、菜单栏时钟绘制（NSImage.lockFocus 手绘胶囊 :326-388）、iCloud NSAlert(:223-248)
- StatusBarController.swift:7 PopoverPresentationState.shared —— 全仓唯一单例，只存 isVisible

### 状态层
- AppModel.swift:77 —— 唯一根 ObservableObject。10 个 @Published + 13 个 let 服务成员(:88-111)。既是状态容器又是服务定位器。无 @MainActor 标注
- AppModel.swift:5 CalendarRefreshController —— 6 个系统通知 + didWake，200ms 去抖刷日历
- AppModels.swift:122-330 AppSettings 值类型 —— 33 字段 + 8 个 mutating 业务方法
- SettingsStore.swift —— UserDefaults 编解码 29 key（4 个 legacy 迁移 :30-33）
- NotificationRuntimeStore.swift:74 —— actor，落盘 notification-runtime-v1.json
- PreferenceSyncService.swift:195 —— iCloud KVS，仅 8 个 PortableSettingField(:5-14)；触控板/通知配置不同步

### 服务层
常驻（AppModel 持有）：QuickActionService(:88)、TrackpadGestureService(:89)、PreferenceSyncService(:90)、PowerDiagnosticsService(:94)、ProcessEnergyService(:97)、ProcessHealthService(:99)、NotificationConfigurationService(:100)、NotificationRuntimeStore(:101)、NotificationDeliveryDispatcher(:102)、AlertMonitoringService(:103)。
View 局部创建：SystemMetricsService **两个实例**（StatusPopoverView.swift:57 历史 48 点 / DashboardView.swift:16 传 120）、SystemDetailService(StatusTabView.swift:63)、DashboardMetricsService(DashboardView.swift:17)、StatusSamplingController(StatusTabView.swift:64)。
隐藏依赖：PowerHelperManager 挂在 QuickActionService.swift:81。

### 视图层
StatusPopoverView.swift（2488 行、26 个顶层类型）同时装弹窗根视图与设置窗口根视图。

### 助手进程
MenuCueHelper/main.swift + PowerHelperProtocol.swift：XPC pmset 特权、进程 terminate/renice。客户端 PowerHelperManager.swift 921 行。

## 二、状态流转

**配置写入（唯一收敛路径，干净）**：View → AppModel.updateSettings(:183) → portable 差异+时间戳(:190-198) → applySettings(:492)：@Published 赋值 → settingsStore.save → appearanceService.apply → 触控板有变才 trackpadGestureService.apply → configureNotificationServices → refreshEventsIfPossible → 尾部推 iCloud(:201-203)。
**指标采集（散）**：SystemMetricsProbe/DashboardProbe/SystemDetailProbe 静态函数被 5 个宿主独立调用，各自维护基线：SystemMetricsService.swift:83、DashboardMetricsService.swift:45-49、AlertMetricProvider.swift:53-58。互不共享。
**告警投递**：8 个 SystemAlertMetricProvider actor 各跑 while 轮询（AlertMonitoringService.swift:194-200）→ AlertRuleEngine → store.commit → dispatcher.kick() → drainLoop（NotificationDeliveryDispatcher.swift:41，每轮重建 channel 含同步读 Keychain）→ HTTP。
**唯一跨领域桥**：AppModel.configureDarkWakeBridge(:527-546) —— GCD 回调 main.async 里再 Task 进 actor。

## 三、耦合与混乱点（按严重度）

- **C1** 弹窗和设置窗口同文件：StatusPopoverView.swift 装 StatusPopoverView(:45)、SettingsWindowView(:612)、SettingsPane(:714, 10 case)、DateTimeSettingsSection(:708)、SettingsContentView(:1108 路由器)、MenuBarFormatSettingsView(:818)、PreferenceSyncSettingsView(:998)、AnimationQualitySettingsView(:2240)、MonthCalendarView(:1752)、AgendaList(:2323)
- **C2** View onAppear 写全局设置并启动常驻服务：PowerTabView.swift:40 → AppModel.swift:346-355 permanently true + 启动后台监控；DashboardPowerSection.swift:26 第二触发点；冷启动恢复在 StatusBarController.swift:146-152
- **C3** View 直接调特权 XPC：PowerTabView.swift:753 terminateProcess、:760/:821 reniceProcess；helper 取自 :18 model.quickActionService.powerHelperManager
- **C4** PowerHelperManager 挂错宿主，4 个 View 深链取：StatusPopoverView.swift:1208、OverviewSettingsView.swift:36、QuickActionViews.swift:153、PowerTabView.swift:18
- **C5** 同一指标独立采 3-5 遍：CPU/内存/GPU/风扇各 3 条路径、磁盘 IO/网络各 5 条；告警链对 SystemMetricsService 零引用；SystemSensorReader（SMC）最多同时 12 份（2×Metrics + Dashboard + Detail + 8×AlertProvider）
- **C6** 同一对象 model 图内+View 单独 @ObservedObject：OverviewSettingsView.swift:36-38 一次拉三个；QuickActionViews.swift:14,53,152-153；TrackpadSettingsView.swift:19,1234；NotificationSettingsView.swift:10；StatusPopoverView.swift:1000-1005；PowerTabView 经 :194-197 传参。双更新通道
- **C7** View 里文件 IO/模态面板/系统深链：TrackpadSettingsView.swift:505-525 NSSavePanel+encode+write、:528-562 NSOpenPanel+security-scoped+2MB 校验+decode、:1574 又一个 OpenPanel、:1444 绕开 service.openAccessibilitySettings()（TrackpadGestureService.swift:1179）、:1730 runningApplications
- **C8** 导航状态孤岛+设置窗口重开重置 pane：弹窗 tab @State(:58) 初值只读一次(:81)；设置 pane @State(:616)；两个 SwipeRelay（StatusBarController.swift:158 弹窗 vs :658 设置窗口**每次 showSettingsWindow 新建**，仅 DashboardView.swift:98 消费，其他 pane 滑动静默失效）；showSettingsWindow(:648-685) 窗口已开也重建 contentViewController(:675) → pane 被重置（StatusPopoverView.swift:618-620 注释自认）
- **C9** 反馈通道 5 套：AppModel.errorMessage(:82)+launchAtLoginErrorMessage(:85)；QuickActionService.feedbackMessage(:620)；TrackpadActionExecutor 独立 NSPanel HUD(:970-1037)；TrackpadSettingsView @State feedbackMessage(:13)；NSAlert.runModal（StatusBarController:223-248、QuickActionService:513-521）。手势触发 QuickAction 时 HUD 与面板文本同时出
- **C10** 手势后台线程可同步弹模态：Executor:206 → QuickActionService:204 → :513-521 alert.runModal()；Engine 队列上 3 处 DispatchQueue.main.sync（TrackpadGestureService.swift:658/840/984）
- **C11** 两套并发模型：指标链 100% GCD（6 条自建队列）；通知链 100% Swift Concurrency（4 actor）；SystemAlertMetricProvider 从 actor 调 PowerDiagnosticsProbe.swift:203-232 的 while isRunning Thread.sleep 忙等 + waitUntilExit —— 协作线程池上同步阻塞
- **C12** configureNotificationServices(:504-525) 每次新建 Task 无取消无串行化 —— 连续两次设置变更 updateRules 顺序不保证
- **C13** refreshAll() 12 个调用点 7 个在 onAppear：StatusTabView.swift:109、TrackpadSettingsView.swift:39、QuickActionViews.swift:123/281/422、OverviewSettingsView.swift:55、StatusBarController.swift:656/757；开弹窗+落 status tab = 两次全量刷新（内跑 shortcuts list 子进程）
- **C14** 辅助功能权限判定三处重复：QuickActionService.swift:49-55（已有 AccessibilityPermissionRequesting 协议）、TrackpadGestureService.swift:516/898/1181、TrackpadActionExecutor.swift:468-470（名叫 request 实则只查）。SystemAccessibilityPermissionRequester.requestAccess()（QuickActionService.swift:59）死代码
- **C15** 后台态最多 11 条并发循环，理论峰值约 17；pmset -g log 单次约 5.4s/24MB；top -l 2 前台 15s 后台 300s

## 四、三个最核心结构性问题

1. **没有导航层**。导航全是 View 里的 @State（selectedTab :58 / selectedPane :616 / requestedDateTimeSection :617 / DashboardView section :27）。跨页跳转靠 5 个闭包下传（openSettings/openQuickActionSettings/openDashboard/selectPane/selectDateTimeSection）；深链靠重建 contentViewController（StatusBarController.swift:659-679）；「窗口开着再点设置就重置 pane」是设计必然。C1、C8 是它的表现。
2. **AppModel 是服务定位器不是状态容器**。13 成员 6 领域 615 行，View 深链取对象再二次订阅（C6），无 @MainActor。
3. **服务生命周期由 View onAppear/onDisappear 驱动**。retain/release 10 处、refreshAll 7 处在 View、enablePowerMonitoring 2 处在 View、SystemMetricsService @StateObject 创建两次。「此刻在采什么、采几份、何时停」无显式策略对象。C2、C5、C13、C15 是它的表现。

配置无双写：触控板真源唯一 AppSettings.trackpadGestureSettings；activeSettings(:1055)/Engine.settings(:88) 均只读派生。「状态存两处」的问题在指标数据（C5）不在配置。
