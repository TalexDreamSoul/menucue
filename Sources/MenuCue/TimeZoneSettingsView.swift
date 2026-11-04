import AppKit
import SwiftUI

/// Time & Region — the v1.0.0 design document's one new pane (pane M).
///
/// Three things that used to be scattered now sit together: MenuCue's anchor time
/// zone, the macOS system time zone, and the Mac's language and region.
///
/// MenuCue's own app language deliberately stays in General: it never changes macOS, so
/// it is not a system-wide setting.
struct TimeZoneSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var anchorTimeZoneSearch = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      anchorTimeZoneCard
      systemTimeZoneCard
      systemLanguageCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var anchorTimeZoneCard: some View {
    SettingsCard(
      L10n.string("Anchor Time"),
      desc: L10n.string("Reminders, calendar dates, and automatic appearance share this time zone. It never changes the macOS time zone.")
    ) {
      SettingsRows {
        SettingsRow(
          L10n.string("Anchor Time"),
          desc: L10n.string("Choose the time zone used throughout MenuCue."),
          controlWidth: 240
        ) {
          VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.string("Search time zones"), text: $anchorTimeZoneSearch)
              .textFieldStyle(.roundedBorder)
            TimeZonePicker(
              title: "",
              selection: model.settingsBinding(\.anchorTimeZoneID),
              identifiers: anchorTimeZoneIdentifiers
            )
            .labelsHidden()
          }
          .frame(width: 240, alignment: .leading)
        }
        SettingsRow(
          L10n.string("Fallback Rule"),
          desc: L10n.string("If the anchor time zone is unavailable, MenuCue uses this Mac's time zone directly. World clocks do not affect the fallback.")
        ) {
          SettingsChip(L10n.string("This Mac"))
        }
      }
      if model.settings.isAnchorTimeZoneUnavailable {
        SettingsBanner(
          L10n.string("Anchor time zone unavailable"),
          desc: L10n.string("MenuCue is using this Mac's time zone. Choose an available anchor time zone to restore your preferred schedule."),
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange
        )
      }
    }
  }

  private var anchorTimeZoneIdentifiers: [String] {
    TimeZoneCatalog.identifiers(
      matching: anchorTimeZoneSearch,
      including: model.settings.anchorTimeZoneID
    )
  }

  private var systemTimeZoneCard: some View {
    SettingsCard(
      L10n.string("macOS System Time Zone"),
      desc: L10n.string("Changes the time zone for all apps and system services on this Mac.")
    ) {
      SettingsBanner(
        L10n.string("This setting changes macOS"),
        desc: L10n.string("The system time zone is written through Power Helper and affects every app and system service."),
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )
      SystemTimeZoneSettingsView(powerHelper: model.quickActionService.powerHelperManager)
    }
  }

  private var systemLanguageCard: some View {
    SettingsCard(
      L10n.string("macOS Language and Region"),
      desc: L10n.string("System-wide values. MenuCue links to System Settings instead of duplicating them.")
    ) {
      SettingsRows {
        SettingsRow(
          L10n.string("System Language"),
          desc: L10n.string("Decides the default language of macOS and of the apps that follow it.")
        ) {
          SettingsChip(SystemLanguageRegionSummary.languageName)
        }
        SettingsRow(
          L10n.string("Region"),
          desc: L10n.string("Decides date, number, and currency formats.")
        ) {
          SettingsChip(SystemLanguageRegionSummary.regionName)
        }
        SettingsRowButton(
          L10n.string("More Settings"),
          desc: L10n.string("MenuCue does not reimplement macOS language and region controls."),
          buttonTitle: L10n.string("Open System Settings"),
          kind: .secondary
        ) {
          NSWorkspace.shared.open(LanguageRegionLinks.systemLanguageSettings)
        }
      }
    }
  }

}

/// Reads the Mac's *system-wide* language and region.
///
/// Not `Locale.current`: MenuCue applies its own app language by writing `AppleLanguages`
/// into its own bundle domain, so the app's locale can differ from the system's. These
/// chips must report macOS, not MenuCue.
enum SystemLanguageRegionSummary {
  static var languageName: String {
    guard let identifier = globalLanguages?.first else {
      return Locale.current.localizedString(forIdentifier: Locale.current.identifier)
        ?? Locale.current.identifier
    }
    return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
  }

  static var regionName: String {
    guard let region = regionIdentifier else { return unavailable }
    return Locale.current.localizedString(forRegionCode: region) ?? region
  }

  private static let unavailable = "—"

  private static var globalDomain: [String: Any]? {
    UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")
  }

  private static var globalLanguages: [String]? {
    globalDomain?["AppleLanguages"] as? [String]
  }

  private static var regionIdentifier: String? {
    if let appleLocale = globalDomain?["AppleLocale"] as? String,
       let region = Locale(identifier: appleLocale).region?.identifier {
      return region
    }
    return Locale.current.region?.identifier
  }
}
