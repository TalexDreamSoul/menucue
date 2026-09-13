import AppKit
import SwiftUI

/// Time & Region — the v1.0.0 design document's one new pane (pane M).
///
/// Three things that used to be scattered now sit together: MenuCue's own display time
/// zone (whose editor lived in the Menu Bar pane), the macOS system time zone (which lived
/// at the bottom of that same pane), and the Mac's language and region (which lived inside
/// General).
///
/// MenuCue's own app language deliberately stays in General: it never changes macOS, so
/// it is not a system-wide setting.
struct TimeZoneSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var displayTimeZoneSearch = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      SettingsBanner(
        L10n.string("These settings change this Mac"),
        desc: L10n.string("The system time zone is written through Power Helper and affects every app and system service."),
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )

      displayTimeZoneCard
      systemTimeZoneCard
      systemLanguageCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The stored value is `overviewTimeZoneID`; the first carousel clock is only its
  /// fallback, so the picker is the setting and the chip documents the fallback chain.
  private var displayTimeZoneCard: some View {
    SettingsCard(
      L10n.string("MenuCue Display Time Zone"),
      desc: L10n.string("Affects dates and times inside MenuCue only; it never changes macOS.")
    ) {
      SettingsRows {
        SettingsRow(
          L10n.string("Display Time Zone"),
          desc: L10n.string("Dates and times inside MenuCue use this zone."),
          controlWidth: 240
        ) {
          VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.string("Search time zones"), text: $displayTimeZoneSearch)
              .textFieldStyle(.roundedBorder)
            TimeZonePicker(
              title: "",
              selection: model.settingsBinding(\.overviewTimeZoneID),
              identifiers: displayTimeZoneIdentifiers
            )
            .labelsHidden()
          }
          .frame(width: 240, alignment: .leading)
        }
        SettingsRow(
          L10n.string("Fallback Rule"),
          desc: L10n.string("If that zone is unavailable, MenuCue falls back to the first clock in the carousel, then to this Mac's zone.")
        ) {
          SettingsChip(L10n.string("Automatic"))
        }
      }
    }
  }

  private var displayTimeZoneIdentifiers: [String] {
    TimeZoneCatalog.identifiers(
      matching: displayTimeZoneSearch,
      including: model.settings.overviewTimeZoneID
    )
  }

  private var systemTimeZoneCard: some View {
    SettingsCard(
      L10n.string("macOS System Time Zone"),
      desc: L10n.string("Changes the time zone for all apps and system services on this Mac.")
    ) {
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
