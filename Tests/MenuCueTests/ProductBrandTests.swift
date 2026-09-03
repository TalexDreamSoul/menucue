import Foundation
import Testing
@testable import MenuCue

struct ProductBrandTests {
  @Test func displayNameUsesMenuCueBrand() {
    #expect(ProductBrand.displayName == "MenuCue")
  }

  @Test func packagedHelperUsesManagedDaemonLayout() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let buildScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
      encoding: .utf8
    )
    let updateScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-update.sh"),
      encoding: .utf8
    )
    let daemonPlistURL = repositoryRoot.appendingPathComponent(
      "Resources/com.tagzxia.app.menucue.helper.plist")
    let daemonPlistData = try Data(contentsOf: daemonPlistURL)
    let daemonPlist = try #require(
      PropertyListSerialization.propertyList(from: daemonPlistData, format: nil)
        as? [String: Any]
    )
    let helperEntitlementsURL = repositoryRoot.appendingPathComponent(
      "Resources/MenuCueHelper.entitlements")
    let helperManager = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MenuCue/PowerHelperManager.swift"),
      encoding: .utf8
    )
    let helperMain = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/MenuCueHelper/main.swift"),
      encoding: .utf8
    )

    #expect(daemonPlist["Label"] as? String == "com.tagzxia.app.menucue.helper")
    #expect(daemonPlist["BundleProgram"] as? String == "Contents/MacOS/MenuCueHelper")
    #expect(
      (daemonPlist["MachServices"] as? [String: Bool])?["com.tagzxia.app.menucue.helper"]
        == true
    )
    #expect(
      daemonPlist["AssociatedBundleIdentifiers"] as? [String]
        == ["com.tagzxia.app.menucue"]
    )
    #expect(!FileManager.default.fileExists(atPath: helperEntitlementsURL.path))
    #expect(
      buildScript.contains(
        #"cp "$ROOT_DIR/.build/$BUILD_CONFIG/$HELPER_NAME" "$MACOS_DIR/$HELPER_NAME""#
      )
    )
    #expect(!buildScript.contains("MenuCueHelper.entitlements"))
    #expect(updateScript.contains(#"BUNDLE_PROGRAM="$(/usr/libexec/PlistBuddy"#))
    #expect(updateScript.contains("Unexpected LaunchDaemon Label"))
    #expect(updateScript.contains("Unexpected LaunchDaemon MachServices"))
    #expect(updateScript.contains("Unexpected LaunchDaemon AssociatedBundleIdentifiers"))
    #expect(updateScript.contains("Unexpected Helper signing identifier"))
    #expect(updateScript.contains("Helper carries a provisioning-profile entitlement"))
    #expect(updateScript.contains(#"HELPER_PATH="$APP_DIR/$BUNDLE_PROGRAM""#))
    #expect(helperManager.contains(#".appendingPathComponent("Contents/MacOS", isDirectory: true)"#))
    #expect(!buildScript.contains("HELPER_TOOLS_DIR"))
    #expect(!helperManager.contains("Contents/Library/HelperTools"))
    #expect(helperMain.contains("PowerHelperExecutableLocation.currentExecutableURL()"))
    #expect(!helperMain.contains("CommandLine.arguments[0]"))
  }

  @Test func deploymentTargetSupportsMacOSVentura() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let packageManifest = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )
    let buildScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
      encoding: .utf8
    )

    #expect(packageManifest.contains("platforms: [.macOS(.v13)]"))
    #expect(buildScript.contains("<string>13.0</string>"))
    #expect(!packageManifest.contains(".macOS(.v14)"))
    #expect(!buildScript.contains("<string>14.0</string>"))
  }

  @Test func localBuildSigningSelectsAppleDevelopmentAndRetainsAdHocOptOut() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let buildScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
      encoding: .utf8
    )

    #expect(buildScript.contains(#"if [[ -z "$CODESIGN_IDENTITY" ]]; then"#))
    #expect(buildScript.contains("security find-identity -v -p codesigning"))
    #expect(buildScript.contains("Apple Development: "))
    #expect(buildScript.contains(#"if [[ "$CODESIGN_IDENTITY" == "-" ]]; then"#))
    #expect(buildScript.contains("Using ad-hoc signing"))
  }

  @Test func releasePipelineRequiresDeveloperIDAndNotarization() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let buildScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
      encoding: .utf8
    )
    let updateScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-update.sh"),
      encoding: .utf8
    )

    #expect(buildScript.contains("Developer ID Application:"))
    #expect(buildScript.contains("ProvisionsAllDevices"))
    #expect(buildScript.contains("ProvisionedDevices"))
    #expect(buildScript.contains("com.apple.security.get-task-allow"))
    #expect(buildScript.contains("--options runtime"))
    #expect(buildScript.contains("--timestamp"))
    #expect(updateScript.contains("Developer ID Application: ZiXian Tang (2L5YC85FQ7)"))
    #expect(updateScript.contains("NOTARYTOOL_PROFILE"))
    #expect(updateScript.contains("NOTARIZATION_MAX_ATTEMPTS"))
    #expect(updateScript.contains("notarytool submit"))
    #expect(updateScript.contains("stapler staple"))
    #expect(updateScript.contains("stapler validate"))
    #expect(updateScript.contains("spctl --assess"))
  }

  @Test func packagingUsesMenuCueTechnicalIdentity() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let packageManifest = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )
    let buildScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
      encoding: .utf8
    )
    let updateScript = try String(
      contentsOf: repositoryRoot.appendingPathComponent("scripts/build-update.sh"),
      encoding: .utf8
    )

    let legacyProductName = ["Touch", "Macer"].joined()
    let legacySlug = ["touch", "macer"].joined(separator: "-")
    let legacyCompactName = ["touch", "macer"].joined()

    #expect(packageManifest.contains(#"name: "MenuCue""#))
    #expect(packageManifest.contains(#"name: "MenuCueHelper""#))
    #expect(packageManifest.contains(#"name: "MenuCueHelperProtocol""#))
    #expect(buildScript.contains(#"APP_NAME="MenuCue""#))
    #expect(buildScript.contains(#"HELPER_NAME="MenuCueHelper""#))
    #expect(buildScript.contains(#"BUNDLE_IDENTIFIER="com.tagzxia.app.menucue""#))
    #expect(
      buildScript.contains(
        #"HELPER_BUNDLE_IDENTIFIER="com.tagzxia.app.menucue.helper""#
      )
    )
    #expect(updateScript.contains("TalexDreamSoul/menucue"))
    #expect(updateScript.contains("embedded.provisionprofile"))
    #expect(updateScript.contains("com.apple.developer.ubiquity-kvstore-identifier"))
    #expect(!packageManifest.contains(legacyProductName))
    #expect(!buildScript.contains(legacyProductName))
    #expect(!updateScript.contains(legacyProductName))
    #expect(!updateScript.contains(legacySlug))
    #expect(!updateScript.contains(legacyCompactName))
  }
}
