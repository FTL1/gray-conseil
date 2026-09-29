import SwiftData
import XCTest
@testable import Grey_Eminence

final class VoicePrintTests: XCTestCase {
    func testCodecRoundTrip() {
        let values: [Float] = [0.1, -0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let data = VoicePrintCodec.encode(values)
        let decoded = VoicePrintCodec.decode(data)
        XCTAssertEqual(decoded, values)
        XCTAssertNil(VoicePrintCodec.decode(nil))
        XCTAssertNil(VoicePrintCodec.decode(Data([0x00])))
    }

    func testCosineDistanceIdenticalIsZero() {
        let vector: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(VoicePrintMatcher.cosineDistance(vector, vector), 0, accuracy: 0.0001)
    }

    func testLooseDistanceDoesNotMatchEnrolledThreshold() {
        let probe: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let kinda: [Float] = [0.6, 0.8, 0, 0, 0, 0, 0, 0]
        let distance = VoicePrintMatcher.cosineDistance(probe, kinda)
        XCTAssertGreaterThan(distance, VoicePrintMatcher.enrolledDistance)
        XCTAssertNil(
            VoicePrintMatcher.bestMatch(
                embedding: probe,
                in: [(item: "jordan", embedding: kinda)],
                threshold: VoicePrintMatcher.enrolledDistance
            )
        )
    }

    func testBestMatchRequiresMarginWhenTwoPeopleAreClose() {
        let probe: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let a: [Float] = [0.99, 0.1, 0, 0, 0, 0, 0, 0]
        let b: [Float] = [0.98, 0.12, 0, 0, 0, 0, 0, 0]
        XCTAssertNil(
            VoicePrintMatcher.bestMatch(
                embedding: probe,
                in: [(item: "jordan", embedding: a), (item: "sam", embedding: b)],
                threshold: 0.5,
                margin: 0.08
            )
        )
    }

    func testBestMatchRespectsThreshold() {
        let probe: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let close: [Float] = [0.95, 0.05, 0, 0, 0, 0, 0, 0]
        let far: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
        let hit = VoicePrintMatcher.bestMatch(
            embedding: probe,
            in: [(item: "close", embedding: close), (item: "far", embedding: far)],
            threshold: 0.2
        )
        XCTAssertEqual(hit?.item, "close")

        let miss = VoicePrintMatcher.bestMatch(
            embedding: probe,
            in: [(item: "far", embedding: far)],
            threshold: 0.2
        )
        XCTAssertNil(miss)
    }

    func testCatalogSplitsThisMeetingAndPriorSpeakers() {
        let alex = SpeakerLinkPerson(contactID: UUID(), name: "Alex", hasVoicePrint: true, aliases: [], meetingCount: 4, isThisVoice: false)
        let pat = SpeakerLinkPerson(contactID: UUID(), name: "Pat", hasVoicePrint: false, aliases: ["guest-1"], meetingCount: 1, isThisVoice: false)
        let sam = SpeakerLinkPerson(contactID: UUID(), name: "Sam", hasVoicePrint: true, aliases: ["Sam"], meetingCount: 3, isThisVoice: false)
        let unused = SpeakerLinkPerson(contactID: UUID(), name: "Random", hasVoicePrint: false, aliases: [], meetingCount: 0, isThisVoice: false)

        let groups = SpeakerLinkCatalog.groups(
            people: [alex, pat, sam, unused],
            transcriptNames: ["Alex", "Pat", "guest-1"],
            attendeeNames: ["Pat", "Jordan"],
            meName: "Alex",
            currentSpeakerName: "guest-1"
        )

        XCTAssertEqual(groups.thisMeeting.map(\.name), ["Alex", "Pat", "Jordan"])
        XCTAssertTrue(groups.thisMeeting.first { $0.name == "Pat" }?.isThisVoice == true)
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Alex" }?.isMe, true)
        XCTAssertTrue(groups.thisMeeting.first { $0.name == "Alex" }?.asSpeaker().isMe == true)
        XCTAssertNotEqual(groups.thisMeeting.first { $0.name == "Pat" }?.isMe, true)
        XCTAssertEqual(groups.priorSpeakers.map(\.name), ["Sam"])
        XCTAssertFalse(groups.thisMeeting.contains { $0.name == "Random" })
        XCTAssertFalse(groups.priorSpeakers.contains { $0.name == "Random" })
    }

    func testMeDisplayingAnotherNameIsNotAlreadyThatPerson() {
        let robert = SpeakerLinkPerson(
            contactID: UUID(),
            name: "Robert Berube",
            hasVoicePrint: true,
            aliases: [],
            meetingCount: 2,
            isThisVoice: false
        )
        let groups = SpeakerLinkCatalog.groups(
            people: [robert],
            transcriptNames: ["Robert Berube"],
            attendeeNames: ["Robert Berube"],
            meName: "Clay",
            currentSpeakerName: "Robert Berube",
            currentIsMe: true
        )
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Clay" }?.isThisVoice, true)
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Clay" }?.isMe, true)
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Robert Berube" }?.isThisVoice, false)
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Robert Berube" }?.asSpeaker().isMe, false)
    }

    func testNamedRemoteIsThisVoiceWhenIdentityMatches() {
        let robert = SpeakerLinkPerson(
            contactID: UUID(),
            name: "Robert Berube",
            hasVoicePrint: true,
            aliases: [],
            meetingCount: 2,
            isThisVoice: false
        )
        let groups = SpeakerLinkCatalog.groups(
            people: [robert],
            transcriptNames: ["Robert Berube"],
            attendeeNames: ["Robert Berube"],
            meName: "Clay",
            currentSpeakerName: "Robert Berube",
            currentIsMe: false
        )
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Clay" }?.isThisVoice, false)
        XCTAssertEqual(groups.thisMeeting.first { $0.name == "Robert Berube" }?.isThisVoice, true)
    }

    func testCollectionAppendsInsteadOfOverwriting() {
        let contact = Contact(name: "Pat")
        contact.addVoicePrint([1, 0, 0, 0, 0, 0, 0, 0], source: VoicePrintSource.session)
        contact.addVoicePrint([0, 1, 0, 0, 0, 0, 0, 0], source: VoicePrintSource.session)
        XCTAssertEqual(contact.voicePrintSampleCount, 2)
        XCTAssertEqual(contact.voicePrintEmbeddings().count, 2)
    }

    func testCollectionSkipsNearDuplicate() {
        let contact = Contact(name: "Pat")
        let sample = [Float](repeating: 0.4, count: 8)
        contact.addVoicePrint(sample, source: VoicePrintSource.session)
        contact.addVoicePrint(sample, source: VoicePrintSource.session)
        XCTAssertEqual(contact.voicePrintSampleCount, 1)
    }

    func testIsolationRemovesCollidingPrintsFromOthers() {
        let me = Contact(name: "Alex")
        let robert = Contact(name: "Robert")
        let robertVoice: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        me.addVoicePrint(robertVoice, source: VoicePrintSource.enroll)
        XCTAssertTrue(me.hasVoicePrint)
        VoicePrintIsolation.isolate(robertVoice, owner: robert, among: [me, robert])
        XCTAssertFalse(me.hasVoicePrint)
        robert.addVoicePrint(robertVoice, source: VoicePrintSource.session)
        XCTAssertTrue(robert.hasVoicePrint)
    }

    func testBestIdentityMatchDoesNotUseSamePersonAsRunnerUp() {
        let probe: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let a: [Float] = [0.99, 0.1, 0, 0, 0, 0, 0, 0]
        let b: [Float] = [0.98, 0.12, 0, 0, 0, 0, 0, 0]
        XCTAssertNil(
            VoicePrintMatcher.bestMatch(
                embedding: probe,
                in: [(item: "jordan", embedding: a), (item: "sam", embedding: b)],
                threshold: 0.5,
                margin: 0.08
            )
        )
        let hit = VoicePrintMatcher.bestIdentityMatch(
            embedding: probe,
            in: [(item: "jordan", embedding: a), (item: "jordan", embedding: b)],
            identity: { $0 },
            threshold: 0.5,
            margin: 0.08
        )
        XCTAssertEqual(hit?.item, "jordan")
    }

    func testExpectedSpeakerUsesTheWholeCollection() {
        let person = MeetingSpeakerRecovery.ExpectedSpeaker(
            name: "Robert",
            speaker: .other("Robert"),
            contactID: nil,
            embedding: [Float](repeating: 0.1, count: 8),
            embeddings: [
                [Float](repeating: 0.1, count: 8),
                [Float](repeating: 0.9, count: 8)
            ],
            isMe: false,
            isPreselected: true
        )
        XCTAssertEqual(person.allEmbeddings().count, 2)
        XCTAssertTrue(person.hasVoicePrint)
    }

    func testLouderSlicePrefersHigherEnergy() {
        XCTAssertEqual(VoicePrintEnrollment.louder([0.9, 0.9], [0.1, 0.1]), [0.9, 0.9])
        XCTAssertEqual(VoicePrintEnrollment.rms([0, 0]), 0, accuracy: 0.0001)
    }

    @MainActor
    func testSeedingUsesThisMeetingNotTheWholeRolodex() throws {
        let container = try ModelContainer(
            for: Contact.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let me = Contact(name: "Alex")
        let jordan = Contact(name: "Jordan Hale")
        let sam = Contact(name: "Sam")
        me.mergeVoicePrint([Float](repeating: 0.1, count: 8))
        jordan.mergeVoicePrint([Float](repeating: 0.2, count: 8))
        sam.mergeVoicePrint([Float](repeating: 0.3, count: 8))
        container.mainContext.insert(me)
        container.mainContext.insert(jordan)
        container.mainContext.insert(sam)

        let seeded = VoicePrintSeeding.contactsToSeed(
            contacts: [me, jordan, sam],
            meetingAttendeeIDs: [sam.id],
            myContactID: me.id
        )
        XCTAssertEqual(Set(seeded.map(\.name)), Set(["Alex", "Sam"]))
    }

    func testPlaceholderNames() {
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("guest-1"))
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("Me"))
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("Speaker 2"))
        XCTAssertFalse(SpeakerLinkCatalog.isPlaceholder("Pat"))
        XCTAssertTrue(Speaker.other("guest-2").displayNameIsPlaceholder)
        XCTAssertTrue(Speaker.other("unknown-1").displayNameIsPlaceholder)
        XCTAssertFalse(Speaker.other("Pat").displayNameIsPlaceholder)
    }
}
