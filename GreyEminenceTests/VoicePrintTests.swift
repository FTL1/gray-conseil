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

    func testDuplicateCanGainAFootprint() {
        let contact = Contact(name: "Pat")
        let sample = [Float](repeating: 0.4, count: 8)
        contact.addVoicePrint(sample, source: VoicePrintSource.session)
        XCTAssertFalse(contact.voicePrintSamples().contains(where: \.usesFootprint))
        contact.addVoicePrint(
            sample,
            source: VoicePrintSource.session,
            footprint: [1, 0, 0, 0, 0, 0, 0, 0],
            usesFootprint: true
        )
        XCTAssertEqual(contact.voicePrintSampleCount, 1)
        XCTAssertTrue(contact.voicePrintSamples().contains(where: \.usesFootprint))
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

    func testLegacySampleJSONStillDecodesWithoutFootprint() throws {
        let sample = VoicePrintSample.make(
            embedding: [1, 0, 0, 0, 0, 0, 0, 0],
            source: VoicePrintSource.session
        )
        let encoded = try JSONEncoder().encode(sample)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "footprint")
        object.removeValue(forKey: "usesFootprint")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VoicePrintSample.self, from: stripped)
        XCTAssertFalse(decoded.usesFootprint)
        XCTAssertNil(decoded.footprint)
        XCTAssertEqual(decoded.floats()?.count, 8)
    }

    func testFootprintSineAndNoiseAreDifferent() {
        let n = 16_000
        var sine = [Float](repeating: 0, count: n)
        var noise = [Float](repeating: 0, count: n)
        var seed: UInt32 = 42
        for i in 0..<n {
            sine[i] = sin(2 * Float.pi * 440 * Float(i) / 16_000)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            noise[i] = Float(Int(seed >> 16) % 2000) / 1_000 - 1
        }
        let a = AcousticFootprint.extract(sine)
        let b = AcousticFootprint.extract(noise)
        XCTAssertEqual(a.count, AcousticFootprint.dimension)
        XCTAssertEqual(b.count, AcousticFootprint.dimension)
        XCTAssertGreaterThan(VoicePrintMatcher.cosineDistance(a, b), 0.05)
    }

    func testFootprintEchoRaisesLateEnvelopeCorrelation() {
        let n = 32_000
        var dry = [Float](repeating: 0, count: n)
        var seed: UInt32 = 7
        for i in 0..<n {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            dry[i] = Float(Int(seed >> 16) % 2000) / 1_000 - 1
        }
        var wet = dry
        let delay = 1_600
        for i in delay..<n { wet[i] += 0.8 * dry[i - delay] }
        let dryPrint = AcousticFootprint.extract(dry)
        let wetPrint = AcousticFootprint.extract(wet)
        XCTAssertGreaterThan(VoicePrintMatcher.cosineDistance(dryPrint, wetPrint), 0.001)
    }

    func testMashupDoesNotMintAThirdPerson() {
        let a: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
        let mix: [Float] = [0.7071, 0.7071, 0, 0, 0, 0, 0, 0]
        let hit = VoicePrintMatcher.identityAssignment(
            embedding: mix,
            in: [
                (item: "clay", embedding: a, footprint: nil, usesFootprint: false),
                (item: "robert", embedding: b, footprint: nil, usesFootprint: false)
            ],
            identity: { $0 }
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.kind, .mashup)
        XCTAssertTrue(hit?.item == "clay" || hit?.item == "robert")
    }

    func testFootprintPullsACloseVoiceMatch() {
        let voiceA: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let voiceB: [Float] = [0.95, 0.3, 0, 0, 0, 0, 0, 0]
        let footA: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let footB: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
        let probeVoice = voiceB
        let probeFoot = footA
        let hit = VoicePrintMatcher.identityAssignment(
            embedding: probeVoice,
            footprint: probeFoot,
            in: [
                (item: "wet", embedding: voiceA, footprint: footA, usesFootprint: true),
                (item: "dry", embedding: voiceB, footprint: footB, usesFootprint: true)
            ],
            identity: { $0 }
        )
        XCTAssertEqual(hit?.item, "wet")
    }

    func testDualTrackMicOnlyIsMe() {
        let mic = [Float](repeating: 0.2, count: 16_000)
        let system = [Float](repeating: 0.001, count: 16_000)
        let assigned = DualTrackOverlap.resolve(
            proposed: .other("speaker-1"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            me: .me
        )
        XCTAssertTrue(assigned.isMe)
    }

    func testDualTrackSystemOnlyNeverMe() {
        let mic = [Float](repeating: 0.001, count: 16_000)
        let system = [Float](repeating: 0.2, count: 16_000)
        let leftover = DualTrackOverlap.resolve(
            proposed: .other("speaker-2"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            remotes: [.other("Josh")]
        )
        XCTAssertEqual(leftover.displayName, "speaker-2")
        let unseated = DualTrackOverlap.resolve(
            proposed: .me,
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            remotes: [.other("Josh")]
        )
        XCTAssertEqual(unseated.displayName, "Josh")
        XCTAssertFalse(unseated.isMe)
    }

    func testDualTrackBothSimilarMeIsTalkOver() {
        let mic = [Float](repeating: 0.2, count: 16_000)
        let system = [Float](repeating: 0.2, count: 16_000)
        let assigned = DualTrackOverlap.resolve(
            proposed: .me,
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system
        )
        XCTAssertTrue(assigned.isTalkOver)
    }

    func testDualTrackBothSimilarIsTalkOver() {
        let mic = [Float](repeating: 0.2, count: 16_000)
        let system = [Float](repeating: 0.2, count: 16_000)
        let leftover = DualTrackOverlap.resolve(
            proposed: .other("speaker-2"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system
        )
        XCTAssertTrue(leftover.isTalkOver)
        let named = DualTrackOverlap.resolve(
            proposed: .other("Josh"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system
        )
        XCTAssertEqual(named.displayName, "Josh")
        XCTAssertFalse(named.isTalkOver)
    }

    func testDualTrackMicDominantLeftoverIsMe() {
        let mic = [Float](repeating: 0.2, count: 16_000)
        let system = [Float](repeating: 0.02, count: 16_000)
        let leftover = DualTrackOverlap.resolve(
            proposed: .other("speaker-1"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            me: .me
        )
        XCTAssertTrue(leftover.isMe)
    }

    func testDualTrackMicDominantNamedRemoteStays() {
        let mic = [Float](repeating: 0.2, count: 16_000)
        let system = [Float](repeating: 0.02, count: 16_000)
        let assigned = DualTrackOverlap.resolve(
            proposed: .other("Josh"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            me: .me
        )
        XCTAssertEqual(assigned.displayName, "Josh")
        XCTAssertFalse(assigned.isMe)
    }

    func testDualTrackSilentSystemDoesNotBulkMe() {
        let mic = [Float](repeating: 0.2, count: 16_000)
        let system = [Float](repeating: 0, count: 16_000)
        XCTAssertFalse(DualTrackOverlap.trackHasSpeech(system))
        let named = DualTrackOverlap.resolve(
            proposed: .other("Josh"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            me: .me,
            systemHasSpeech: false
        )
        XCTAssertEqual(named.displayName, "Josh")
        let leftover = DualTrackOverlap.resolve(
            proposed: .other("speaker-1"),
            start: 0,
            end: 1,
            offset: 0,
            mic: mic,
            system: system,
            me: .me,
            systemHasSpeech: false
        )
        XCTAssertEqual(leftover.displayName, "speaker-1")
    }

    func testClassifyReverbOnLouderSystemIsRemote() {
        XCTAssertEqual(
            DualTrackOverlap.classify(micRMS: 0.05, sysRMS: 0.08, systemReverb: 0.5),
            .remote
        )
        XCTAssertEqual(
            DualTrackOverlap.classify(micRMS: 0.2, sysRMS: 0.2, systemReverb: 0),
            .talkOver
        )
        XCTAssertEqual(
            DualTrackOverlap.classify(micRMS: 0.2, sysRMS: 0.001, systemReverb: 0),
            .me
        )
    }

    func testPlaceholderNames() {
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("guest-1"))
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("Me"))
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("Speaker 2"))
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("Talk-over"))
        XCTAssertTrue(SpeakerLinkCatalog.isPlaceholder("overlap"))
        XCTAssertFalse(SpeakerLinkCatalog.isPlaceholder("Pat"))
        XCTAssertTrue(Speaker.other("guest-2").displayNameIsPlaceholder)
        XCTAssertTrue(Speaker.other("unknown-1").displayNameIsPlaceholder)
        XCTAssertTrue(Speaker.talkOver.displayNameIsPlaceholder)
        XCTAssertFalse(Speaker.other("Pat").displayNameIsPlaceholder)
    }
}
