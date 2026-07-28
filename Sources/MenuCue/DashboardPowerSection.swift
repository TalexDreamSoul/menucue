import SwiftUI

/// Power on the Dashboard, where there is room to answer in sentences.
///
/// The popover's Power tab is a dense readout in 360pt. This is the surface that
/// leads with the answer — what woke the Mac, and what is stopping it sleeping —
/// because those are the two questions people actually ask.
struct DashboardPowerSection: View {
  @ObservedObject var model: AppModel
  @ObservedObject var diagnostics: PowerDiagnosticsService
  @ObservedObject var energy: ProcessEnergyService

  var body: some View {
    let snapshot = diagnostics.snapshot

    VStack(spacing: DashboardMetrics.cardSpacing) {
      latestWakeCard(snapshot)
      sleepBlockersCard(snapshot)
      keepsRunningCard
      wakeHistoryCard(snapshot)
    }
    .onAppear {
      diagnostics.retain()
      // Looking at this is the opt-in. From here on history keeps accruing with the
      // window closed, which is the only way an overnight wake can be explained.
      model.enablePowerMonitoring()
    }
    .onDisappear { diagnostics.release() }
  }

  // MARK: - What woke it

  @ViewBuilder
  private func latestWakeCard(_ snapshot: PowerDiagnosticsSnapshot) -> some View {
    DashboardCard(
      title: L10n.string("Last Wake"), systemImage: "sunrise", tint: .orange
    ) {
      if let refreshed = snapshot.refreshedAt {
        Text(refreshed, style: .relative)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    } content: {
      if let latest = snapshot.latestWake {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            L10n.format(
              "Your Mac last woke at %@",
              latest.event.timestamp.formatted(date: .omitted, time: .shortened))
          )
          .font(.title3.weight(.semibold))
          Text(latest.cause.sentence)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          // The raw token stays available but secondary: it is what the system
          // recorded, and hiding it would make an unrecognized cause unverifiable.
          if case let .interrupt(token, _) = latest.cause, token != latest.cause.sentence {
            Text(token)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .textSelection(.enabled)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if snapshot.errorMessage != nil {
        UnsupportedNote(message: L10n.string("Wake history could not be read."))
      } else {
        UnsupportedNote(message: L10n.string("No wake has been recorded yet."))
      }
    }
  }

  // MARK: - What is holding it awake

  @ViewBuilder
  private func sleepBlockersCard(_ snapshot: PowerDiagnosticsSnapshot) -> some View {
    DashboardCard(
      title: L10n.string("Keeping Your Mac Awake"), systemImage: "eye", tint: .yellow
    ) {
      let blockers = snapshot.sleepBlockers
      if blockers.isEmpty {
        UnsupportedNote(message: L10n.string("Nothing is preventing sleep."))
      } else {
        VStack(spacing: 10) {
          ForEach(blockers) { assertion in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(assertion.process)
                    .font(.callout.weight(.semibold))
                  if assertion.isOwned(byPID: model.quickActionService.keepAwakePID) {
                    Text(ProductBrand.displayName)
                      .font(.caption2)
                      .foregroundStyle(.yellow)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(Color.yellow.opacity(0.16), in: Capsule())
                  }
                }
                // pmset's own sentence when it has one, the assertion's name otherwise.
                Text(assertion.localized ?? assertion.reason)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer(minLength: 8)
              Text(assertion.heldDescription)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(durationTint(assertion.heldSeconds))
            }
          }
        }
      }
    }
  }

  /// A few minutes is ordinary; a process that has held sleep off for hours is the
  /// thing worth noticing.
  private func durationTint(_ seconds: Int) -> Color {
    switch seconds {
    case ..<1_800: return .secondary
    case ..<14_400: return .orange
    default: return .red
    }
  }

  // MARK: - What keeps running

  /// Persistence, not the instantaneous readout.
  ///
  /// The live figure is a one-second `top` sample, which answers "what is hot right
  /// now". A daemon that wakes every 30 seconds reads 0.0 in almost every such sample
  /// and can still be the reason the fans are on — so this ranks by how much of the
  /// window a process was present for.
  @ViewBuilder
  private var keepsRunningCard: some View {
    DashboardCard(
      title: L10n.string("Keeps Running"), systemImage: "repeat", tint: .indigo
    ) {
      if let started = energy.history.windowStart {
        Text(started, style: .relative)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    } content: {
      let top = energy.history.topByPersistence(limit: 8)
      if top.isEmpty {
        UnsupportedNote(message: L10n.string("Not enough samples yet."))
      } else {
        let samples = energy.history.totalSamples
        VStack(spacing: 8) {
          ForEach(top) { record in
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 8) {
                Text(record.name)
                  .font(.callout.weight(.semibold))
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer(minLength: 8)
                // The percent sign is formatted into the value rather than living in
                // the key: `%%` adjacent to text is fragile, and percent formatting is
                // a locale decision anyway.
                Text(
                  L10n.format(
                    "%@ of the time",
                    SystemMetricsFormatter.percent(record.presence(inWindowOf: samples)))
                )
                  .font(.callout.weight(.medium))
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
              }
              MetricBar(
                fraction: record.presence(inWindowOf: samples), tint: .indigo, height: 5)
              // Average and peak together: an average alone hides a spike, and a peak
              // alone makes an idle process look busy.
              Text(
                L10n.format(
                  "avg %@ · peak %@",
                  String(format: "%.1f", record.averageImpact),
                  String(format: "%.1f", record.peakImpact))
              )
              .font(.caption)
              .foregroundStyle(.tertiary)
            }
          }
        }
      }
    }
  }

  // MARK: - History

  @ViewBuilder
  private func wakeHistoryCard(_ snapshot: PowerDiagnosticsSnapshot) -> some View {
    DashboardCard(
      title: L10n.string("Recent Wakes"), systemImage: "clock.arrow.circlepath", tint: .orange
    ) {
      // States what is being kept and what it costs, rather than leaving the user to
      // wonder how much of their disk this quietly occupies.
      Text(
        L10n.format(
          "last 30 days · %@",
          SystemMetricsFormatter.capacity(diagnostics.historyFileSizeBytes))
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
    } content: {
      if diagnostics.migrationDroppedRecords > 0 {
        UnsupportedNote(
          message: L10n.format(
            "%d earlier records were removed: they described wakes that had been scheduled, not wakes that happened.",
            diagnostics.migrationDroppedRecords))
      }
      let wakes = snapshot.events.filter { $0.kind != .sleep }.suffix(20).reversed()
      if wakes.isEmpty {
        UnsupportedNote(message: L10n.string("No wake has been recorded yet."))
      } else {
        VStack(spacing: 8) {
          ForEach(Array(wakes)) { event in
            // Same helper the popover uses, so the two surfaces cannot word the same
            // event differently.
            let sentence = PowerAttributionParser.sentence(
              for: event, scheduled: snapshot.scheduledWakes)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
              Text(sentence)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 6)
              Text(kindLabel(event.kind))
                .font(.caption2)
                .foregroundStyle(kindTint(event.kind))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(kindTint(event.kind).opacity(0.14), in: Capsule())
            }
          }
        }
      }
    }
  }

  private func kindLabel(_ kind: WakeEventKind) -> String {
    switch kind {
    case .sleep: return L10n.string("Sleep")
    case .darkWake: return L10n.string("Dark Wake")
    case .wake: return L10n.string("User Wake")
    }
  }

  private func kindTint(_ kind: WakeEventKind) -> Color {
    switch kind {
    case .sleep: return .secondary
    case .darkWake: return .purple
    case .wake: return .green
    }
  }
}
