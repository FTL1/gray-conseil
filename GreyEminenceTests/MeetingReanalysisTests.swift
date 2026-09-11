import XCTest
import SwiftData
@testable import Grey_Eminence

@MainActor
final class MeetingReanalysisTests: XCTestCase {
    func testParseClockAndFocusFilter() {
        XCTAssertEqual(MeetingReanalysis.parseClock("1:30"), 90)
        XCTAssertEqual(MeetingReanalysis.parseClock("1:02:03"), 3723)
        XCTAssertEqual(MeetingReanalysis.clock(90), "1:30")
        let container = try! ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "Call")
        container.mainContext.insert(meeting)
        let early = TranscriptSegment(speaker: .me, text: "overview", startTime: 10, endTime: 20, isFinal: true)
        let late = TranscriptSegment(speaker: .me, text: "price", startTime: 400, endTime: 420, isFinal: true)
        early.meeting = meeting
        late.meeting = meeting
        meeting.segments.append(contentsOf: [early, late])
        meeting.analysisFocusStart = 300
        let focused = MeetingReanalysis.focusedSnapshots(in: meeting)
        XCTAssertEqual(focused.map(\.text), ["price"])
        let chunks = MeetingReanalysis.chunkSnapshots(focused, maxSpan: 60)
        XCTAssertEqual(chunks.count, 1)
    }

    func testExtractFactsPromptAsksForCommitmentsNotOverview() {
        let prompt = AIPromptTemplates.extractFactsPrompt(
            transcript: "UNIQUE_WINDOW",
            windowLabel: "the focused window 20:00–40:00",
            analysisGuidance: "Agree a delivery date."
        )
        XCTAssertTrue(prompt.contains("UNIQUE_WINDOW"))
        XCTAssertTrue(prompt.contains("commitments"))
        XCTAssertTrue(prompt.contains("Agree a delivery date."))
        XCTAssertFalse(prompt.lowercased().contains("json array of section objects"))
    }

    func testStrippingSuppressedSummaryDropsMatchingBullets() {
        let sections = [
            SummarySection(
                title: "Background",
                intro: nil,
                points: [
                    SummaryPoint(label: "Project overview", detail: "I described the whole project plan."),
                    SummaryPoint(label: "Scan quote", detail: "They can ship the sample this week."),
                ]
            )
        ]
        let raw = SummarySection.encode(sections)!
        let drop = MeetingReanalysis.summaryPointKey(sections[0].points[0])
        let stripped = MeetingReanalysis.strippingSuppressedSummary(raw, keys: [drop])
        let parsed = SummarySection.parse(stripped)!
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].points.map(\.label), ["Scan quote"])
    }

    func testNormalizeKeyCollapsesWhitespaceAndStripsTrailingPunctuation() {
        XCTAssertEqual(MeetingReanalysis.normalizeKey("  Hello,  World! "), "hello, world")
        XCTAssertEqual(MeetingReanalysis.normalizeKey("Follow-up?"), "follow-up")
        XCTAssertEqual(MeetingReanalysis.normalizeKey("same   KEY."), "same key")
    }

    func testQueueFailureKeepsMeetingIdentityAndMessage() {
        let meetingID = UUID()
        let failure = MeetingReanalysisQueue.Failure(
            id: UUID(),
            meetingID: meetingID,
            title: "Gray Conseil - vendor sync up",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            message: "The request timed out."
        )
        XCTAssertEqual(failure.meetingID, meetingID)
        XCTAssertTrue(failure.message.localizedCaseInsensitiveContains("timed out"))
        XCTAssertEqual(
            [failure].compactMap(\.meetingID),
            [meetingID]
        )
    }

    func testAnalysisTitleHintPrefersCalendarEventName() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "Stored name")
        container.mainContext.insert(meeting)
        XCTAssertEqual(meeting.analysisTitleHint, "Stored name")

        meeting.calendarEventTitle = "North Campus Engineering Scope Review"
        XCTAssertEqual(meeting.analysisTitleHint, "North Campus Engineering Scope Review")

        meeting.calendarEventTitle = "   "
        XCTAssertEqual(meeting.analysisTitleHint, "Stored name")
    }

    func testRenameDisplayTitleTrimsAndRejectsEmpty() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "Standup")
        container.mainContext.insert(meeting)
        XCTAssertTrue(meeting.renameDisplayTitle("  Q2 budget  "))
        XCTAssertEqual(meeting.title, "Q2 budget")
        XCTAssertFalse(meeting.renameDisplayTitle("   "))
        XCTAssertEqual(meeting.title, "Q2 budget")
        XCTAssertFalse(meeting.renameDisplayTitle("Q2 budget"))
    }

    func testApplyGeneratedTitleDoesNotOverwriteUserRename() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "Meeting 8/27/26")
        container.mainContext.insert(meeting)
        XCTAssertTrue(Meeting.isAutomaticTitle(meeting.title))
        meeting.applyGeneratedTitle("Align prospect docs with Jordan")
        XCTAssertEqual(meeting.title, "Align prospect docs with Jordan")
        XCTAssertTrue(meeting.renameDisplayTitle("Q2 budget"))
        meeting.applyGeneratedTitle("A different AI title")
        XCTAssertEqual(meeting.generatedTitle, "A different AI title")
        XCTAssertEqual(meeting.title, "Q2 budget")
    }

    func testApplyGeneratedTitleDoesNotOverwriteCalendarLinkedTitle() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "North Campus Engineering Scope Review")
        meeting.calendarEventID = "evt-1"
        meeting.calendarEventTitle = "North Campus Engineering Scope Review"
        container.mainContext.insert(meeting)

        meeting.applyGeneratedTitle("Align prospect docs with Jordan")
        XCTAssertEqual(meeting.generatedTitle, "Align prospect docs with Jordan")
        XCTAssertEqual(meeting.title, "North Campus Engineering Scope Review")
    }

    func testActionSnapshotRoundTrip() {
        let items = [
            ParsedActionItem(text: "Fix the ROM", assignee: "Me", sourceQuote: nil),
            ParsedActionItem(text: "Send drawings", assignee: "Jordan", sourceQuote: nil),
        ]
        let json = InsightRevision.encodeActions(items)
        let decoded = InsightRevision.decodeActions(json)
        XCTAssertEqual(decoded.map(\.text), ["Fix the ROM", "Send drawings"])
        XCTAssertEqual(decoded.map(\.assignee), ["Me", "Jordan"])
    }

    func testCanRevertRequiresTwoInsights() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let meeting = Meeting(title: "Call")
        container.mainContext.insert(meeting)
        XCTAssertFalse(InsightRevision.canRevert(meeting))
        let a = MeetingInsight(summary: "one")
        a.meeting = meeting
        meeting.insights.append(a)
        container.mainContext.insert(a)
        XCTAssertFalse(InsightRevision.canRevert(meeting))
        let b = MeetingInsight(summary: "two")
        b.meeting = meeting
        meeting.insights.append(b)
        container.mainContext.insert(b)
        XCTAssertTrue(InsightRevision.canRevert(meeting))
    }
}
