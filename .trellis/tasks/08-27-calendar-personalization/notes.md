# 实现笔记：日历个性化

## 偏差

### 1. PRD R4 的 portable 表述自相矛盾（已由 lead 拍板订正，三字段已进 portable 集）

PRD R4 原文是「不进 iCloud portable 集，与现有日历字段同规格——先核对现有日历字段是否 portable，保持一致」。核对结果：**现有日历显示字段全部是 portable** —— `PortableSettingField` 里已有 `calendarWeekStartDay` / `showsLunarCalendar` / `allDayEventDatePolicy`（Sources/MenuCue/PreferenceSyncService.swift:5）。「不进 portable」与「和现有日历字段保持一致」互斥。

第一轮实现按 PRD 字面执行（只落 UserDefaults）并上报。2026-08-28 team-lead 拍板：以「与现有日历字段一致」为准，理由是三者同属显示偏好，跨 Mac 漫游符合用户预期。PRD R4 已同步订正。

补做内容（`Sources/MenuCue/PreferenceSyncService.swift`）：`PortableSettingField`、`PortableSettingValue` 各加 3 个 case，`isCompatible` 加 3 对配对，`portableValue(for:)` / `applyPortableValue` 各加 3 个分支。

发布与合并方向**没有**新增任何逻辑：`AppModel.updateSettings` 按 `PortableSettingField.allCases` 差分、`importPortableEnvelopes` 按 `portableModificationDates` 后写覆盖，全流程无逐字段特判，所以三个新字段与 `showsLunarCalendar` 行为完全一致。iCloud 键为 `menucue.preferences.v1.<字段名>`。旧版本 App 读到新 case 时 envelope 解码失败，被 `readCloudEnvelopes` 的 `try?` 跳过，不会崩。

### 2. `MonthWorkdayStats` 是结构体，不是 design 里的元组

design 写的是 `-> (workdays: Int, restDays: Int, isEstimated: Bool)`。实际返回 `MonthWorkdayStats`，多带 `elapsedWorkdays` / `containsToday`（R2 的「已过 A · 剩 B」需要）与 `localizedSummary`。是超集，不是缩减。

### 3. `DayKind` 携带 `StatutoryHoliday` 枚举，不是 design 里的 `name: String`

design 写 `case holiday(name: String)`。若把 `L10n.string(...)` 写进静态表，语言会在静态初始化时被冻住，切换 App 语言后已在屏幕上的日期不会改标签。改为存枚举、`DayKind.name` 读时解析，对外形状与 design 一致。

## 旁路发现

### 已顺手删除：`MonthCalendarView.selectedDateRelativeText`（死代码）

改动前它就没有任何调用点，且与本任务的距离信息条职责重叠（自带一套「N 天前 / N 小时前」文案）。留着会出现两套互相打架的距离口径，故随本任务删除。

副作用：以下 5 个 catalog 键现在无人引用（无测试会因此失败，LocalizationCoverageTests 只查 source→catalog 方向）：
`Less than 1 hour ago`、`%d hour ago`、`%d hours ago`、`%d day ago`、`In %d day`。

**没有删**——并行代理正在改同两个 .strings 文件，清理无关键值会平添冲突面。建议单独收口。

### 同样未动：`MonthCalendarView.selectedDateText` / `weekNumber(for:)`

也是死代码，但与本任务无关，未碰。

### 2027 年安排

预计 2026 年 11 月由国办发明电公布。届时只需往 `ChineseHolidayCalendar.holidayRuns` / `makeupRuns` 加一年，`coversYear` 自动跟随（它从 `holidayRuns.keys` 推导），不加则自动回退「按周一至五估算」并在统计行提示。
