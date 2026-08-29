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
    private var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = SettingsStore()
        let calendarService = CalendarService()
        let appearanceService = AppearanceService()
        let runtimeStore: NotificationRuntimeStore
        let runtimeErrorMessage: String?
        do {
            runtimeStore = try NotificationRuntimeStore.applicationStore()
            runtimeErrorMessage = nil
        } catch {
            let message = L10n.string(
                "Notification history could not be opened. Existing pending messages were preserved."
            )
            runtimeStore = NotificationRuntimeStore.unavailable(reason: message)
            runtimeErrorMessage = message
        }
        let model = AppModel(
            settingsStore: settingsStore,
            calendarService: calendarService,
            appearanceService: appearanceService,
            notificationRuntimeStore: runtimeStore,
            notificationRuntimeErrorMessage: runtimeErrorMessage,
            notificationSecretStore: KeychainNotificationSecretStore()
        )
        appModel = model
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
        appModel?.trackpadGestureService.stop()
        // A hot key survives the object that asked for it, so quitting has to hand every
        // combination back rather than leave it claimed by a process that is gone.
        appModel?.hotkeyService.stop()
        statusBarController = nil
        appModel = nil
    }
}
