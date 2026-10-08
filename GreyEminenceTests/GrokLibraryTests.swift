import XCTest
import SwiftData
@testable import Grey_Eminence

final class GrokLibraryTests: XCTestCase {
    func testWritesTranscriptIntelAndIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snap = sampleSnapshot()
        let record = GrokLibrary.writeSnapshot(snap, series: "Weekly Standup", into: root)
        XCTAssertEqual(record.series, "Weekly Standup")
        XCTAssertTrue(record.hasTranscript)
        XCTAssertEqual(record.actionCount, 2)
        XCTAssertEqual(record.openActionCount, 2)

        let folder = root.appendingPathComponent("meetings/\(snap.id.uuidString)", isDirectory: true)
        let transcript = try String(
            contentsOf: folder.appendingPathComponent("transcript.md"),
            encoding: .utf8
        )
        XCTAssertTrue(transcript.contains("twelve pages"))
        XCTAssertTrue(transcript.contains("I'll update the draft"))
        let intel = try String(
            contentsOf: folder.appendingPathComponent("intel.md"),
            encoding: .utf8
        )
        XCTAssertTrue(intel.contains("Send the notes") || intel.contains("draft") || intel.contains("Documents"))

        GrokLibrary.writeIndex([record], into: root)
        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(GrokLibrary.Index.self, from: data)
        XCTAssertEqual(index.meetingCount, 1)
        XCTAssertEqual(index.meetings.first?.id, snap.id.uuidString)
        XCTAssertEqual(index.bundleID, "com.ftl1.greyeminence")
    }

    @MainActor
    func testSyncAllReusesExistingTranscriptAndPatchesTitle() async throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let meeting = Meeting(title: "Weekly Standup", date: date(2026, 8, 18))
        meeting.status = .completed
        meeting.duration = 47 * 60
        meeting.seriesTitle = "Weekly Standup"
        context.insert(meeting)
        let line = TranscriptSegment(
            speaker: .other("Jordan"),
            text: "It is twelve pages not forty.",
            startTime: 12,
            endTime: 16,
            isFinal: true
        )
        line.meeting = meeting
        meeting.segments.append(line)
        context.insert(line)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = await GrokLibrary.syncAll(from: context, into: root)
        XCTAssertEqual(first.written, 1)
        XCTAssertEqual(first.reused, 0)
        let transcriptURL = root
            .appendingPathComponent("meetings/\(meeting.id.uuidString)", isDirectory: true)
            .appendingPathComponent("transcript.md")
        let original = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(original.contains("twelve pages"))

        try "KEEP-ME".write(to: transcriptURL, atomically: true, encoding: .utf8)
        meeting.title = "Renamed standup"
        let second = await GrokLibrary.syncAll(from: context, into: root)
        XCTAssertEqual(second.written, 0)
        XCTAssertEqual(second.reused, 1)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "KEEP-ME")

        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(GrokLibrary.Index.self, from: data)
        XCTAssertEqual(index.meetings.first?.title, "Renamed standup")
        XCTAssertEqual(index.meetings.first?.id, meeting.id.uuidString)
    }

    func testIdleGateReadsProcessInfo() {
        _ = BackgroundIdleWork.resourcesAreFree
    }

    func testSkipsEmptySeries() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-lib-\(UUID().uuidString)", isDirectory: true)
        let record = GrokLibrary.writeSnapshot(sampleSnapshot(), series: "  ", into: root)
        XCTAssertNil(record.series)
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleSnapshot() -> DossierMeetingSnapshot {
        DossierMeetingSnapshot(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            title: "Weekly Standup",
            generatedTitle: "Align draft numbers",
            date: date(2026, 8, 18),
            durationLabel: "47m",
            durationMinutes: 47,
            attendees: ["Alex", "Jordan"],
            speakers: ["Alex", "Jordan"],
            myLabels: ["Alex", "Me"],
            summaryJSON: """
            [{"title":"Documents","intro":"Alex is correcting outbound scope language.","points":[{"label":"Draft","detail":"Update numbers Jordan voiced."}]}]
            """,
            actionItems: [
                DossierAction(text: "Fix the draft", assignee: "Me", isCompleted: false, sourceQuote: "I'll update the draft"),
                DossierAction(text: "Send the notes", assignee: "Jordan", isCompleted: false, sourceQuote: "I can send the notes"),
            ],
            followUps: ["Does the write-up use Jordan's twelve-page figure?"],
            topics: ["project documents", "draft"],
            shareNarratives: [],
            transcript: [
                DossierLine(speaker: "Jordan", timestamp: "0:12", text: "It is twelve pages not forty.", isMe: false),
                DossierLine(speaker: "Alex", timestamp: "0:20", text: "I'll update the draft.", isMe: true),
            ]
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
