# 执行清单：性能热修

按序执行，每步后跑最小验证。全部完成后跑全量 `swift build && swift test`。

## 步骤

1. [x] 读 `research/perf-audit.md` 与涉及文件的现状实现（StatusBarController.swift、AppearanceService.swift、AppModels.swift、MenuBarClockRenderer.swift、TrackpadGestureService.swift、TrackpadSettingsView.swift、NotificationRuntimeStore.swift、OverviewSettingsView.swift）。
2. [x] R3a：AppModels.countryCode 两个字典 → `static let`（纯移动，零行为变化）。
3. [x] R2：AppearanceService.apply 脏检查（记录 lastApplied，含 nil 语义）；StatusBarController :265-267,281 的每秒赋值加同值跳过。
4. [x] R3b：MenuBarClockRenderer formatter.timeZone 仅变更时赋值。
5. [x] R1：日期胶囊缓存。建议抽 `DateCapsuleCache`（键：胶囊文本+isDark+字体尺寸相关输入；值：最终 NSAttributedString）。外观/设置变更失效。字体 static。
6. [x] R3c：applyStatusTitle 同值跳过 setAttributedTitle。
7. [x] R6：OverviewSettingsView Timer.publish 移出 body。
8. [x] R4a：TrackpadGestureService frontmost 缓存 + workspace 通知失效（注意 engineQueue 线程安全：缓存值用锁或原子读写）。
9. [x] R4b：publishLiveContacts 增加 livePreviewActive 门控；TrackpadSettingsView onAppear/onDisappear 调 service 显式开关（经 AppModel 或直接 service 方法，跟随现有取用模式）。
10. [x] R5：NotificationRuntimeStore events 上限 1000 + 裁剪 + 消除每次全量 sort；新增 actor 级单测（append 超限裁剪、时序保持、旧超限文件加载后收敛）。
11. [x] 本地化：无新增用户可见文案，跳过（verify-localizations 1157 键通过）。
12. [x] 全量 `swift build && swift test`；失败区分本次改动 vs 既有问题。

## 验证命令

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -30
```

## 回滚点

每步独立可回滚；R1/R2 是收益主体，若 R4/R5 遇阻可单独放弃并在任务 notes 记录，不阻塞收尾。

## 禁止

- 不改识别逻辑、不改采样架构、不 git commit（由主会话统一提交）。
