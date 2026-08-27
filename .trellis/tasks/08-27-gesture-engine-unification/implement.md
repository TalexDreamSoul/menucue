# 执行清单：手势引擎统一抽象

分两个阶段（Stage A 识别与匹配、Stage B 动作层），阶段间必须全量 build+test 绿。每阶段由独立 implement 子代理执行。

## Stage A：识别与匹配收敛

1. [x] 读 research/trackpad-deep.md、design.md、Engine/Service/Models 现状。
2. [x] 建 TrackpadRuleMatcher.swift（RuleMatcher + TrackpadGeometry），带单测（specificity 排序、region/edge 几何与现实现逐一对拍）。
3. [x] Engine.eligibleRules 改调 RuleMatcher（行为等价，测试全绿）。
4. [x] Service 两个 SuppressionPolicy 改调 RuleMatcher/Geometry，删除本地副本；**补 specificity 排序**；新增覆盖抑制路径排序的测试。
5. [x] 建识别器协议 + 注册表；平移完成态六族（contact/swipe/edgeEntrySwipe/pinch/fingerSwipe/drawing）到各自识别器；Engine completionMatches 主 switch 删除。
6. [x] 平移 tipTap、edgeContinuous 到识别器（各自状态盒承接 Session 裸字段）；Engine.consume 改为遍历注册表；删除 :523-524 排除分支。
7. [x] 抑制需求声明化：注册表提供 suppressionNeeds；Service 删除 hasEnabledEdgeContinuousRule；装配逻辑改查询。
8. [x] 注册表穷举测试（每个 kind 恰有一个识别器）；全量 build+test。

## Stage B：动作层统一与声明修复

9. [ ] TrackpadFeedbackHUD 搬出为独立文件（接口不变）。
10. [ ] AppleScriptRunner 单点化；QuickActionService 与 Executor 改调；错误映射对齐两侧现状文案（本地化键复用）。
11. [ ] 打开 App/URL/文件 收敛（Executor 完整实现为准，QuickActionService 局部调用改走它）。
12. [ ] 触控板辅助功能判定复用 AccessibilityPermissionRequesting；清理死代码 SystemAccessibilityPermissionRequester.requestAccess（删除或接线，二选一并记录理由）。
13. [ ] Trackpad 动作结构化可用性（ActionAvailability 对齐 QuickActionAvailability，含 settingsURL）；失败文案接补救入口（UI 层消费在子任务 3，本任务先把数据给全）。
14. [ ] ActionCatalog 数据层：builtin 14 + shortcuts + 触控板原生动作登记；QuickActionService.catalogItems 改由目录生成；测试锁定 panel surface 清单与现状一致。
15. [ ] Match 瘦身（ruleID+action+标记）；Service.handle 改字段直取。
16. [ ] 动作执行路径 main.sync → async（抑制判定路径不动）。
17. [ ] tipTap 手指范围 UI 对齐引擎（2…4）+ 编辑器说明文案；预设名本地化键（en/zh-Hans）。
18. [ ] 全量 build + test + LocalizationCoverageTests；grep 验收（无 regionMatches/edgeContains/centroid 副本、无 hasEnabledEdgeContinuousRule）。

## 验证命令

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -40
# --filter matches suite names, not file names: TrackpadGestureTests.swift holds
# TrackpadGestureEngineTests, so filtering on the file name silently runs 0 tests.
swift test --filter Trackpad 2>&1 | tail -30   # 71 tests: 35 engine + 11 matcher + 6 registry + 19 policy
grep -rn "hasEnabledEdgeContinuousRule\|func regionMatches\|func edgeContains\|func centroid" Sources/ | grep -v TrackpadRuleMatcher.swift
```

## 回滚点

- Stage A 步骤 2-4（RuleMatcher）独立成立，可单独提交。
- 步骤 5-7（识别器化）失败可整体回退，RuleMatcher 收益保留。
- Stage B 每步独立可回退。

## 禁止

- 不改识别阈值/判定顺序/首个命中语义（specificity 修复除外，且要测试显式覆盖）。
- 不动 TrackpadGestureTrigger/Action 的序列化字段布局。
- 不改 UI 布局（子任务 3 负责）。不 git commit。
