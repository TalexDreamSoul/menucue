import SwiftUI

// MARK: - CPU

struct DashboardCPUSection: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var dashboard: DashboardMetricsService

  private static let userColor = Color.accentColor
  private static let systemColor = Color.orange

  var body: some View {
    let snapshot = metrics.snapshot

    VStack(spacing: DashboardMetrics.cardSpacing) {
      DashboardCard(title: L10n.string("Processor"), systemImage: "cpu", tint: Self.userColor) {
        if let temperature = snapshot.cpuTemperature {
          Text(SystemMetricsFormatter.temperature(temperature))
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DashboardPalette.temperature(temperature))
            .contentTransition(.numericText())
        }
      } content: {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(metrics.hardware.chipName)
              .font(.system(size: 15, weight: .semibold))
            if !metrics.hardware.coreSummary.isEmpty {
              Text(metrics.hardware.coreSummary)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            }
          }
          Spacer(minLength: 12)
          Text(SystemMetricsFormatter.percent(snapshot.cpu.busy))
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
        }

        CPUUsageChart(
          samples: metrics.cpuHistory,
          capacity: metrics.historyCapacity,
          userColor: Self.userColor,
          systemColor: Self.systemColor
        )
        .frame(height: DashboardMetrics.chartHeight)

        HStack(spacing: 0) {
          LegendItem(
            color: Self.userColor, label: L10n.string("User"),
            value: SystemMetricsFormatter.percent(snapshot.cpu.userBand))
          Spacer(minLength: 8)
          LegendItem(
            color: Self.systemColor, label: L10n.string("System"),
            value: SystemMetricsFormatter.percent(snapshot.cpu.systemBand))
          Spacer(minLength: 8)
          LegendItem(
            color: .secondary.opacity(0.4), label: L10n.string("Idle"),
            value: SystemMetricsFormatter.percent(snapshot.cpu.idle))
        }
      }

      Grid(
        horizontalSpacing: DashboardMetrics.cardSpacing,
        verticalSpacing: DashboardMetrics.cardSpacing
      ) {
        GridRow {
          coresCard
          loadAverageCard
        }
      }

      thermalCard
    }
  }

  private var coresCard: some View {
    DashboardCard(
      title: L10n.string("Per-Core Load"), systemImage: "square.grid.3x3", tint: .accentColor
    ) {
      Text(L10n.format("%d cores", dashboard.snapshot.perCoreLoad.count))
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    } content: {
      if dashboard.snapshot.perCoreLoad.isEmpty {
        UnsupportedNote(message: L10n.string("Sampling cores…"))
      } else {
        VStack(spacing: 5) {
          ForEach(dashboard.snapshot.perCoreLoad) { core in
            HStack(spacing: 8) {
              Text(coreLabel(core))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
              MetricBar(fraction: core.busy, tint: DashboardPalette.load(core.busy), height: 6)
              Text(SystemMetricsFormatter.percent(core.busy))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
            }
          }
        }
      }
    }
  }

  /// Cores are numbered within their cluster, which is how every Mac tool presents
  /// them; a bare global index says nothing about which cluster is under load.
  private func coreLabel(_ core: CoreLoad) -> String {
    let cores = dashboard.snapshot.perCoreLoad
    let position = cores.prefix(core.index).filter { $0.cluster == core.cluster }.count + 1
    switch core.cluster {
    case .performance: return L10n.format("P%d", position)
    case .efficiency: return L10n.format("E%d", position)
    case .unspecified: return L10n.format("Core %d", core.index + 1)
    }
  }

  private var loadAverageCard: some View {
    DashboardCard(
      title: L10n.string("Load Average"), systemImage: "chart.bar.doc.horizontal", tint: .orange
    ) {
      if let load = dashboard.snapshot.loadAverage {
        VStack(spacing: 10) {
          HStack(spacing: 12) {
            StatTile(title: L10n.string("1 min"), value: format(load.one), tint: .orange)
            StatTile(title: L10n.string("5 min"), value: format(load.five), tint: .orange)
            StatTile(title: L10n.string("15 min"), value: format(load.fifteen), tint: .orange)
          }
          Divider().opacity(0.4)
          DataRow(
            label: L10n.string("Logical cores"),
            value: "\(metrics.hardware.logicalCores)")
          Text(L10n.string("Runnable threads averaged over each window. Above the core count means work is queued."))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        UnsupportedNote(message: L10n.string("Load average unavailable."))
      }
    }
  }

  private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private var thermalCard: some View {
    DashboardCard(
      title: L10n.string("Cluster Temperatures"), systemImage: "thermometer.medium", tint: .red
    ) {
      let readings = dashboard.snapshot.thermals
      if readings.isEmpty {
        UnsupportedNote(message: L10n.string("No temperature sensors reported."))
      } else {
        VStack(spacing: 7) {
          ForEach(readings) { reading in
            DataRow(
              label: reading.label,
              value: SystemMetricsFormatter.temperature(reading.celsius),
              valueColor: DashboardPalette.temperature(reading.celsius))
          }
        }
      }
    }
  }
}

// MARK: - GPU

struct DashboardGPUSection: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var dashboard: DashboardMetricsService

  var body: some View {
    let gpu = dashboard.snapshot.gpu

    VStack(spacing: DashboardMetrics.cardSpacing) {
      DashboardCard(
        title: L10n.string("Graphics"), systemImage: "cube.transparent", tint: .green
      ) {
        if let temperature = gpuTemperature {
          Text(SystemMetricsFormatter.temperature(temperature))
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DashboardPalette.temperature(temperature))
            .contentTransition(.numericText())
        }
      } content: {
        if gpu.isEmpty {
          UnsupportedNote(message: L10n.string("This Mac reports no GPU performance counters."))
        } else {
          HStack(alignment: .firstTextBaseline) {
            // On Apple silicon the GPU is part of the SoC, so the chip name is the
            // honest identifier — there is no public API for a GPU core count.
            Text(metrics.hardware.chipName)
              .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 12)
            if let utilization = gpu.deviceUtilization {
              Text(SystemMetricsFormatter.percent(utilization))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            }
          }

          SeriesChart(
            series: [
              ChartSeries(
                label: L10n.string("Device"),
                values: dashboard.gpuHistory.values,
                color: .green)
            ],
            capacity: dashboard.gpuHistory.capacity,
            upperBound: 1
          )
          .frame(height: DashboardMetrics.chartHeight)
        }
      }

      DashboardCard(title: L10n.string("Details"), systemImage: "list.bullet", tint: .green) {
        if gpu.isEmpty {
          UnsupportedNote(message: L10n.string("No readings available."))
        } else {
          VStack(spacing: 7) {
            if let device = gpu.deviceUtilization {
              DataRow(
                label: L10n.string("Device utilization"),
                value: SystemMetricsFormatter.percent(device))
              MetricBar(fraction: device, tint: .green, height: 6)
            }
            if let renderer = gpu.rendererUtilization {
              DataRow(
                label: L10n.string("Renderer utilization"),
                value: SystemMetricsFormatter.percent(renderer))
            } else {
              DataRow(label: L10n.string("Renderer utilization"), value: "—")
            }
            if let memory = gpu.inUseMemory {
              DataRow(
                label: L10n.string("Graphics memory in use"),
                value: SystemMetricsFormatter.capacity(memory))
            } else {
              DataRow(label: L10n.string("Graphics memory in use"), value: "—")
            }
            DataRow(
              label: L10n.string("Temperature"),
              value: gpuTemperature.map(SystemMetricsFormatter.temperature) ?? "—",
              valueColor: gpuTemperature.map(DashboardPalette.temperature) ?? .primary)
          }
        }
      }
    }
  }

  /// Matched on `kind`, not on `label` — the label is localized for display.
  private var gpuTemperature: Double? {
    dashboard.snapshot.thermals.first { $0.kind == .gpu }?.celsius
  }
}

// MARK: - Memory

struct DashboardMemorySection: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var dashboard: DashboardMetricsService

  var body: some View {
    let memory = metrics.snapshot.memory

    VStack(spacing: DashboardMetrics.cardSpacing) {
      DashboardCard(title: L10n.string("Physical Memory"), systemImage: "memorychip", tint: .purple) {
        if let pressure = dashboard.snapshot.memoryPressure {
          Text(pressure.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(pressureColor(pressure))
        }
      } content: {
        HStack(alignment: .firstTextBaseline) {
          Text(SystemMetricsFormatter.capacity(memory.used))
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
          Text(L10n.format("of %@", SystemMetricsFormatter.capacity(memory.total)))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
          Spacer(minLength: 12)
          Text(SystemMetricsFormatter.percent(memory.fraction))
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        MetricBar(fraction: memory.fraction, tint: .purple, height: 10)

        HStack(spacing: 12) {
          StatTile(
            title: L10n.string("App"), value: SystemMetricsFormatter.capacity(memory.appMemory),
            tint: .purple)
          StatTile(
            title: L10n.string("Wired"), value: SystemMetricsFormatter.capacity(memory.wired),
            tint: .purple)
          StatTile(
            title: L10n.string("Compressed"),
            value: SystemMetricsFormatter.capacity(memory.compressed), tint: .purple)
          StatTile(
            title: L10n.string("Cached"), value: SystemMetricsFormatter.capacity(memory.cached),
            tint: .secondary)
        }
      }

      DashboardCard(title: L10n.string("Swap"), systemImage: "arrow.left.arrow.right", tint: .pink) {
        if let swap = dashboard.snapshot.swap {
          if swap.isInUse {
            VStack(spacing: 8) {
              MetricBar(fraction: swap.fraction, tint: .pink, height: 8)
              DataRow(
                label: L10n.string("Used"), value: SystemMetricsFormatter.capacity(swap.used))
              DataRow(
                label: L10n.string("Total"), value: SystemMetricsFormatter.capacity(swap.total))
              DataRow(
                label: L10n.string("Encrypted"),
                value: swap.isEncrypted ? L10n.string("Yes") : L10n.string("No"))
            }
          } else {
            UnsupportedNote(message: L10n.string("Swap is not in use."))
          }
        } else {
          UnsupportedNote(message: L10n.string("Swap usage unavailable."))
        }
      }

      DashboardCard(
        title: L10n.string("Top Processes"), systemImage: "list.number", tint: .purple
      ) {
        let processes = dashboard.snapshot.topProcesses
        if processes.isEmpty {
          UnsupportedNote(message: L10n.string("No readable processes."))
        } else {
          let peak = processes.first?.residentBytes ?? 1
          VStack(spacing: 8) {
            ForEach(processes) { process in
              VStack(alignment: .leading, spacing: 3) {
                DataRow(
                  label: process.name,
                  value: SystemMetricsFormatter.capacity(process.residentBytes))
                MetricBar(
                  fraction: peak == 0 ? 0 : Double(process.residentBytes) / Double(peak),
                  tint: .purple,
                  height: 4)
              }
            }
          }
        }
      }
    }
  }

  private func pressureColor(_ level: MemoryPressureLevel) -> Color {
    switch level {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
    }
  }
}
