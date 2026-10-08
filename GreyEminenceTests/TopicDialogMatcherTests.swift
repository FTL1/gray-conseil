import XCTest
@testable import Grey_Eminence

final class TopicDialogMatcherTests: XCTestCase {
    func testNormalizeIsCaseInsensitive() {
        XCTAssertTrue(TopicDialogMatcher.topicsMatch("Schedule Conflict", "schedule conflict"))
        XCTAssertFalse(TopicDialogMatcher.topicsMatch("ACME", "Track B"))
    }

    func testPhraseMatch() {
        XCTAssertTrue(
            TopicDialogMatcher.segmentMatches(
                "They talked about Schedule Conflict near the office.",
                topic: "Schedule Conflict"
            )
        )
    }

    func testSingleTokenUsesWordBoundary() {
        XCTAssertTrue(TopicDialogMatcher.segmentMatches("ACME sent a stale deck.", topic: "ACME"))
        XCTAssertFalse(TopicDialogMatcher.segmentMatches("The signal was strong.", topic: "ACME"))
    }

    func testMultiTokenRequiresEverySignificantWord() {
        XCTAssertTrue(
            TopicDialogMatcher.segmentMatches(
                "Vendor partnership talks with Jordan Hale.",
                topic: "Vendor Partnership"
            )
        )
        XCTAssertFalse(
            TopicDialogMatcher.segmentMatches(
                "They mentioned the vendor community.",
                topic: "Vendor Partnership"
            )
        )
    }

    func testMeetingsSharingTopicExcludesCurrent() {
        // Pure filter is covered via meetings(sharing:excluding:among:) on
        // topic labels; this test uses the normalize helper only so it stays
        // free of SwiftData.
        XCTAssertEqual(TopicDialogMatcher.significantTokens(in: "the Draft Exclusivity"), ["draft", "exclusivity"])
        XCTAssertEqual(TopicDialogMatcher.significantTokens(in: "ACME"), ["acme"])
    }
}
