import Foundation
import SwiftData
import SwiftUI

@Model
final class Contact {
    var id: UUID
    var name: String
    var nickname: String?
    var email: String?
    var isArchived: Bool = false
    var isInterviewer: Bool = false
    var createdAt: Date

    // Future: Microsoft Teams / external sync
    var externalID: String?
    var externalSource: String?

    // Speaker label aliases for auto-linking
    var speakerAliases: [String] = []

    /// WeSpeaker embedding (Float32 little-endian). Lets later meetings
    /// recognize this person instead of minting a new guest-N.
    /// Centroid of `voicePrintCollectionData` for older readers; the
    /// collection is the source of truth.
    var voicePrintData: Data?
    var voicePrintUpdatedAt: Date?

    /// JSON-encoded `[VoicePrintSample]`. One contact keeps many stamps
    /// (one per meeting / enrollment) so a later sample cannot overwrite
    /// earlier acoustic conditions.
    var voicePrintCollectionData: Data?

    /// Index into `SpeakerPalette.swatches`. Nil until assigned.
    var colorSlot: Int?
    var isColorLocked: Bool = false

    @Relationship(inverse: \Meeting.attendees)
    var meetings: [Meeting] = []

    @Relationship(inverse: \ActionItem.assignedContact)
    var assignedActionItems: [ActionItem] = []

    init(name: String, email: String? = nil) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.createdAt = .now
    }

    var hasVoicePrint: Bool {
        voicePrintSampleCount > 0
    }

    var voicePrintSampleCount: Int {
        voicePrintSamples().count
    }

    func voicePrintEmbedding() -> [Float]? {
        voicePrintEmbeddings().first
    }

    func voicePrintEmbeddings() -> [[Float]] {
        voicePrintSamples().compactMap { $0.floats() }
    }

    func voicePrintSamples() -> [VoicePrintSample] {
        let stored = VoicePrintCollectionCodec.decode(voicePrintCollectionData)
        if !stored.isEmpty { return stored }
        if let data = voicePrintData, VoicePrintCodec.decode(data) != nil {
            return [
                VoicePrintSample(
                    id: UUID(),
                    embedding: data,
                    createdAt: voicePrintUpdatedAt ?? createdAt,
                    meetingID: nil,
                    source: VoicePrintSource.legacy
                )
            ]
        }
        return []
    }

    func setVoicePrint(_ embedding: [Float]) {
        addVoicePrint(embedding, meetingID: nil, source: VoicePrintSource.enroll)
    }

    /// Append a sample. Never overwrites the collection; near-duplicates
    /// (cosine distance < 0.02) are skipped. The stored `voicePrintData`
    /// centroid stays in sync for anything still reading a single vector.
    func addVoicePrint(
        _ embedding: [Float],
        meetingID: UUID? = nil,
        source: String = VoicePrintSource.session,
        footprint: [Float]? = nil,
        usesFootprint: Bool = false
    ) {
        guard embedding.count >= 8 else { return }
        var samples = VoicePrintCollectionCodec.decode(voicePrintCollectionData)
        if samples.isEmpty, let data = voicePrintData, VoicePrintCodec.decode(data) != nil {
            samples = [
                VoicePrintSample(
                    id: UUID(),
                    embedding: data,
                    createdAt: voicePrintUpdatedAt ?? createdAt,
                    meetingID: nil,
                    source: VoicePrintSource.legacy
                )
            ]
        }
        if let index = samples.firstIndex(where: { sample in
            guard let existing = sample.floats(), existing.count == embedding.count else { return false }
            return VoicePrintMatcher.cosineDistance(existing, embedding) < 0.02
        }) {
            if usesFootprint, !samples[index].usesFootprint, let footprint, footprint.count >= 8 {
                samples[index].footprint = VoicePrintCodec.encode(footprint)
                samples[index].usesFootprint = true
                persistVoicePrintSamples(samples)
            }
            return
        }
        samples.append(.make(
            embedding: embedding,
            meetingID: meetingID,
            source: source,
            footprint: footprint,
            usesFootprint: usesFootprint
        ))
        if samples.count > VoicePrintCollectionCodec.maxSamples {
            samples.removeFirst(samples.count - VoicePrintCollectionCodec.maxSamples)
        }
        persistVoicePrintSamples(samples)
    }

    /// Average a new sample into the stored print so later enrollments
    /// tighten the match instead of replacing it outright.
    /// Kept as an alias of `addVoicePrint` — averaging smeared distinct
    /// acoustic conditions together and made Me steal remote voices.
    func mergeVoicePrint(_ embedding: [Float]) {
        addVoicePrint(embedding, meetingID: nil, source: VoicePrintSource.enroll)
    }

    func removeSamples(matching embedding: [Float], threshold: Float) {
        var samples = voicePrintSamples()
        let before = samples.count
        samples.removeAll { sample in
            guard let floats = sample.floats() else { return false }
            return VoicePrintMatcher.cosineDistance(floats, embedding) <= threshold
        }
        guard samples.count != before else { return }
        persistVoicePrintSamples(samples)
    }

    func clearVoicePrint() {
        voicePrintData = nil
        voicePrintUpdatedAt = nil
        voicePrintCollectionData = nil
    }

    private func persistVoicePrintSamples(_ samples: [VoicePrintSample]) {
        if samples.isEmpty {
            clearVoicePrint()
            return
        }
        voicePrintCollectionData = VoicePrintCollectionCodec.encode(samples)
        let embeddings = samples.compactMap { $0.floats() }
        if let centroid = Self.centroid(of: embeddings) {
            voicePrintData = VoicePrintCodec.encode(centroid)
            voicePrintUpdatedAt = samples.map(\.createdAt).max() ?? .now
        }
    }

    private static func centroid(of embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first, !first.isEmpty else { return nil }
        let width = first.count
        var acc = Array(repeating: Float(0), count: width)
        var count = 0
        for embedding in embeddings where embedding.count == width {
            for i in 0..<width { acc[i] += embedding[i] }
            count += 1
        }
        guard count > 0 else { return nil }
        return acc.map { $0 / Float(count) }
    }

    func asSpeakerLinkPerson() -> SpeakerLinkPerson {
        SpeakerLinkPerson(
            contactID: id,
            name: name,
            hasVoicePrint: hasVoicePrint,
            aliases: speakerAliases,
            meetingCount: meetings.count,
            isThisVoice: false,
            isMe: id == Meeting.storedMyContactID
        )
    }

    func matchesSpeakerName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if self.name.compare(trimmed, options: .caseInsensitive) == .orderedSame { return true }
        if speakerAliases.contains(where: {
            $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return true
        }
        if SpeakerNameMatcher.samePerson(self.name, trimmed) { return true }
        if speakerAliases.contains(where: { SpeakerNameMatcher.samePerson($0, trimmed) }) {
            return true
        }
        if let nickname, !nickname.isEmpty, SpeakerNameMatcher.samePerson(nickname, trimmed) {
            return true
        }
        return false
    }

    var firstName: String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    var displayNickname: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return firstName
    }

    var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var avatarColor: Color { paletteColor }

    var paletteColor: Color {
        if let colorSlot {
            return SpeakerPalette.color(slot: colorSlot)
        }
        return SpeakerPalette.color(forName: name)
    }
}
