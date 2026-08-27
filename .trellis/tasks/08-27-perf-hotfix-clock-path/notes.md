# 任务收尾记录（2026-08-27）

## 结果

- implement.md 12 步全部完成；trellis-check 8 项核验通过 + 4 处自修（NSTextAttachment 身份约束双向注释、DateCapsuleCache 容量 8→32 并注明与时钟数关系、NotificationRuntimeStore 裁剪策略注释、statusTitle 内联字典提 static）。
- `swift build` 通过；`swift test` 503 用例 0 失败 1 跳过（副屏环境门控，既有）+ swift-testing 5 用例通过；verify-localizations 1157 键通过。
- 新增测试：DateCapsuleCacheTests ×2、NotificationRuntimeStoreTests 保留策略 ×3。

## 关键约束（后续改动者必读）

- **R1+R3c 耦合**：applyStatusTitle 的同值跳过依赖 DateCapsuleCache 返回同一 NSTextAttachment 实例（无 isEqual 重写）。缓存改成返回等价副本会静默关掉跳过优化。代码内已有双向注释。
- NotificationRuntimeStore 裁剪按时间新旧，待投递旧事件可能被更新事件挤出（有意取舍，代码有注释）。

## 遗留 / 后续候选

1. `AppSettings.clockTimeZones`（AppModels.swift:210）计算属性每次访问重建数组并急切求值 4 个派生字段，1Hz 路径每 tick 触达 ≥2 次。缓存需要双源失效设计（clockEntries + 系统时区），本任务未做。
2. 设置窗口 `isReleasedWhenClosed=false` 关闭不销毁 → SwiftUI onDisappear 可能不触发的门控盲区（触控板 30Hz 预览、既有指标 retain/release 一视同仁受影响；既有问题非本次引入）。已挂到子任务 4（导航层）的执行清单：windowWillClose 统一拆除。
3. `TimeZoneCatalog.statusTitle` 字典已顺手提 static（check 自修，属 R3a 精神范围）。
