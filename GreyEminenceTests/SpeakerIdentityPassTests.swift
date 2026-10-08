import XCTest
import SwiftData
@testable import Grey_Eminence

@MainActor
final class SpeakerIdentityPassTests: XCTestCase {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Meeting.self, Contact.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func vector(_ first: Float, _ second: Float = 0) -> [Float] {
        [first, second, 0, 0, 0, 0, 0, 0]
    }

    func testRosterIncludesContactWhoWasNotOnTheInvite() throws {
        let container = try container()
        let context = container.mainContext
        let meeting = Meeting(title: "Call")
        meeting.status = .completed
        let jordan = Contact(name: "Jordan Hale")
        let bob = Contact(name: "Bob Dipshit")
        bob.speakerAliases = ["Bobby"]
        context.insert(meeting)
        context.insert(jordan)
        context.insert(bob)
        meeting.attendees = [jordan]

        let names = SpeakerIdentityPass.rosterNames(meeting: meeting, contacts: [jordan, bob])
        XCTAssertTrue(names.contains(where: { SpeakerNameMatcher.samePerson($0, "Bob Dipshit") }))
        XCTAssertTrue(names.contains(where: { SpeakerNameMatcher.samePerson($0, "Bobby") }))
        XCTAssertTrue(names.contains(where: { SpeakerNameMatcher.samePerson($0, "Jordan Hale") }))
    }

    func testSelfIntroNamesAContactWhoWasNotOnTheCalendar() throws {
        let container = try container()
        let context = container.mainContext
        let meeting = Meeting(title: "Call")
        meeting.status = .completed
        let jordan = Contact(name: "Jordan Hale")
        let bob = Contact(name: "Bob Dipshit")
        context.insert(meeting)
        context.insert(jordan)
        context.insert(bob)
        meeting.attendees = [jordan]

        let intro = TranscriptSegment(
            speaker: .other("speaker-1"),
            text: "Nice to meet you, I'm Bob.",
            startTime: 12,
            endTime: 16,
            isFinal: true
        )
        let later = TranscriptSegment(
            speaker: .other("speaker-1"),
            text: "The draft is wrong.",
            startTime: 90,
            endTime: 94,
            isFinal: true
        )
        intro.meeting = meeting
        later.meeting = meeting
        meeting.segments.append(contentsOf: [intro, later])

        let edits = SpeakerIdentityPass.applyIdentities(
            meeting: meeting,
            contacts: [jordan, bob]
        )
        XCTAssertGreaterThan(edits.selfIntroChanged, 0)
        XCTAssertEqual(intro.speaker, .other("Bob Dipshit"))
        XCTAssertEqual(later.speaker, .other("Bob Dipshit"))
    }

    func testLeftoverPrintMatchUsesAttendeeNotTheWholeRolodex() throws {
        let container = try container()
        let context = container.mainContext
        let meeting = Meeting(title: "Call")
        meeting.status = .completed
        let sam = Contact(name: "Sam")
        let jordan = Contact(name: "Jordan Hale")
        sam.addVoicePrint(vector(1), source: VoicePrintSource.enroll)
        jordan.addVoicePrint(vector(0, 1), source: VoicePrintSource.enroll)
        context.insert(meeting)
        context.insert(sam)
        context.insert(jordan)
        meeting.attendees = [sam]

        let leftover = TranscriptSegment(
            speaker: .other("speaker-1"),
            text: "We can ship Friday.",
            startTime: 20,
            endTime: 24,
            isFinal: true
        )
        leftover.meeting = meeting
        meeting.segments.append(leftover)

        let edits = SpeakerIdentityPass.applyIdentities(
            meeting: meeting,
            contacts: [sam, jordan],
            embeddings: [leftover.speaker.identityKey: vector(1)]
        )
        XCTAssertGreaterThan(edits.printChanged, 0)
        XCTAssertEqual(leftover.speaker, .other("Sam"))
    }

    func testLeftoverPrintDoesNotNameSomeoneWhoWasNotOnTheCall() throws {
        let container = try container()
        let context = container.mainContext
        let meeting = Meeting(title: "Call")
        meeting.status = .completed
        let sam = Contact(name: "Sam")
        let jordan = Contact(name: "Jordan Hale")
        sam.addVoicePrint(vector(1), source: VoicePrintSource.enroll)
        jordan.addVoicePrint(vector(0, 1), source: VoicePrintSource.enroll)
        context.insert(meeting)
        context.insert(sam)
        context.insert(jordan)
        meeting.attendees = [sam]

        let leftover = TranscriptSegment(
            speaker: .other("speaker-1"),
            text: "We can ship Friday.",
            startTime: 20,
            endTime: 24,
            isFinal: true
        )
        leftover.meeting = meeting
        meeting.segments.append(leftover)

        let edits = SpeakerIdentityPass.applyIdentities(
            meeting: meeting,
            contacts: [sam, jordan],
            embeddings: [leftover.speaker.identityKey: vector(0, 1)]
        )
        XCTAssertEqual(edits.printChanged, 0)
        XCTAssertEqual(leftover.speaker, .other("speaker-1"))
    }

    func testUncheckedPersonIsNotUsedAsAPrintMatch() throws {
        let container = try container()
        let context = container.mainContext
        let meeting = Meeting(title: "Call")
        meeting.status = .completed
        let sam = Contact(name: "Sam")
        let jordan = Contact(name: "Jordan Hale")
        sam.addVoicePrint(vector(1), source: VoicePrintSource.enroll)
        jordan.addVoicePrint(vector(0, 1), source: VoicePrintSource.enroll)
        context.insert(meeting)
        context.insert(sam)
        context.insert(jordan)
        meeting.attendees = [sam, jordan]

        let leftover = TranscriptSegment(
            speaker: .other("speaker-1"),
            text: "We can ship Friday.",
            startTime: 20,
            endTime: 24,
            isFinal: true
        )
        leftover.meeting = meeting
        meeting.segments.append(leftover)

        let edits = SpeakerIdentityPass.applyIdentities(
            meeting: meeting,
            contacts: [sam, jordan],
            embeddings: [leftover.speaker.identityKey: vector(0, 1)],
            printContactIDs: [sam.id]
        )
        XCTAssertEqual(edits.printChanged, 0)
        XCTAssertEqual(leftover.speaker, .other("speaker-1"))
    }

    func testTalkOverIsNotNamedFromAVoicePrint() throws {
        let container = try container()
        let context = container.mainContext
        let meeting = Meeting(title: "Call")
        meeting.status = .completed
        let sam = Contact(name: "Sam")
        sam.addVoicePrint(vector(1), source: VoicePrintSource.enroll)
        context.insert(meeting)
        context.insert(sam)
        meeting.attendees = [sam]

        let mashup = TranscriptSegment(
            speaker: .talkOver,
            text: "both talking",
            startTime: 20,
            endTime: 24,
            isFinal: true
        )
        mashup.meeting = meeting
        meeting.segments.append(mashup)

        let edits = SpeakerIdentityPass.applyIdentities(
            meeting: meeting,
            contacts: [sam],
            embeddings: [mashup.speaker.identityKey: vector(1)]
        )
        XCTAssertEqual(edits.printChanged, 0)
        XCTAssertTrue(mashup.speaker.isTalkOver)
    }

    func testMergedProfilesBuildFromContactStampsWithoutJSON() throws {
        let container = try container()
        let sam = Contact(name: "Sam")
        sam.addVoicePrint(vector(1), source: VoicePrintSource.enroll)
        container.mainContext.insert(sam)

        let profiles = VoiceProfileStore.mergedProfiles(contacts: [sam], stored: [])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].contactID, sam.id)
        XCTAssertEqual(profiles[0].contactName, "Sam")
        XCTAssertFalse(profiles[0].signature.isEmpty)
    }

    func testMergedProfilesKeepJSONWhenContactHasNoStamp() throws {
        let id = UUID()
        let stored = VoiceProfileStore.Profile(
            contactID: id,
            contactName: "Erin",
            signature: VoiceSignature.from(turns: [(vector(1), 120)])!,
            meetingCount: 2,
            updatedAt: .now
        )
        let profiles = VoiceProfileStore.mergedProfiles(contacts: [], stored: [stored])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].contactID, id)
        XCTAssertEqual(profiles[0].contactName, "Erin")
    }
}
