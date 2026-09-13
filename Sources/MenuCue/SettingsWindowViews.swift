import AppKit
import SwiftUI

/// Sidebar grouping for the settings window: four runs of panes, each under a small
/// header, the way System Settings separates unrelated families of preferences.
/// Group order and membership come from the v1.0.0 design document.
enum SettingsPaneGroup: String, CaseIterable, Identifiable {
  case display
  case interaction
  case alerts
  case system

  var id: String { rawValue }

  var title: String {
    switch self {
    // One key holds one translation, so a group never borrows the wording of the pane
    // it contains: "Alerts" is the pane, "Notifications" is the group that holds it.
    case .display: return L10n.string("Display")
    case .interaction: return L10n.string("Interaction and Actions")
    case .alerts: return L10n.string("Notifications")
    case .system: return L10n.string("System")
    }
  }

  var panes: [SettingsPane] {
    SettingsPane.allCases.filter { $0.group == self }
  }
}

enum SettingsPane: String, CaseIterable, Identifiable {
  case menuBar
  case panel
  case calendar
  case trackpad
  case hotkeys
  case actionCenter
  case alerts
  case power
  case timeZone
  case general
  case about

  var id: String { rawValue }

  var group: SettingsPaneGroup {
    switch self {
    case .menuBar, .panel, .calendar: return .display
    case .trackpad, .hotkeys, .actionCenter: return .interaction
    case .alerts: return .alerts
    case .power, .timeZone, .general, .about: return .system
    }
  }

  /// Maps a pane identifier written before the reorganization onto its new home, so an
  /// old deep link keeps landing on the pane that now owns the setting it pointed at.
  /// Returns nil when the destination is no longer a settings pane at all.
  static func migrating(rawValue: String) -> SettingsPane? {
    switch rawValue {
    // The Dashboard is read-only and has never held a setting; it is its own window
    // now, so `AppRouter.route(forIdentifier:)` sends that link to the window instead.
    case "dashboard": return nil
    case "overview": return .panel
    // The pane that owned "date and time" still owns the clock *format*; only its time
    // zones moved out, and those identifiers resolve below.
    case "dateAndTime": return .menuBar
    case "quickActions": return .actionCenter
    case "notifications": return .alerts
    case "timezone", "timeZone", "region", "timeAndRegion", "languageRegion": return .timeZone
    // The app's own language stayed in General; only the macOS language row moved.
    case "appearance", "iCloud", "language": return .general
    default: return SettingsPane(rawValue: rawValue)
    }
  }

  var title: String {
    switch self {
    case .menuBar: return L10n.string("Menu Bar")
    case .panel: return L10n.string("Panel")
    case .calendar: return L10n.string("Calendar")
    case .trackpad: return L10n.string("Trackpad")
    // Not "Shortcuts": that key already names Apple's Shortcuts app in the action
    // catalog, and one key cannot hold two translations.
    case .hotkeys: return L10n.string("Keyboard Shortcuts")
    case .actionCenter: return L10n.string("Action Library")
    case .alerts: return L10n.string("Alert Rules")
    case .power: return L10n.string("Power")
    case .timeZone: return L10n.string("Time & Region")
    case .general: return L10n.string("General")
    case .about: return L10n.string("About")
    }
  }

  var subtitle: String {
    switch self {
    case .menuBar:
      return L10n.string("Status-bar clock, its format, and the clock carousel.")
    case .panel:
      return L10n.string("Popover tab order, sampling behavior, and animation effects.")
    case .calendar:
      return L10n.string("Event sources, month-view layout, and calendar access.")
    case .trackpad:
      return L10n.string("Build gesture rules from live touch input and run actions on this Mac.")
    case .hotkeys:
      return L10n.string("Global keyboard shortcuts that run any action on this Mac.")
    case .actionCenter:
      return L10n.string("Every action MenuCue can run, where it appears, and what references it.")
    case .alerts:
      return L10n.string("External channels, system alert rules, and message templates.")
    case .power:
      return L10n.string("Power Helper, system power settings, and wake history.")
    case .timeZone:
      return L10n.string("MenuCue's display time zone, the macOS system time zone, and system language and region.")
    case .general:
      return L10n.string("Startup, updates, appearance, language, and iCloud sync.")
    case .about:
      return L10n.string("Version, GitHub releases, and project links.")
    }
  }

  var systemImage: String {
    switch self {
    case .menuBar: return "menubar.rectangle"
    case .panel: return "macwindow"
    case .calendar: return "calendar"
    case .trackpad: return "hand.tap"
    case .hotkeys: return "keyboard"
    case .actionCenter: return "square.grid.2x2"
    case .alerts: return "bell.badge"
    case .power: return "bolt"
    case .timeZone: return "globe"
    case .general: return "gearshape"
    case .about: return "info.circle"
    }
  }
}

struct SettingsWindowView: View {
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var model: AppModel
  @ObservedObject var updateService: UpdateService
  @ObservedObject var languageService: AppLanguageService
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NavigationSplitView {
      List(selection: $router.settingsPane) {
        ForEach(SettingsPaneGroup.allCases) { group in
          Section(group.title) {
            ForEach(group.panes) { pane in
              Label(pane.title, systemImage: pane.systemImage)
                .tag(pane)
            }
          }
        }
      }
      .listStyle(.sidebar)
      .navigationTitle(L10n.string("Settings"))
      .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
      // System Settings never offers to hide its sidebar; without this the split
      // view puts a lone toggle in an otherwise empty toolbar band.
      .menuCueHideSidebarToggle()
    } detail: {
      SettingsContentView(
        model: model,
        updateService: updateService,
        languageService: languageService,
        pane: router.settingsPane
      )
    }
    .navigationSplitViewStyle(.balanced)
    // All three of min/ideal/max are needed. `ideal` is what NSHostingController
    // reports as the window's fitting size — drop it and the controller asks for the
    // full height of the tallest pane's content (measured at 2736pt), which is how a
    // scroll view ends up laid out taller than the window with nothing to scroll.
    // `max` is what lets the split view follow the window when it is resized.
    .frame(
      minWidth: 720, idealWidth: 900, maxWidth: .infinity,
      minHeight: 540, idealHeight: 680, maxHeight: .infinity
    )
    .environment(\.menuCueMotion, motion)
  }

  private var motion: MotionProfile {
    MotionProfile(quality: model.settings.animationQuality, reducesMotion: reduceMotion)
  }
}

private struct SettingsContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var updateService: UpdateService
  @ObservedObject var languageService: AppLanguageService
  let pane: SettingsPane

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing * 1.5) {
        SettingsPaneHeader(
          pane.title,
          subtitle: pane.subtitle,
          systemImage: pane.systemImage
        )
        selectedPaneContent
      }
      .padding(24)
      .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var selectedPaneContent: some View {
    switch pane {
    case .menuBar:
      MenuBarSettingsView(model: model)
    case .panel:
      PanelSettingsView(model: model)
    case .calendar:
      CalendarSettingsView(model: model)
    case .trackpad:
      TrackpadSettingsView(model: model)
    case .hotkeys:
      HotkeySettingsView(model: model)
    case .actionCenter:
      ActionCenterSettingsView(model: model)
    case .alerts:
      NotificationSettingsView(model: model)
    case .power:
      PowerSettingsView(model: model)
    case .timeZone:
      TimeZoneSettingsView(model: model)
    case .general:
      GeneralSettingsView(
        model: model,
        updateService: updateService,
        languageService: languageService
      )
    case .about:
      AboutSettingsView()
    }
  }
}

/// About pane: what this build is and where it came from. Launch at Login and the
/// update controls that used to live here now belong to General.
struct AboutSettingsView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
      SettingsCard(ProductBrand.displayName) {
        SettingsRows {
          AboutBrandRow(version: L10n.format("Version %@", appVersion))
        }
      }

      SettingsCard(L10n.string("Links")) {
        SettingsRows {
          SettingsRowButton(
            L10n.string("Source and Issues"),
            buttonTitle: L10n.string("GitHub Repository"),
            kind: .link
          ) {
            SettingsLinkOpener.open(Self.repositoryURL)
          }
          SettingsRowButton(
            L10n.string("Changelog"),
            buttonTitle: L10n.string("Release Notes"),
            kind: .link
          ) {
            SettingsLinkOpener.open(Self.releaseNotesURL)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static let repositoryURL = "https://github.com/TalexDreamSoul/menucue"
  private static let releaseNotesURL = "https://github.com/TalexDreamSoul/menucue/releases"

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.4"
  }
}

/// The About pane's identity block: the installed build's own app icon beside its version.
///
/// `SettingsRow` is shaped for a label with a control opposite it, which this block is
/// not. Reusing the row's metrics and its card surface is what matters: the surface is
/// what occludes the separator layer `SettingsRows` paints behind every row, so a block
/// that skips it would punch a hairline-width hole through the card.
private struct AboutBrandRow: View {
  @Environment(\.settingsSurface) private var surface
  let version: String

  var body: some View {
    HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)

      Text(version)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, SettingsMetrics.rowPaddingH)
    .padding(.vertical, SettingsMetrics.rowPaddingV)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface)
  }
}

enum SettingsLinkOpener {
  static func open(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }
}

extension AppModel {
  /// Two-way binding onto one stored setting. Writes funnel through `updateSettings`
  /// so persistence and observers fire exactly as they do for every other write.
  func settingsBinding<Value>(
    _ keyPath: WritableKeyPath<AppSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { self.settings[keyPath: keyPath] },
      set: { newValue in
        self.updateSettings { settings in
          settings[keyPath: keyPath] = newValue
        }
      }
    )
  }
}

struct TimeZonePicker: View {
  let title: String
  @Binding var selection: String
  var identifiers: [String] = TimeZoneCatalog.identifiers

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(identifiers, id: \.self) { identifier in
        Text(TimeZoneCatalog.displayName(for: identifier)).tag(identifier)
      }
    }
  }
}
