# 边缘手势期间锁定鼠标指针

## 背景

用户实机反馈（2026-08-28）：「双指滚动触发的时候鼠标不能动」——做边缘连续调节（音量/亮度）时指针会被触控板输入带跑，要求手势活跃期间指针冻结。

## Requirements

### R1. 冻结窗口
- 起点：边缘连续手势首次步进发射（确认进入连续调节，而不是刚进走廊就冻——避免普通滚动误伤）。
- 终点：会话结束（全部手指抬起）后立即恢复；现有 0.3s 惯性排空逻辑若会继续吞滚动事件，冻结也随会话结束即停（指针恢复优先于排空美观）。

### R2. 实现与安全网（缺一不可）
- 首选 `CGAssociateMouseAndMouseCursorPosition(false/true)`；若实测有权限或副作用问题，回退方案：冻结期间记录起点 + 每帧 `CGWarpMouseCursorPosition` 回弹。
- 恢复路径必须成对且多重兜底：①会话结束；②引擎/识别器 reset；③TrackpadGestureService.stop() 与总开关关闭；④失效定时器（自最后一帧起 1.5s 无帧强制恢复）；⑤应用终止路径（applicationWillTerminate 已调 stop，确认链路覆盖）。
- 冻结/恢复抽成可注入协议（真实 CG 调用薄封装），单测用 mock 断言所有路径成对、不重复冻结、不遗漏恢复。

### R3. 范围
- 仅 edgeContinuous 族；tipTap 与其他族不冻结。
- 不新增辅助功能权限要求（CGAssociate/CGWarp 均不需要 AX；若实测发现需要，停下来上报）。

## Acceptance Criteria
- [ ] build/test 全绿；`--filter Trackpad` 全绿。
- [ ] mock 单测：正常会话、异常 reset、服务 stop、失效定时器四条路径 freeze/unfreeze 严格成对。
- [ ] 无新增权限；无残留冻结的代码路径（review 级核验）。

## 追加（实测发现，2026-08-28）

### R4. 规则编辑弹窗 Esc 关闭
实测发现 sheet 编辑器按 Esc 无法关闭（取消按钮未接 cancelAction）。给「取消」补 `.keyboardShortcut(.cancelAction)`，「保存」接 `.defaultAction`（回车保存，需确认名称输入框回车不误触——TextField 提交语义检查一下）。
