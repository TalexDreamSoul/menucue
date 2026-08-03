import SwiftUI

// MARK: - Storage

struct DashboardStorageSection: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var dashboard: DashboardMetricsService

  private var throughputSeries: [ChartSeries] {
    [
      ChartSeries(
        label: L10n.string("Read"), values: dashboard.diskReadHistory.values, color: .teal),
      ChartSeries(
        label: L10n.string("Write"), values: dashboard.diskWriteHistory.values, color: .indigo),
    ]
  }

  var body: some View {
    VStack(spacing: DashboardMetrics.cardSpacing) {
      DashboardCard(
        title: L10n.string("Throughput"), systemImage: "arrow.up.arrow.down", tint: .teal
      ) {
        SeriesChart(
          series: throughputSeries,
          capacity: dashboard.diskReadHistory.capacity
        )
        .frame(height: DashboardMetrics.chartHeight)
        ChartLegend(series: throughputSeries, format: SystemMetricsFormatter.rate)
      }

      DashboardCard(title: L10n.string("Activity"), systemImage: "waveform.path", tint: .teal) {
        if let io = dashboard.snapshot.diskIO {
          VStack(spacing: 10) {
            HStack(spacing: 12) {
              StatTile(
                title: L10n.string("Read IOPS"),
                value: operations(io.readOperationsPerSecond), tint: .teal)
              StatTile(
                title: L10n.string("Write IOPS"),
                value: operations(io.writeOperationsPerSecond), tint: .indigo)
            }
            Divider().opacity(0.4)
            DataRow(
              label: L10n.string("Read since boot"),
              value: SystemMetricsFormatter.capacity(io.totalBytesRead))
            DataRow(
              label: L10n.string("Written since boot"),
              value: SystemMetricsFormatter.capacity(io.totalBytesWritten))
          }
        } else {
          UnsupportedNote(message: L10n.string("No block device counters reported."))
        }
      }

      DashboardCard(title: L10n.string("Volumes"), systemImage: "internaldrive", tint: .teal) {
        Text(L10n.format("%d mounted", dashboard.snapshot.volumes.count))
          .font(.caption)
          .foregroundStyle(.tertiary)
      } content: {
        let volumes = dashboard.snapshot.volumes
        if volumes.isEmpty {
          UnsupportedNote(message: L10n.string("No browsable volumes reported."))
        } else {
          VStack(spacing: 14) {
            ForEach(volumes) { volume in
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                  Text(volume.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                  Text(volume.format)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                  if volume.isInternal {
                    Text(L10n.string("Internal"))
                      .font(.caption2)
                      .foregroundStyle(.teal)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(Color.teal.opacity(0.14), in: Capsule())
                  }
                  Spacer(minLength: 6)
                  Text(SystemMetricsFormatter.percent(volume.fraction))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                MetricBar(fraction: volume.fraction, tint: .teal, height: 7)
                HStack(spacing: 12) {
                  Text(
                    L10n.format("%@ used", SystemMetricsFormatter.capacity(volume.used))
                  )
                  Text(
                    L10n.format("%@ free", SystemMetricsFormatter.capacity(volume.free))
                  )
                  Text(
                    L10n.format("%@ total", SystemMetricsFormatter.capacity(volume.total))
                  )
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
              }
            }
          }
        }
      }
    }
  }

  private func operations(_ value: Double) -> String {
    value < 1 ? "0" : String(format: "%.0f", value)
  }
}

// MARK: - Network

struct DashboardNetworkSection: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var dashboard: DashboardMetricsService

  private var trafficSeries: [ChartSeries] {
    [
      ChartSeries(
        label: L10n.string("Download"), values: dashboard.downloadHistory.values, color: .blue),
      ChartSeries(
        label: L10n.string("Upload"), values: dashboard.uploadHistory.values, color: .green),
    ]
  }

  var body: some View {
    let network = metrics.snapshot.network

    VStack(spacing: DashboardMetrics.cardSpacing) {
      DashboardCard(title: L10n.string("Traffic"), systemImage: "globe", tint: .blue) {
        if let interface = network.interfaceName {
          Text(interface)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      } content: {
        HStack(spacing: 12) {
          StatTile(
            title: L10n.string("Download"),
            value: SystemMetricsFormatter.rate(network.downloadBytesPerSecond), tint: .blue)
          StatTile(
            title: L10n.string("Upload"),
            value: SystemMetricsFormatter.rate(network.uploadBytesPerSecond), tint: .green)
        }
        SeriesChart(series: trafficSeries, capacity: dashboard.downloadHistory.capacity)
          .frame(height: DashboardMetrics.chartHeight)
        ChartLegend(series: trafficSeries, format: SystemMetricsFormatter.rate)
      }

      DashboardCard(
        title: L10n.string("Interfaces"), systemImage: "network", tint: .blue
      ) {
        Text(L10n.format("%d active", dashboard.snapshot.interfaces.count))
          .font(.caption)
          .foregroundStyle(.tertiary)
      } content: {
        let interfaces = dashboard.snapshot.interfaces
        if interfaces.isEmpty {
          UnsupportedNote(message: L10n.string("No active interfaces reported."))
        } else {
          VStack(spacing: 12) {
            ForEach(interfaces) { interface in
              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                  Text(interface.name)
                    .font(.callout.weight(.semibold))
                  if interface.name == network.interfaceName {
                    Text(L10n.string("Primary"))
                      .font(.caption2)
                      .foregroundStyle(.blue)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(Color.blue.opacity(0.14), in: Capsule())
                  }
                  Spacer(minLength: 6)
                  if let address = interface.ipv4Address {
                    Text(address)
                      .font(.callout.weight(.medium))
                      .foregroundStyle(.blue)
                      .textSelection(.enabled)
                  }
                }
                if let mac = interface.macAddress {
                  DataRow(label: L10n.string("Hardware address"), value: mac)
                }
                // Rates, not totals: the kernel's per-interface octet counters are
                // 32-bit and wrap every 4.29 GB, so a "since boot" figure would be
                // wrong within a day. Differences across two reads stay correct.
                DataRow(
                  label: L10n.string("Download"),
                  value: interface.downloadBytesPerSecond.map(SystemMetricsFormatter.rate) ?? "—")
                DataRow(
                  label: L10n.string("Upload"),
                  value: interface.uploadBytesPerSecond.map(SystemMetricsFormatter.rate) ?? "—")
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - Sensors

struct DashboardSensorsSection: View {
  @ObservedObject var metrics: SystemMetricsService
  @ObservedObject var dashboard: DashboardMetricsService

  var body: some View {
    let fans = metrics.snapshot.fans

    VStack(spacing: DashboardMetrics.cardSpacing) {
      DashboardCard(title: L10n.string("Cooling"), systemImage: "fanblades", tint: .cyan) {
        if !fans.isEmpty {
          Text(L10n.format("%d fans", fans.count))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      } content: {
        if fans.isEmpty {
          // Fanless Macs (MacBook Air, M-series Mac mini) report no tachometers.
          UnsupportedNote(message: L10n.string("This Mac has no fans."))
        } else {
          VStack(spacing: 16) {
            ForEach(fans) { fan in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(L10n.format("Fan %d", fan.index + 1))
                    .font(.callout.weight(.semibold))
                  Spacer(minLength: 8)
                  Text(L10n.format("%d RPM", Int(fan.currentRPM)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .menuCueNumericTransition(value: fan.currentRPM)
                }
                if fan.maxRPM > fan.minRPM {
                  MetricBar(fraction: fan.loadFraction, tint: .cyan, height: 7)
                  Text(L10n.format("%d–%d RPM", Int(fan.minRPM), Int(fan.maxRPM)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                if let history = dashboard.fanHistory[fan.index], history.values.count > 1 {
                  SeriesChart(
                    series: [
                      ChartSeries(
                        label: L10n.format("Fan %d", fan.index + 1),
                        values: history.values,
                        color: .cyan)
                    ],
                    capacity: history.capacity,
                    // Bounded by the tachometer ceiling so two fans with different
                    // ranges stay visually comparable.
                    upperBound: fan.maxRPM > 0 ? fan.maxRPM : nil
                  )
                  .frame(height: 70)
                }
              }
            }
          }
        }
      }

      DashboardCard(
        title: L10n.string("Temperature Sensors"), systemImage: "thermometer.medium", tint: .red
      ) {
        let readings = dashboard.snapshot.thermals
        if readings.isEmpty {
          UnsupportedNote(message: L10n.string("No temperature sensors reported."))
        } else {
          VStack(spacing: 9) {
            ForEach(readings) { reading in
              VStack(alignment: .leading, spacing: 4) {
                DataRow(
                  label: reading.label,
                  value: SystemMetricsFormatter.temperature(reading.celsius),
                  valueColor: DashboardPalette.temperature(reading.celsius))
                // 110 °C is the throttling ceiling on Apple silicon; the bar is a
                // proportion of that, not of an arbitrary maximum.
                MetricBar(
                  fraction: min(1, reading.celsius / 110),
                  tint: DashboardPalette.temperature(reading.celsius),
                  height: 4)
              }
            }
          }
        }
      }
    }
  }
}
