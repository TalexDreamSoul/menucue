import Foundation
import Testing
@testable import MenuCue

struct ProductBrandTests {
  @Test func displayNameUsesMenuCueBrand() {
    #expect(ProductBrand.displayName == "MenuCue")
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
    #expect(!packageManifest.contains(legacyProductName))
    #expect(!buildScript.contains(legacyProductName))
    #expect(!updateScript.contains(legacyProductName))
    #expect(!updateScript.contains(legacySlug))
    #expect(!updateScript.contains(legacyCompactName))
  }
}
