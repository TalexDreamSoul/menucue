# 执行清单：日历个性化

1. [x] 读 prd.md（含节假日数据表）、design.md；读 MonthCalendarView 现状（StatusPopoverView.swift 弹窗日历部分）、CalendarSettingsView.swift、AppModels/SettingsStore 日历字段现状。
2. [x] 建 ChineseHolidayCalendar.swift（2025/2026 数据 + WorkdayCalculator + DateDistance），文件头注明国办发明电文号来源。
3. [x] 单测：WorkdayCalculatorTests（PRD 黄金用例逐条）+ DateDistanceTests（0/±1/换算边界）。先测后接 UI。
4. [x] AppSettings/SettingsStore 三个新字段（默认值、编解码、portable 对齐现状 —— 即进 portable 集，见 notes.md 偏差 1）。
5. [x] CalendarSettingsView 三控件。
6. [x] 月历 UI：hover 状态 + 距离信息条 + 月度统计行 + 详情卡「距今」行与假期/调休标签（开关全部生效）。
7. [x] 本地化（`/* Calendar personalization */` 段，en/zh 成对）。**Localizable.strings 留到最后一步编辑，编辑前重新 Read 一次**（另一任务的代理可能并行改同一文件；若 Edit 失配就重读重试）。
8. [x] 全量 `swift build && swift test` + `swift test --filter Workday 2>&1 | tail` + `./scripts/verify-localizations.swift <en> <zh-Hans>`；现有月历交互回归自查（选择/翻月/农历/事件点路径读代码确认未动）。

## 禁止

- 不改现有农历/节气/事件渲染逻辑；不新建 Calendar.current；不 git commit。
