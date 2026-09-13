import Foundation
import XCTest

@testable import MenuCue

/// The data-entry picker filters the canonical catalog as the user types. These tests hold
/// the two rules that keep the binding honest while filtering: a query matches an identifier
/// or the text the user actually sees, and the current value stays selectable even when the
/// query no longer matches it. An unknown value must never be invented.
final class TimeZoneCatalogSearchTests: XCTestCase {
  func testQueryMatchesTheIdentifierItself() {
    let results = TimeZoneCatalog.identifiers(matching: "Asia/Tokyo", including: "")

    XCTAssertEqual(
      results, ["Asia/Tokyo"],
      "the raw identifier is searchable even though the displayed text spells the city differently"
    )
  }

  func testQueryMatchesTheDisplayedTextThatTheIdentifierCannot() {
    // "America/Los_Angeles" has an underscore, so only the picker's displayed
    // "Los Angeles" text can make this query match.
    let results = TimeZoneCatalog.identifiers(matching: "Los Angeles", including: "")

    XCTAssertEqual(
      results, ["America/Los_Angeles"],
      "filtering by display text must find the zone whose identifier spells the city with an underscore"
    )
  }

  func testSearchKeepsTheCurrentSelectionSelectableWhenTheQueryExcludesIt() {
    let results = TimeZoneCatalog.identifiers(matching: "London", including: "Asia/Tokyo")

    XCTAssertEqual(
      results.first, "Asia/Tokyo",
      "the current binding must stay selectable while the user types a query that excludes it"
    )
    XCTAssertEqual(
      results.filter { $0 == "Asia/Tokyo" }.count, 1,
      "keeping the selection must not duplicate it"
    )
    XCTAssertTrue(results.contains("Europe/London"), "the matched zone is still offered")
    XCTAssertFalse(results.contains("America/New_York"), "the query still filters the rest of the list")
  }

  func testAQueryThatAlreadyMatchesTheSelectionDoesNotDuplicateIt() {
    let results = TimeZoneCatalog.identifiers(matching: "Tokyo", including: "Asia/Tokyo")

    XCTAssertEqual(
      results.filter { $0 == "Asia/Tokyo" }.count, 1,
      "a selection the query already matches is not prepended a second time"
    )
  }

  func testUnknownSelectionIsNeverInventedIntoTheCatalog() {
    let unknown = "Not/AZone"
    XCTAssertFalse(TimeZoneCatalog.identifiers.contains(unknown))

    let filtered = TimeZoneCatalog.identifiers(matching: "zzzz", including: unknown)
    XCTAssertTrue(filtered.isEmpty, "an unknown value cannot survive as a phantom match")

    let unfiltered = TimeZoneCatalog.identifiers(matching: "", including: unknown)
    XCTAssertEqual(
      unfiltered, TimeZoneCatalog.identifiers,
      "an unknown value cannot be smuggled into the unfiltered picker"
    )
  }
}
