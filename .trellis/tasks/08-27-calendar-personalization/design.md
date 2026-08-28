# 技术设计：日历个性化

## 新文件

**ChineseHolidayCalendar.swift**
```swift
struct ChineseHolidaySchedule {   // 按年静态表，文件头注释来源文号
  enum DayKind { case holiday(name: String)      // 放假日
                 case makeupWorkday(name: String) } // 调休上班的周末
  static func kind(of date: Date, calendar: Calendar) -> DayKind?   // 无命中返回 nil
  static func coversYear(_ year: Int) -> Bool                       // 2025/2026 → true
}

enum WorkdayScheme: String, Codable { case chineseStatutory, weekdaysOnly }

struct WorkdayCalculator {        // 纯函数，全部可单测
  static func isWorkday(_ date: Date, scheme: WorkdayScheme, calendar: Calendar) -> Bool
  static func monthStats(month: Date, scheme: WorkdayScheme, calendar: Calendar)
    -> (workdays: Int, restDays: Int, isEstimated: Bool)   // isEstimated = 数据外年份回退
  static func distance(from today: Date, to date: Date, calendar: Calendar) -> DateDistance
}

struct DateDistance { let days: Int; /* 派生 weeks/remainder */ }
extension DateDistance { var localizedDescription: String }  // 文案规则见 PRD R1
```
- `calendar` 一律传入（跟随现有 MonthCalendarView 使用的 Calendar 实例与周起始设置），不隐式用 `.current`。
- 判定顺序：makeupWorkday → 工作日；holiday → 休息日；否则按 weekday。

## 改动点

| 文件 | 改动 |
|---|---|
| AppModels.swift | AppSettings 新增 `calendarShowsDateDistance: Bool = true`、`calendarShowsMonthStats: Bool = true`、`calendarWorkdayScheme: WorkdayScheme = .chineseStatutory` |
| SettingsStore.swift | 三个新键（命名跟随现有 `calendar*` 键风格）+ 编解码 + 默认值；portable 与否对齐现有日历字段的现状 |
| CalendarSettingsView.swift | 「日历与日程」组内追加三控件（Toggle×2 + Picker） |
| StatusPopoverView.swift（MonthCalendarView 一带） | ①日期格 `.onHover` 记录 hoveredDate（开关关闭则不挂）；②网格与详情卡之间的距离信息条（悬浮优先，无悬浮显示选中日；高度固定避免跳动）；③网格下方月度统计行；④日期详情卡追加「距今」行 + 节假日/调休标签 |
| Resources/*.lproj/Localizable.strings | 新键统一放 `/* Calendar personalization */` 段（含格式键：`%d 天前/后`、`%d 周`、`%d 周 %d 天`、假期/调休上班标签、按周一至五估算提示、设置项文案） |
| Tests/MenuCueTests/ | 新 WorkdayCalculatorTests（黄金用例见 PRD）+ DateDistanceTests |

## 交互细节

- 悬浮信息条与统计行都是纯文本行（12px 上下），不引入卡片嵌套；reduced-motion 无动画。
- 节假日格子的可视化（如现有节日文案「中元节」）不动——本任务只加距离/统计层，不改现有农历/节气渲染。
- 统计行「已过」定义：严格早于今天的工作日数；今天为工作日时计入「剩」。

## 风险

- MonthCalendarView 位于 StatusPopoverView.swift（弹窗部分），改动要克制、保持既有 hover 性能（onHover 状态更新只改文本行，不触发整格重绘——hoveredDate 用独立 @State，信息条单独取值）。
- Calendar 周起始/时区：全部走既有 calendar 实例，杜绝新建 Calendar.current 造成口径漂移。
