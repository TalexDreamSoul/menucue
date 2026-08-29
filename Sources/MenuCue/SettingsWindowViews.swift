import AppKit
import SwiftUI

/// Sidebar grouping for the settings window: three runs of panes, each under a small
/// header, the way System Settings separates unrelated families of preferences.
enum SettingsPaneGroup: String, CaseIterable, Identifiable {
  case interface
  case input
  case system

  var id: String { rawValue }

  var title: String {
    switch self {
    // "Interface" alone is already spoken for by the network-interface row in the
    // metric detail panel, and a .strings catalog is one key to one translation.
    case .interface: return L10n.string("User Interface")
    case .input: return L10n.string("Input")
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
  case actionCenter
  case trackpad
  case hotkeys
  case alerts
  case power
  case general
  case about

  var id: String { rawValue }

  var group: SettingsPaneGroup {
    switch self {
    case .menuBar, .panel, .calendar, .actionCenter: return .interface
    case .trackpad, .hotkeys, .alerts: return .input
    case .power, .general, .about: return .system
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
    case "dateAndTime": return .menuBar
    case "quickActions": return .actionCenter
    case "notifications": return .alerts
    case "appearance", "iCloud", "language": return .general
    default: return SettingsPane(rawValue: rawValue)
    }
  }

  var title: String {
    switch self {
    case .menuBar: return L10n.string("Menu Bar")
    case .panel: return L10n.string("Panel")
    case .calendar: return L10n.string("Calendar")
    case .actionCenter: return L10n.string("Action Center")
    case .trackpad: return L10n.string("Trackpad")
    // Not "Shortcuts": that key already names Apple's Shortcuts app in the action
    // catalog, and one key cannot hold two translations.
    case .hotkeys: return L10n.string("Keyboard Shortcuts")
    case .alerts: return L10n.string("Alerts")
    case .power: return L10n.string("Power")
    case .general: return L10n.string("General")
    case .about: return L10n.string("About")
    }
  }

  var subtitle: String {
    switch self {
    case .menuBar:
      return L10n.string("Menu-bar clock format, the clock carousel, and time zones.")
    case .panel:
      return L10n.string("Popover tab order, sampling behavior, and animation effects.")
    case .calendar:
      return L10n.string("Event sources, month-view layout, and calendar access.")
    case .actionCenter:
      return L10n.string("Every action MenuCue can run, and where it appears.")
    case .trackpad:
      return L10n.string("Build gesture rules from live touch input and run actions on this Mac.")
    case .hotkeys:
      return L10n.string("Global keyboard shortcuts that run any action on this Mac.")
    case .alerts:
      return L10n.string("External channels, system alert rules, and message templates.")
    case .power:
      return L10n.string("Power Helper, system power settings, and wake history.")
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
    case .actionCenter: return "square.grid.2x2"
    case .trackpad: return "hand.tap"
    case .hotkeys: return "keyboard"
    case .alerts: return "bell.badge"
    case .power: return "bolt"
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
      VStack(alignment: .leading, spacing: 22) {
        SettingsPaneHeader(pane: pane)
        selectedPaneContent
      }
      .padding(28)
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
    case .actionCenter:
      ActionCenterSettingsView(model: model)
    case .trackpad:
      TrackpadSettingsView(model: model)
    case .hotkeys:
      HotkeySettingsView(model: model)
    case .alerts:
      NotificationSettingsView(model: model)
    case .power:
      PowerSettingsView(model: model)
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

private struct SettingsPaneHeader: View {
  let pane: SettingsPane

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(pane.title, systemImage: pane.systemImage)
        .font(.title2.weight(.semibold))
      Text(pane.subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SettingsGroup<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      content
    }
    .frame(maxWidth: 560, alignment: .leading)
  }
}

/// About pane: what this build is and where it came from. Launch at Login and the
/// update controls that used to live here now belong to General.
struct AboutSettingsView: View {
  var body: some View {
    SettingsGroup(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(ProductBrand.displayName)
          .font(.title2.weight(.semibold))
        Text(L10n.format("Version %@", appVersion))
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("Links")
          .font(.headline)
        HStack(spacing: 10) {
          Button("GitHub Repository") {
            SettingsLinkOpener.open("https://github.com/TalexDreamSoul/menucue")
          }
          Button("Release Notes") {
            SettingsLinkOpener.open("https://github.com/TalexDreamSoul/menucue/releases")
          }
        }
      }
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.4"
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

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(TimeZoneCatalog.identifiers, id: \.self) { identifier in
        Text(TimeZoneCatalog.displayName(for: identifier)).tag(identifier)
      }
    }
  }
}
