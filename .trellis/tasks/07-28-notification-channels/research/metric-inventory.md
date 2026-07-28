# Alert metric inventory

## Inclusion rule

The first release exposes every current value that is:

1. time-varying and user-visible in MenuCue;
2. scalar or ordered categorical;
3. obtainable with a stable target identity and truthful unit;
4. meaningful as a threshold/state incident with alert and recovery semantics.

Static capacities/hardware facts, formatting-only derivatives, monotonic lifetime counters, dynamic ranked entities, lists, and configuration values are inventoried but excluded with reasons. “All metrics” in product/UI copy means all entries marked Included below, not every stored field in every model.

## Included catalog

| Stable metric ID | Source | Value / unit | Target | Operators | Cost |
|---|---|---|---|---|---|
| `cpu.total.busy` | `CPULoadSample.busy` | percent | system | above/below | cheap counter |
| `cpu.total.user` | `CPULoadSample.userBand` | percent | system | above/below | cheap counter |
| `cpu.total.system` | `CPULoadSample.systemBand` | percent | system | above/below | cheap counter |
| `cpu.total.idle` | `CPULoadSample.idle` | percent | system | above/below | cheap counter |
| `cpu.core.busy` | `CoreLoad.busy` | percent | logical core index | above/below | medium counter |
| `cpu.load.1m` | `LoadAverage.one` | runnable threads | system | above/below | cheap sysctl |
| `cpu.load.5m` | `LoadAverage.five` | runnable threads | system | above/below | cheap sysctl |
| `cpu.load.15m` | `LoadAverage.fifteen` | runnable threads | system | above/below | cheap sysctl |
| `gpu.device.utilization` | `GPUStats.deviceUtilization` | percent | busiest accelerator | above/below | expensive IOKit |
| `gpu.renderer.utilization` | `GPUStats.rendererUtilization` | percent | busiest accelerator | above/below | expensive IOKit |
| `gpu.memory.inUse` | `GPUStats.inUseMemory` | bytes | busiest accelerator | above/below | expensive IOKit |
| `memory.used` | `MemoryUsage.used` | bytes | system | above/below | cheap host stats |
| `memory.used.percent` | `MemoryUsage.fraction` | percent | system | above/below | cheap host stats |
| `memory.app` | `MemoryUsage.appMemory` | bytes | system | above/below | cheap host stats |
| `memory.wired` | `MemoryUsage.wired` | bytes | system | above/below | cheap host stats |
| `memory.compressed` | `MemoryUsage.compressed` | bytes | system | above/below | cheap host stats |
| `memory.cached` | `MemoryUsage.cached` | bytes | system | above/below | cheap host stats |
| `memory.pressure` | `MemoryPressureLevel` | normal/warning/critical | system | reaches/at-least/at-most | cheap sysctl |
| `swap.used` | `SwapUsage.used` | bytes | system | above/below | medium sysctl |
| `swap.used.percent` | `SwapUsage.fraction` | percent | system | above/below | medium sysctl |
| `storage.volume.used` | `VolumeUsage.used` / `DiskUsage.used` | bytes | stable volume path | above/below | medium filesystem |
| `storage.volume.free` | `VolumeUsage.free` | bytes | stable volume path | above/below | medium filesystem |
| `storage.volume.usedPercent` | `VolumeUsage.fraction` / `DiskUsage.fraction` | percent | stable volume path | above/below | medium filesystem |
| `disk.read.rate` | `DiskUsage.readBytesPerSecond` | bytes/second | aggregate | above/below | cheap counter |
| `disk.write.rate` | `DiskUsage.writeBytesPerSecond` | bytes/second | aggregate | above/below | cheap counter |
| `disk.read.operations` | `DiskIORates.readOperationsPerSecond` | operations/second | aggregate | above/below | medium IOKit |
| `disk.write.operations` | `DiskIORates.writeOperationsPerSecond` | operations/second | aggregate | above/below | medium IOKit |
| `network.download.rate` | `NetworkUsage.downloadBytesPerSecond` | bytes/second | aggregate/primary | above/below | cheap counter |
| `network.upload.rate` | `NetworkUsage.uploadBytesPerSecond` | bytes/second | aggregate/primary | above/below | cheap counter |
| `network.interface.downloadRate` | `NetworkInterfaceInfo.downloadBytesPerSecond` | bytes/second | BSD interface name | above/below | medium route data |
| `network.interface.uploadRate` | `NetworkInterfaceInfo.uploadBytesPerSecond` | bytes/second | BSD interface name | above/below | medium route data |
| `sensor.cpu.temperature` | `SystemMetricsSnapshot.cpuTemperature` | degrees Celsius | aggregate CPU | above/below | medium sensor |
| `sensor.thermal.temperature` | `ThermalReading.celsius` | degrees Celsius | new nonlocalized sensor ID | above/below | expensive sensor |
| `fan.speed` | `FanReading.currentRPM` | RPM | fan index | above/below | medium SMC |
| `fan.load` | `FanReading.loadFraction` | percent | fan index | above/below | medium SMC |
| `battery.level` | `BatteryStatus.percentage` | percent | internal battery | above/below | cheap IOPowerSources |
| `battery.timeRemaining` | `BatteryStatus.timeRemainingMinutes` | minutes | internal battery | above/below | cheap IOPowerSources |
| `battery.flow.watts` | `BatteryFlow.watts` | watts (signed) | internal battery | above/below | cheap IOPowerSources/IORegistry |
| `battery.flow.percentPerHour` | `BatteryFlow.percentPerHour` | percent/hour (signed) | internal battery | above/below | cheap IOPowerSources/IORegistry |
| `battery.charging` | `BatteryStatus.isCharging` | boolean | internal battery | is/is-not | cheap IOPowerSources |
| `power.onAC` | `BatteryStatus.isOnAC` | boolean | system | is/is-not | cheap IOPowerSources |
| `event.darkWake` | `WakeEvent(kind: .darkWake)` | event occurrence | system | occurs | expensive history reconciliation |

## Prerequisite target-identity change

`ThermalReading.id` currently returns the localized `label`, which is not stable across language changes and cannot distinguish multiple `.other` sensors. Before thermal rules ship, add a nonlocalized `sensorID` sourced from the HID cluster identifier or Intel SMC key. Keep `label` display-only. Add migration behavior that marks any unknown/legacy target unavailable rather than guessing.

Fan index, logical core index, BSD interface name, and mounted-volume path are the existing stable target identifiers. Target disappearance makes a rule unavailable; it does not retarget automatically.

## Excluded inventory

| Source/value | Reason excluded from generic rule catalog |
|---|---|
| `CPULoadSample.nice` raw field | UI intentionally presents `userBand = user + nice`; exposing raw nice would contradict displayed semantics. |
| Memory/disk/swap `total` capacity | Static denominator/hardware capacity, not an incident signal. It remains available as a template context variable for related rules. |
| Fan min/max RPM | Static capability bounds; available as template context for a fan rule. |
| `DiskIORates.totalBytesRead/totalBytesWritten` | Monotonic since-boot counters; a fixed threshold would alert once forever and reset on boot. Rate metrics carry operational meaning. |
| Interface raw counters | Documented 32-bit wrapping values and never displayed as absolute totals. |
| `WakeStatistics` and `WakeDailySummary` counts | Monotonic/aggregate windows with reboot/day semantics; dark-wake source events provide exact deduplication and incident identity. |
| Battery source/charging unknown (`nil`) | Availability state, not a value. Boolean rules evaluate only known values. |
| Power profiles/settings | User/system configuration, not observed load/health metrics. |
| Sleep assertions/scheduled wakes/wake-history rows | Typed lists/events requiring identity-specific rule designs. Dark wake is separately supported. |
| Process memory/energy/detail values | Dynamic ranked process identities; generic target persistence would be unsafe across process exit/PID reuse. Future process rules must use `ProcessIdentity`. |
| Hardware info, IP/MAC address, filesystem format/name | Static identity/context, not threshold metrics. Suitable template variables where relevant. |
| Chart histories | Derived presentation buffers, not independent observations. Rules consume source samples directly. |

## Completeness gate

Add one table-driven test whose expected IDs are a literal set matching every Included row. A code review adding a new user-visible time-varying scalar to the source models must either add a catalog ID/test or add an explicit exclusion here with rationale. This prevents the catalog from defining its own incomplete notion of “all”.
