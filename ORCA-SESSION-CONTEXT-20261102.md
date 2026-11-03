# Orca 会话上下文归档（2026-11-02）

只保留清理 Orca 前确认的未完成事项；不复制凭据、聊天标识或会话全文。

## 长按 Esc 退出：仍未完成真机归因

- 会话 `RMND: Add reminders and fix appearance scheduling` 的提醒、外观接管、清洁模式实现和测试已完成；随后用户反馈“长按 Esc 还是不会退出”。
- 合成事件驱动真实生产链路 `QuickActionService → CleaningModeController → KeyboardEventBlocker` 可以在约 3.5 秒后退出，说明核心计时逻辑不是主要问题。
- 真机长按事件尚未抓到可复核样本；机器上还有 WeType、Electron、PixPin、Vorssaint 等键盘 tap，可能改变 Esc 事件。
- 会话末尾源码已恢复到无调试残留，后台只读抓取曾启动；后续应重新做**有界**真机抓取并确认 tap 归因，不要凭合成事件宣布修复。

## 版本/代码状态

- Orca 清理前的本地工作树已整体提交到分支 `backup/orca-cleanup-20261102`，提交 `85c7d2599285d4ecc8f35c789c3f7dedfba0afcc`，并推送到 `origin`。
- 本文件只记录会话上下文，不代表长按 Esc 已经发布；发布前仍需按项目既有流程重新验证。
