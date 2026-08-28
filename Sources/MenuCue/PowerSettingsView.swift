import SwiftUI

/// Power settings for this Mac. Stage A only carries over Power Helper management,
/// which five other features depend on and which used to sit at the bottom of Quick
/// Actions; the pmset switches, the monitoring toggle and wake-history retention join
/// it in Stage B.
struct PowerSettingsView: View {
  @Environment(\.menuCueMotion) private var motion
  @ObservedObject var model: AppModel
  @ObservedObject private var service: QuickActionService
  @ObservedObject private var powerHelper: PowerHelperManager
  @State private var helperFeedback: String?

  init(model: AppModel) {
    self.model = model
    self.service = model.quickActionService
    self.powerHelper = model.quickActionService.powerHelperManager
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      powerHelperSection(isProminent: powerHelper.registrationState.needsProminentRemediation)
    }
    .onAppear {
      service.refreshAll()
    }
  }

  private func powerHelperSection(isProminent: Bool) -> some View {
    SettingsGroup(spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: powerHelper.registrationState.isEnabled
            ? "checkmark.shield.fill"
            : isProminent ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"
        )
        .font(.title3)
        .foregroundStyle(powerHelper.registrationState.isEnabled ? Color.green : Color.orange)
        .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text("Power Helper")
              .font(.headline)
            Spacer()
            Text(powerHelper.registrationState.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(powerHelper.registrationState.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "Low Power Mode applies to battery and adapter power. Don't Sleep When Closed can increase heat and battery use."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let helperFeedback {
        Text(helperFeedback)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .transition(motion.revealTransition(edge: .top))
      }

      HStack {
        Spacer()
        helperActionButton
      }
    }
    .padding(isProminent ? 14 : 0)
    .background(
      isProminent ? Color.orange.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(isProminent ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
    }
    .animation(motion.stateAnimation, value: powerHelper.registrationState)
  }

  @ViewBuilder
  private var helperActionButton: some View {
    switch powerHelper.registrationState {
    case .enabled:
      Button("Remove Helper", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .requiresApproval:
      Button("Open System Settings") {
        powerHelper.openSystemSettings()
      }
      .buttonStyle(.borderedProminent)
      Button("Cancel Install", role: .destructive, action: removePowerHelper)
        .disabled(powerHelper.isWorking)
    case .refreshRequired:
      Button("Refresh Helper") {
        helperFeedback = nil
        powerHelper.refreshHelperRegistration()
      }
      .buttonStyle(.borderedProminent)
      .disabled(powerHelper.isWorking)
    case .unavailable:
      Button("Install Helper") {}
        .buttonStyle(.borderedProminent)
        .disabled(true)
    case .notRegistered, .failed:
      Button("Install Helper") {
        helperFeedback = nil
        powerHelper.requestRegistration()
      }
      .buttonStyle(.borderedProminent)
      .disabled(powerHelper.isWorking)
    }
  }

  private func removePowerHelper() {
    powerHelper.removeHelper { result in
      switch result {
      case .success:
        helperFeedback = L10n.string("Power Helper removed.")
      case .failure(let error):
        helperFeedback = L10n.format(
          "Could not remove Power Helper: %@",
          error.localizedDescription
        )
      }
      service.refreshAll()
    }
  }
}
