import XCTest
@testable import MenuCue

@MainActor
final class AppLanguageServiceTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "AppLanguageServiceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testSystemDefaultResolvesFirstSupportedPreferredLanguage() {
    XCTAssertEqual(
      AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR", "zh-Hans-CN", "en-US"]),
      "zh-Hans"
    )
    XCTAssertEqual(
      AppLanguage.system.resolvedIdentifier(preferredLanguages: ["de-DE"]),
      "en"
    )
    XCTAssertEqual(
      AppLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-Hans"]),
      "en"
    )
  }

  func testExplicitLanguagePersistsLocallyAndWritesAppOverride() {
    let relauncher = RelauncherStub(result: .success(()))
    let service = AppLanguageService(
      defaults: defaults,
      relauncher: relauncher,
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: {}
    )

    service.apply(.simplifiedChinese)

    XCTAssertEqual(service.selectedLanguage, .simplifiedChinese)
    XCTAssertEqual(defaults.string(forKey: AppLanguageService.selectionKey), "zh-Hans")
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
    XCTAssertEqual(relauncher.requestedURLs.count, 1)
  }

  func testSystemDefaultRemovesAppLanguageOverride() {
    defaults.set(["zh-Hans"], forKey: "AppleLanguages")
    defaults.set("zh-Hans", forKey: AppLanguageService.selectionKey)
    let service = AppLanguageService(
      defaults: defaults,
      relauncher: RelauncherStub(result: .success(())),
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: {}
    )

    service.apply(.system)

    XCTAssertNil(
      defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
    )
    XCTAssertEqual(defaults.string(forKey: AppLanguageService.selectionKey), "system")
  }

  func testExistingAppLanguageOverrideIsMigratedWithoutBeingDeleted() {
    defaults.set(["fr-FR", "zh-Hans-CN"], forKey: "AppleLanguages")

    let service = AppLanguageService(
      defaults: defaults,
      relauncher: RelauncherStub(result: .success(())),
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: {}
    )

    XCTAssertEqual(service.selectedLanguage, .simplifiedChinese)
    XCTAssertEqual(
      defaults.stringArray(forKey: "AppleLanguages"),
      ["fr-FR", "zh-Hans-CN"]
    )
    XCTAssertEqual(defaults.string(forKey: AppLanguageService.selectionKey), "zh-Hans")
  }

  func testUnsupportedStoredSelectionNormalizesToSystemDefault() {
    defaults.set("fr", forKey: AppLanguageService.selectionKey)

    let service = AppLanguageService(
      defaults: defaults,
      relauncher: RelauncherStub(result: .success(())),
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: {}
    )

    XCTAssertEqual(service.selectedLanguage, .system)
    XCTAssertEqual(defaults.string(forKey: AppLanguageService.selectionKey), "system")
  }

  func testRelaunchFailureRollsBackDefaultsAndKeepsProcessAlive() {
    defaults.set("en", forKey: AppLanguageService.selectionKey)
    defaults.set(["en"], forKey: "AppleLanguages")
    var didTerminate = false
    let service = AppLanguageService(
      defaults: defaults,
      relauncher: RelauncherStub(result: .failure(TestError.relaunchFailed)),
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: { didTerminate = true }
    )

    service.apply(.simplifiedChinese)

    XCTAssertEqual(service.selectedLanguage, .english)
    XCTAssertEqual(defaults.string(forKey: AppLanguageService.selectionKey), "en")
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    XCTAssertFalse(didTerminate)
    XCTAssertNotNil(service.errorMessage)
  }

  func testRelaunchFailureRestoresOriginalOverrideExactly() {
    defaults.set("en", forKey: AppLanguageService.selectionKey)
    defaults.set(["en-US", "en"], forKey: "AppleLanguages")
    let service = AppLanguageService(
      defaults: defaults,
      relauncher: RelauncherStub(result: .failure(TestError.relaunchFailed)),
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: {}
    )

    service.apply(.simplifiedChinese)

    XCTAssertEqual(defaults.string(forKey: AppLanguageService.selectionKey), "en")
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en-US", "en"])
  }

  func testSuccessfulRelaunchTerminatesOldProcessOnlyAfterRequestSucceeds() {
    var didTerminate = false
    let service = AppLanguageService(
      defaults: defaults,
      relauncher: RelauncherStub(result: .success(())),
      bundleURL: URL(fileURLWithPath: "/Applications/MenuCue.app"),
      persistentDomainName: suiteName,
      terminator: { didTerminate = true }
    )

    service.apply(.english)

    XCTAssertTrue(didTerminate)
  }
}

@MainActor
private final class RelauncherStub: AppRelaunching {
  private let result: Result<Void, Error>
  private(set) var requestedURLs: [URL] = []

  init(result: Result<Void, Error>) {
    self.result = result
  }

  func relaunch(
    bundleURL: URL,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    requestedURLs.append(bundleURL)
    completion(result)
  }
}

private enum TestError: Error {
  case relaunchFailed
}
