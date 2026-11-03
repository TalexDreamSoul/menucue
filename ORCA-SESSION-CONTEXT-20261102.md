# Orca 会话上下文归档（2026-11-02）

这是历史会话交接快照，不是当前运行结果；不复制凭据、聊天标识或全文。项目已从 `~/orca/projects/touch-macer` 迁到 `~/Workspace/Projects/touch-macer`，源码、Git 与私有配置保留，构建缓存不纳入源码提交。

## 长按 Esc 退出：仍未完成真机归因

- 会话 `RMND: Add reminders and fix appearance scheduling` 的提醒、外观接管、清洁模式实现和测试已完成；随后用户反馈“长按 Esc 还是不会退出”。
- 历史会话报告：合成事件驱动真实链路 `QuickActionService → CleaningModeController → KeyboardEventBlocker` 可在约 3.5 秒后退出；这只证明合成输入场景，不能排除真实输入路径的缺陷。
- 真机长按事件尚未抓到可复核样本；机器上还有 WeType、Electron、PixPin、Vorssaint 等键盘 tap，可能改变 Esc 事件。
- 会话末尾源码已恢复到无调试残留，后台只读抓取曾启动；后续应重新做**有界**真机抓取并确认 tap 归因，不要凭合成事件宣布修复。

## 版本/代码状态

- Orca 清理前的本地工作树已整体提交到分支 `backup/orca-cleanup-20261102`，提交 `85c7d2599285d4ecc8f35c789c3f7dedfba0afcc`，并推送到 `origin`。
- 本文件只记录会话上下文，不代表长按 Esc 已经发布；发布前仍需按项目既有流程重新验证。
