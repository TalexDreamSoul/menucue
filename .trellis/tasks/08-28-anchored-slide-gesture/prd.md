# 锚定滑动手势：按住 + 单指滑动连续调节

## 背景

用户需求（2026-08-28）：「两根手指都放着，当第一根（左边）的手指上下滑动时，也可以进行调节。」即：N 指按住，其中所选一指沿轴向滑动 → 连续调节（音量/亮度等），其余手指锚定。这是统一识别器架构后的第一个全新手势族，触点应验证「新增一族 ≤6 处」的承诺。

## Requirements

### R1. 新手势族 anchoredSlide（锚定滑动）
- 触发参数：手指数 N（2–4，默认 2）、所选滑动指（按落点从左到右序号，默认第 1 指）、滑动轴向（垂直默认 / 水平可选）；锚定指位移受 movementTolerance 约束（复用现有字段）。
- 连续语义与 edgeContinuous 对齐：位移量化步进（minimumDistance / 全局灵敏度）、冷却 0.035、单帧步数上限 4、方向反转即时响应；动作族支持 continuousVolume / continuousBrightness（及通用动作按步触发）。
- 识别器自声明：`suppression = .scrollWheel`（活跃期间抑制系统滚动——注意现有 TrackpadEdgeScrollSuppressionPolicy 是边缘几何特化的，本族需要按「活跃连续会话」驱动的抑制路径，推广现有 edgeGestureOwned 机制，不要再写几何镜像谓词）、`freezesPointer = true`（与边缘族同理由，复用冻结协调器）。

### R2. 与 tipTap 共存（同为「按住+另一指」场景）
- 滑动位移超出 tipTap 判定容差自然不构成点按；需测试：同设备同时启用 tipTap 与 anchoredSlide 规则时，点按只触发 tipTap、滑动只触发 anchoredSlide，互不误触、互不吞会话。

### R3. 配置与预设
- 胖联合体新增字段带默认值，旧 JSON 解码兼容（加解码测试）。
- 预设列表新增「双指按住 · 左指滑动 → 音量」（仅影响重置预设/全新安装；现有用户经「添加规则」自建）。
- 规则编辑弹窗 familyFields 分支：手指数 / 所选滑动指 / 轴向 三控件 + 阈值滑块复用；触发器徽标（如「2 指 · 左指滑动」）与 summary/title；en/zh 双语。

## Acceptance Criteria
- [ ] build/test 全绿；`--filter Trackpad` 全绿；LocalizationCoverage + verify-localizations 通过。
- [ ] 新识别器单测：基本滑动步进、反向、锚指位移取消、冷却防抖、会话结束恢复（含指针冻结成对——复用 PointerFreeze mock 断言路径）、与 tipTap 共存两向不误触、旧 JSON 兼容。
- [ ] 触点核算写入 notes.md：对照「6 触点」承诺逐一列出实际改动位置；若超出，说明原因。
- [ ] Engine/Service 零 per-kind 新分支（抑制推广与冻结走声明机制）。
