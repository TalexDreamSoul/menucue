import AppKit
import Foundation

@main
struct TouchMacerMain {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController = nil
    }
}
