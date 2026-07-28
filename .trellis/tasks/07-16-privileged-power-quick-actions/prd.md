# Privileged Power Quick Actions

## Goal

缩小菜单栏弹窗中的快捷功能区域，修复 Apple 快捷指令缺失图标，并通过用户明确批准的特权 Helper 提供真实的低电量模式和合盖不睡眠切换。

## Requirements

### R1 — 紧凑快捷功能区域

- 快捷功能网格仍为 4 列、最多 7 个固定动作加“更多”。
- 弹窗宽度由 320pt 缩小为 304pt，高度由 680pt 缩小为 640pt。
- 紧凑图标圆形区域不超过 34pt，单项高度不超过 62pt，行间距不超过 8pt。
- 名称保持最多两行，不能截断“Auto-hide Menu Bar”等默认动作的可读信息。
- 快捷区域必须继续在打开弹窗时完整可见。

### R2 — Apple 快捷指令图标

- 每个 Apple 快捷指令必须显示 macOS 14 可用的通用快捷指令图标。
- SF Symbol 不可用时必须回退到可显示的 `command.square.fill`，不得渲染为空圆。
- 内置动作图标和状态色行为保持不变。

### R3 — 特权 Helper 生命周期

- Helper 使用 `SMAppService.daemon(plistName:)` 注册为应用包内 LaunchDaemon。
- 第一次启用特权动作时，TouchMacer 必须请求注册；需要管理员批准时打开“登录项与扩展”系统设置并显示等待批准状态。
- 设置页必须显示 Helper 的未注册、等待批准、已启用和失败状态，并提供注册、打开系统设置和卸载操作。
- Helper 必须通过 XPC 暴露严格限定的电源接口，不得接受任意命令、脚本、路径或参数。
- Helper 必须验证调用方是当前 TouchMacer 主程序的有效代码签名，拒绝其他本地进程。
- Helper 未启用时，低电量模式和合盖不睡眠保留在目录中；点击后进入 Helper 安装/批准流程，不得伪造切换成功。

### R4 — 低电量模式

- Helper 以 root 权限调用固定的 `/usr/bin/pmset` 参数。
- 支持新系统的 `powermode` 和旧系统的 `lowpowermode` 键。
- 启用时将电池和电源适配器模式统一设置为低电量；关闭时统一恢复为自动模式。
- UI 必须通过 Helper 重新读取 `pmset -g custom` 的真实结果后更新状态。
- 命令失败时显示错误并保持实际状态，不得仅依据请求值更新按钮。

### R5 — 合盖不睡眠

- 启用时执行固定操作 `pmset -a disablesleep 1`，关闭时执行 `pmset -a disablesleep 0`。
- UI 必须根据 `pmset -g` 返回的 `SleepDisabled` 真实状态更新。
- 首次启用前必须明确警告：合盖运行可能增加耗电和温度，用户应确保通风。
- Helper 首次接管合盖睡眠时必须记录原始 `SleepDisabled` 值；卸载前仅在 Helper 曾接管该设置时恢复原值，不得覆盖用户已有配置。

## Acceptance Criteria

- [ ] 快捷区域在 304×640pt 弹窗中完整显示，图标和间距明显小于 v0.2.0。
- [ ] Apple 快捷指令均显示有效图标，不再出现空圆。
- [ ] 打包应用包含 Helper 可执行文件和 `Contents/Library/LaunchDaemons` plist。
- [ ] Helper 注册状态与 `SMAppService.Status` 一致，等待批准时提供系统设置入口。
- [ ] 未批准 Helper 时两个特权动作不报告成功。
- [ ] Helper 批准后，低电量模式能够启用、关闭并回读真实状态。
- [ ] Helper 批准后，合盖不睡眠能够启用、关闭并回读 `SleepDisabled`。
- [ ] 非 TouchMacer 客户端无法调用 Helper XPC 接口。
- [ ] 卸载 Helper 会恢复其接管前的 `SleepDisabled` 值；从未接管时保持现状。
- [ ] 现有快捷动作、设置排序、更多窗口、日历和宜忌区域不回归。

## Out of Scope

- 任意 root Shell、AppleScript 或文件操作接口。
- 绕过 macOS 管理员批准。
- 自动启用合盖不睡眠。
- 本轮自动发布新 GitHub Release。
