import Foundation
import SwiftData

/// Names leftover voices after a meeting, using saved voice prints and
/// first-person self-introductions ("I'm Bob") matched to contacts and
/// calendar invitees. Live capture only has to keep up with speech; this
/// pass can take as long as the audio needs and runs when the machine is idle.
@MainActor
enum SpeakerIdentityPass {
    struct Outcome: Sendable, Equatable {
        var audioChanged: Int
        var selfIntroChanged: Int
        var printChanged: Int
        var unknownRemaining: Int

        var changed: Int { audioChanged + selfIntroChanged + printChanged }
    }

    struct IdentityEdits: Equatable {
        var selfIntroChanged: Int
        var printChanged: Int
    }

    static func schedule(
        meetingID: UUID,
        container: ModelContainer,
        isBusy: @escaping @MainActor () -> Bool
    ) {
        Task(priority: .utility) {
            await BackgroundIdleWork.waitUntilIdle(isBusy: isBusy)
            guard !Task.isCancelled else { return }
            _ = await run(meetingID: meetingID, container: container, isBusy: isBusy)
        }
    }

    /// Completed meetings from the recent sidebar window that still have
    /// unnamed remotes. One at a time, paused while recording.
    static func healRecent(
        container: ModelContainer,
        isBusy: @escaping @MainActor () -> Bool
    ) async {
        let cutoff = MeetingLibrary.recentCutoff()
        let ids: [UUID] = await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
            return meetings.compactMap { meeting -> UUID? in
                guard meeting.status == .completed, meeting.date >= cutoff else { return nil }
                guard meeting.segments.contains(where: { $0.speaker.isGuestPlaceholder }) else {
                    return nil
                }
                return meeting.id
            }
        }.value
        guard !ids.isEmpty else { return }
        LogManager.send(
            "Speaker identity: \(ids.count) recent meeting(s) still have unnamed voices",
            category: .transcription
        )
        for id in ids.prefix(8) {
            await BackgroundIdleWork.waitUntilIdle(isBusy: isBusy)
            guard !Task.isCancelled else { return }
            _ = await run(meetingID: id, container: container, isBusy: isBusy)
        }
    }

    @discardableResult
    static func run(
        meetingID: UUID,
        container: ModelContainer,
        isBusy: @escaping @MainActor () -> Bool = { false }
    ) async -> Outcome? {
        let context = container.mainContext
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        descriptor.fetchLimit = 1
        guard let meeting = try? context.fetch(descriptor).first else { return nil }
        guard meeting.status == .completed, !meeting.segments.isEmpty else { return nil }

        let contacts = (try? context.fetch(FetchDescriptor<Contact>())) ?? []
        let expected = MeetingSpeakerRecovery.candidates(meeting: meeting, contacts: contacts)
            .filter(\.isPreselected)

        var audioChanged = 0
        var embeddings: [Speaker.IdentityKey: [Float]] = [:]
        let hasSystemAudio = !AudioFileWriter.existingChunkURLs(
            base: StorageManager.shared.systemAudioURL(for: meeting.audioSourceMeetingID ?? meeting.id)
        ).isEmpty

        var appliedInRecover = false
        var recoverEdits = IdentityEdits(selfIntroChanged: 0, printChanged: 0)
        if hasSystemAudio {
            await BackgroundIdleWork.waitUntilIdle(isBusy: isBusy)
            do {
                let result = try await TransientActivityCoordinator.shared.runAsync(
                    "Identifying speakers…"
                ) {
                    try await MeetingSpeakerRecovery.recover(
                        meeting: meeting,
                        expected: expected,
                        contacts: contacts
                    )
                }
                audioChanged = max(
                    0,
                    result.changed - result.selfIntroChanged - result.printChanged
                )
                embeddings = result.embeddings
                appliedInRecover = true
                recoverEdits = IdentityEdits(
                    selfIntroChanged: result.selfIntroChanged,
                    printChanged: result.printChanged
                )
            } catch MeetingSpeakerRecovery.RecoveryError.noSystemAudio {
                embeddings = [:]
            } catch {
                LogManager.send(
                    "Speaker identity audio pass failed: \(error.localizedDescription)",
                    category: .transcription,
                    level: .warning,
                    meetingID: meeting.id
                )
            }
        }

        let edits: IdentityEdits
        if appliedInRecover {
            edits = recoverEdits
        } else {
            edits = applyIdentities(
                meeting: meeting,
                contacts: contacts,
                embeddings: embeddings,
                printContactIDs: allowedPrintIDs(expected: expected, meeting: meeting)
            )
        }
        enrollMatchedPrints(
            meeting: meeting,
            contacts: contacts,
            embeddings: embeddings,
            expected: expected
        )

        let unknown = Set(
            meeting.segments
                .map(\.speaker)
                .filter { $0.isGuestPlaceholder && !$0.isTalkOver }
                .map(\.identityKey)
        ).count

        PersistenceGate.save(
            context,
            site: "SpeakerIdentityPass",
            critical: false,
            meetingID: meeting.id
        )
        GrokLibrary.upsert(meeting)

        let outcome = Outcome(
            audioChanged: audioChanged,
            selfIntroChanged: edits.selfIntroChanged,
            printChanged: edits.printChanged,
            unknownRemaining: unknown
        )
        if outcome.changed > 0 {
            SpeakerRepairService.invalidateSearchIndex(for: meeting)
            LogManager.send(
                "Speaker identity: audio \(outcome.audioChanged), self-intro \(outcome.selfIntroChanged), prints \(outcome.printChanged), \(outcome.unknownRemaining) unnamed left",
                category: .transcription,
                meetingID: meeting.id
            )
            TransientActivityCoordinator.shared.flash(
                "Named speakers from voice prints and self-introductions."
            )
        }
        return outcome
    }

    /// Calendar invitees, attendees, and every contact name/alias. Self-intro
    /// is a claimed name in the transcript, so a contact who was not ticked
    /// on the re-analyze sheet can still be Bob if they said "I'm Bob".
    static func rosterNames(meeting: Meeting, contacts: [Contact]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func append(_ raw: String?) {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            names.append(trimmed)
        }
        for attendee in meeting.attendees {
            append(attendee.name)
            attendee.speakerAliases.forEach { append($0) }
            append(attendee.nickname)
        }
        for contact in contacts where !contact.isArchived {
            append(contact.name)
            contact.speakerAliases.forEach { append($0) }
            append(contact.nickname)
        }
        return names
    }

    static func myLabels() -> [String] {
        [SpeakerNames.effectiveMeName, Speaker.defaultMeLabel].compactMap { $0 }
    }

    /// Ticked re-analyze people plus Me. Empty expected falls back to
    /// attendees + Me so an unattended recover still has someone to match.
    static func allowedPrintIDs(
        expected: [MeetingSpeakerRecovery.ExpectedSpeaker],
        meeting: Meeting
    ) -> Set<UUID> {
        var ids = Set(expected.compactMap(\.contactID))
        if let me = Meeting.storedMyContactID {
            ids.insert(me)
        }
        if expected.isEmpty {
            ids.formUnion(meeting.presentAttendees.map(\.id))
        }
        return ids
    }

    /// Self-introductions first (text, any contact or calendar name), then
    /// leftover speaker-N against attendee/Me (or ticked) voice prints and
    /// VoiceProfiles.json.
    @discardableResult
    static func applyIdentities(
        meeting: Meeting,
        contacts: [Contact],
        embeddings: [Speaker.IdentityKey: [Float]] = [:],
        printContactIDs: Set<UUID>? = nil
    ) -> IdentityEdits {
        let intro = SpeakerSelfIntroduction.apply(
            segments: meeting.segments,
            inviteeNames: rosterNames(meeting: meeting, contacts: contacts),
            myLabels: myLabels()
        )
        let prints = assignUnknownsFromPrints(
            meeting: meeting,
            contacts: contacts,
            embeddings: embeddings,
            printContactIDs: printContactIDs
        )
        return IdentityEdits(selfIntroChanged: intro, printChanged: prints)
    }

    /// Relabel remaining guest/unknown voices whose embedding matches a
    /// person who was actually on the call (attendee or Me). Whole-library
    /// matching is how Jordan won every remote cluster.
    static func assignUnknownsFromPrints(
        meeting: Meeting,
        contacts: [Contact],
        embeddings: [Speaker.IdentityKey: [Float]],
        printContactIDs: Set<UUID>? = nil
    ) -> Int {
        let pool = printCandidates(
            meeting: meeting,
            contacts: contacts,
            printContactIDs: printContactIDs
        )
        guard !pool.isEmpty else { return 0 }

        var unknowns: [Speaker] = []
        for segment in meeting.segments {
            let speaker = segment.speaker
            guard speaker.isGuestPlaceholder, !speaker.isTalkOver else { continue }
            if !unknowns.contains(where: { $0.matchesIdentity(speaker) }) {
                unknowns.append(speaker)
            }
        }
        guard !unknowns.isEmpty else { return 0 }

        var renamed: [Speaker.IdentityKey: Speaker] = [:]
        for unknown in unknowns {
            let embedding = embeddings[unknown.identityKey] ?? clusterEmbedding(for: unknown, meetingID: meeting.id)
            guard let embedding, embedding.count >= 8 else { continue }
            guard let hit = VoicePrintMatcher.identityAssignment(
                embedding: embedding,
                in: pool,
                identity: { $0.identityKey }
            ) else { continue }
            guard hit.kind == .unique || hit.kind == .near else { continue }
            renamed[unknown.identityKey] = hit.item
        }
        guard !renamed.isEmpty else { return 0 }

        var changed = 0
        for segment in meeting.segments {
            guard let dest = renamed[segment.speaker.identityKey] else { continue }
            if dest != segment.speaker {
                if segment.originalSpeakerData == nil {
                    segment.originalSpeakerData = segment.speakerData
                }
                segment.speaker = dest
                changed += 1
            }
        }
        return changed
    }

    static func enrollEmbedding(
        _ embedding: [Float],
        on contact: Contact,
        meetingID: UUID?,
        source: String,
        footprint: [Float]? = nil,
        usesFootprint: Bool = false
    ) {
        contact.addVoicePrint(
            embedding,
            meetingID: meetingID,
            source: source,
            footprint: footprint,
            usesFootprint: usesFootprint
        )
        VoiceProfileStore.enroll(
            embedding: embedding,
            contactID: contact.id,
            contactName: contact.name
        )
    }

    static func enrollMatchedPrints(
        meeting: Meeting,
        contacts: [Contact],
        embeddings: [Speaker.IdentityKey: [Float]],
        expected: [MeetingSpeakerRecovery.ExpectedSpeaker]
    ) {
        func contactFor(name: String, id: UUID?, isMe: Bool) -> Contact? {
            if let id, let existing = contacts.first(where: { $0.id == id }) { return existing }
            if isMe, let myID = Meeting.storedMyContactID,
               let me = contacts.first(where: { $0.id == myID }) {
                return me
            }
            if let existing = contacts.first(where: { $0.matchesSpeakerName(name) }) {
                return existing
            }
            return nil
        }

        for person in expected {
            let embedding = embeddings[person.speaker.identityKey]
            guard let embedding, embedding.count >= 8 else { continue }
            guard let contact = contactFor(name: person.name, id: person.contactID, isMe: person.isMe) else {
                continue
            }
            VoicePrintIsolation.isolate(embedding, owner: contact, among: contacts)
            enrollEmbedding(
                embedding,
                on: contact,
                meetingID: meeting.id,
                source: VoicePrintSource.reanalyze
            )
            rememberAlias(person.speaker.displayName, on: contact)
        }
    }

    static func rememberAlias(_ name: String, on contact: Contact) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !SpeakerLinkCatalog.isPlaceholder(trimmed) else { return }
        if contact.name.compare(trimmed, options: .caseInsensitive) == .orderedSame { return }
        if !contact.speakerAliases.contains(where: {
            $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            contact.speakerAliases.append(trimmed)
        }
    }

    private static func printCandidates(
        meeting: Meeting,
        contacts: [Contact],
        printContactIDs: Set<UUID>? = nil
    ) -> [(item: Speaker, embedding: [Float], footprint: [Float]?, usesFootprint: Bool)] {
        let meID = Meeting.storedMyContactID
        let allowed = printContactIDs
            ?? Set(meeting.presentAttendees.map(\.id) + [meID].compactMap { $0 })
        var pool: [(item: Speaker, embedding: [Float], footprint: [Float]?, usesFootprint: Bool)] = []
        for contact in contacts {
            guard allowed.contains(contact.id), contact.hasVoicePrint else { continue }
            let speaker: Speaker = contact.id == meID ? Speaker.resolvedMe() : .other(contact.name)
            let samples = contact.voicePrintSamples()
            for sample in samples {
                guard let embedding = sample.floats(), embedding.count >= 8 else { continue }
                pool.append((
                    item: speaker,
                    embedding: embedding,
                    footprint: sample.usesFootprint ? sample.footprintFloats() : nil,
                    usesFootprint: sample.usesFootprint
                ))
            }
        }
        let profiles = VoiceProfileStore.mergedProfiles(contacts: contacts.filter { allowed.contains($0.id) })
        for profile in profiles {
            guard allowed.contains(profile.contactID) else { continue }
            let speaker: Speaker = profile.contactID == meID
                ? Speaker.resolvedMe()
                : .other(profile.contactName)
            pool.append((
                item: speaker,
                embedding: profile.signature.vector,
                footprint: nil,
                usesFootprint: false
            ))
        }
        return pool
    }

    private static func clusterEmbedding(for speaker: Speaker, meetingID: UUID) -> [Float]? {
        let label = speaker.displayName
        guard let cluster = StorageManager.shared.loadVoiceClusters(for: meetingID)?
            .cluster(labelled: label)
            ?? StorageManager.shared.loadVoiceClusters(for: meetingID)?
            .clusters.first(where: { Speaker.other($0.label).matchesIdentity(speaker) })
        else { return nil }
        return cluster.signature.vector
    }
}
