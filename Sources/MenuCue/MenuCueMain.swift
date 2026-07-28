import AppKit
import Foundation

@main
struct MenuCueMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = SettingsStore()
        let calendarService = CalendarService()
        let appearanceService = AppearanceService()
        let model = AppModel(
            settingsStore: settingsStore,
            calendarService: calendarService,
            appearanceService: appearanceService
        )
        let updateService = UpdateService(engine: SparkleUpdateEngine())
        let languageService = AppLanguageService()
        statusBarController = StatusBarController(
            model: model,
            updateService: updateService,
            languageService: languageService
        )
        if ProcessInfo.processInfo.environment["MENUCUE_SWIPE_LOG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.statusBarController?.debugShowPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController = nil
    }
}
