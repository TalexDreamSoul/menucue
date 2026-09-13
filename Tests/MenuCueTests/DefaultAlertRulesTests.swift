import XCTest

@testable import MenuCue

/// `DefaultAlertRules.systemNotifications()` is the monitoring a brand-new install starts
/// with, before the user has configured anything. These tests pin the reviewed first-run
/// contract: exactly the five conservative rules, all enabled, all on the native channel,
/// with the two rules whose meaning lives in their target or trigger still carrying it.
final class DefaultAlertRulesTests: XCTestCase {
  func testFirstRunRulesAreTheReviewedConservativesAllEnabledOnTheSystemChannel() {
    let rules = DefaultAlertRules.systemNotifications()

    XCTAssertEqual(rules.count, 5, "a first run starts from exactly the reviewed rule set")
    XCTAssertEqual(
      Set(rules.map { $0.metricID.rawValue }),
      [
        "cpu.total.busy",
        "memory.pressure",
        "swap.used.percent",
        "storage.volume.usedPercent",
        "event.darkWake",
      ]
    )
    XCTAssertTrue(rules.allSatisfy(\.isEnabled), "every default rule ships enabled")
    for rule in rules {
      XCTAssertEqual(
        rule.channels, [.system],
        "\(rule.metricID.rawValue) must not route first-run alerts to a channel the user never configured"
      )
    }
  }

  func testRootVolumeRuleWatchesTheRootVolumeAndDarkWakeIsEventBased() throws {
    let rules = DefaultAlertRules.systemNotifications()

    let rootVolume = try XCTUnwrap(
      rules.first { $0.metricID.rawValue == "storage.volume.usedPercent" }
    )
    XCTAssertEqual(
      rootVolume.targetID, "/",
      "usage has to be sampled on the root volume rather than an arbitrary mount"
    )

    let darkWake = try XCTUnwrap(rules.first { $0.metricID.rawValue == "event.darkWake" })
    XCTAssertEqual(
      darkWake.condition, .event,
      "a dark wake is an occurrence to report, not a level to compare"
    )
  }
}
