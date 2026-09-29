import Foundation
import SwiftData

/// Float32 little-endian packing for a speaker embedding stored on a Contact.
enum VoicePrintCodec {
    static func encode(_ values: [Float]) -> Data {
        var copy = values
        return copy.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data?) -> [Float]? {
        guard let data, data.count >= MemoryLayout<Float>.size * 8 else { return nil }
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

/// Cosine-distance matching for live and enrolled speaker embeddings.
enum VoicePrintMatcher {
    /// New FluidAudio IDs in the same meeting (cosine distance).
    static let sessionDistance: Float = 0.38
    /// Cross-meeting enrolled prints. 0.52 was so loose that the only
    /// enrolled person (often Jordan) won every remote cluster.
    static let enrolledDistance: Float = 0.30
    /// Best match must beat the runner-up by this much, else leave unlabeled.
    static let matchMargin: Float = 0.08

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0 else { return 1 }
        return max(0, 1 - dot / denom)
    }

    static func bestMatch<T>(
        embedding: [Float],
        in candidates: [(item: T, embedding: [Float])],
        threshold: Float,
        margin: Float = 0
    ) -> (item: T, distance: Float)? {
        guard embedding.count >= 8, !candidates.isEmpty else { return nil }
        var ranked: [(item: T, distance: Float)] = []
        for candidate in candidates {
            guard candidate.embedding.count >= 8 else { continue }
            ranked.append((candidate.item, cosineDistance(embedding, candidate.embedding)))
        }
        ranked.sort { $0.distance < $1.distance }
        guard let best = ranked.first, best.distance <= threshold else { return nil }
        if margin > 0, ranked.count >= 2 {
            let second = ranked[1].distance
            if second - best.distance < margin { return nil }
        }
        return best
    }

    /// Match a probe against a collection of prints per person. Two samples of
    /// the same person never compete for the margin — only the closest print
    /// of each identity is ranked, so a well-enrolled contact cannot crowd out
    /// everyone else just by having more stamps.
    static func bestIdentityMatch<T, ID: Hashable>(
        embedding: [Float],
        in candidates: [(item: T, embedding: [Float])],
        identity: (T) -> ID,
        threshold: Float,
        margin: Float = 0
    ) -> (item: T, distance: Float)? {
        guard embedding.count >= 8, !candidates.isEmpty else { return nil }
        var bestPerIdentity: [ID: (item: T, distance: Float)] = [:]
        for candidate in candidates {
            guard candidate.embedding.count >= 8 else { continue }
            let id = identity(candidate.item)
            let distance = cosineDistance(embedding, candidate.embedding)
            if let existing = bestPerIdentity[id] {
                if distance < existing.distance {
                    bestPerIdentity[id] = (candidate.item, distance)
                }
            } else {
                bestPerIdentity[id] = (candidate.item, distance)
            }
        }
        let ranked = bestPerIdentity.values.sorted { $0.distance < $1.distance }
        guard let best = ranked.first, best.distance <= threshold else { return nil }
        if margin > 0, ranked.count >= 2 {
            let second = ranked[1].distance
            if second - best.distance < margin { return nil }
        }
        return best
    }
}

/// One WeSpeaker embedding kept on a contact. Contacts hold a collection of
/// these (one per enrollment / meeting) rather than a single averaged vector.
struct VoicePrintSample: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var embedding: Data
    var createdAt: Date
    var meetingID: UUID?
    var source: String

    func floats() -> [Float]? {
        VoicePrintCodec.decode(embedding)
    }

    static func make(
        embedding: [Float],
        meetingID: UUID? = nil,
        source: String
    ) -> VoicePrintSample {
        VoicePrintSample(
            id: UUID(),
            embedding: VoicePrintCodec.encode(embedding),
            createdAt: .now,
            meetingID: meetingID,
            source: source
        )
    }
}

enum VoicePrintSource {
    static let session = "session"
    static let enroll = "enroll"
    static let reanalyze = "reanalyze"
    static let legacy = "legacy"
}

enum VoicePrintCollectionCodec {
    static let maxSamples = 16

    static func encode(_ samples: [VoicePrintSample]) -> Data? {
        try? JSONEncoder().encode(samples)
    }

    static func decode(_ data: Data?) -> [VoicePrintSample] {
        guard let data,
              let samples = try? JSONDecoder().decode([VoicePrintSample].self, from: data)
        else { return [] }
        return samples
    }
}

/// When a new in-session print is assigned to someone, drop samples on other
/// contacts that are actually this same voice (the usual Me-was-Robert case).
enum VoicePrintIsolation {
    static func isolate(
        _ embedding: [Float],
        owner: Contact,
        among contacts: [Contact],
        threshold: Float = VoicePrintMatcher.enrolledDistance
    ) {
        for other in contacts where other.id != owner.id {
            other.removeSamples(matching: embedding, threshold: threshold)
        }
    }
}

/// Which stored voice stamps to load at record-start. Never the whole
/// People list — that made Jordan the default remote on every call.
enum VoicePrintSeeding {
    static func contactsToSeed(
        contacts: [Contact],
        meetingAttendeeIDs: Set<UUID>,
        myContactID: UUID?
    ) -> [Contact] {
        contacts.filter { contact in
            guard !contact.isArchived, contact.hasVoicePrint else { return false }
            if let myContactID, contact.id == myContactID { return true }
            return meetingAttendeeIDs.contains(contact.id)
        }
    }
}

/// A person the speaker menu can assign this voice to.
struct SpeakerLinkPerson: Identifiable, Hashable {
    var contactID: UUID?
    var name: String
    var hasVoicePrint: Bool
    var aliases: [String]
    var meetingCount: Int
    var isThisVoice: Bool
    var isMe: Bool = false

    var id: String {
        if let contactID { return contactID.uuidString }
        if isMe { return "me:\(name.lowercased())" }
        return "name:\(name.lowercased())"
    }

    func asSpeaker() -> Speaker {
        isMe ? Speaker.resolvedMe() : .other(name)
    }
}

struct SpeakerLinkGroups: Equatable {
    var thisMeeting: [SpeakerLinkPerson]
    var priorSpeakers: [SpeakerLinkPerson]

    static let empty = SpeakerLinkGroups(thisMeeting: [], priorSpeakers: [])

    var isEmpty: Bool { thisMeeting.isEmpty && priorSpeakers.isEmpty }
}

/// Split People contacts + transcript names into "this meeting" vs people
/// who have spoken (or been tagged) before.
enum SpeakerLinkCatalog {
    static func groups(
        people: [SpeakerLinkPerson],
        transcriptNames: [String],
        attendeeNames: [String],
        meName: String?,
        currentSpeakerName: String
    ) -> SpeakerLinkGroups {
        var meetingNames: [String] = []
        func consider(_ raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isPlaceholder(name) else { return }
            if meetingNames.contains(where: { $0.compare(name, options: .caseInsensitive) == .orderedSame }) {
                return
            }
            meetingNames.append(name)
        }
        if let meName { consider(meName) }
        for name in attendeeNames { consider(name) }
        for name in transcriptNames { consider(name) }

        let thisMeeting = meetingNames.map { name in
            var person = resolvedPerson(named: name, in: people, currentSpeakerName: currentSpeakerName)
            if let meName, isMeName(name, meName: meName) {
                person.isMe = true
            }
            return person
        }

        let meetingKeys = Set(thisMeeting.map { $0.id })
        var prior: [SpeakerLinkPerson] = []
        for person in people {
            guard person.hasVoicePrint || !person.aliases.isEmpty || person.meetingCount > 0 else { continue }
            if meetingKeys.contains(person.id) { continue }
            if thisMeeting.contains(where: { $0.name.compare(person.name, options: .caseInsensitive) == .orderedSame }) {
                continue
            }
            var copy = person
            copy.isThisVoice = matches(person, name: currentSpeakerName)
            prior.append(copy)
        }
        prior.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return SpeakerLinkGroups(thisMeeting: thisMeeting, priorSpeakers: prior)
    }

    static func isPlaceholder(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        if lower == "me" || lower == "other" || lower == "speaker" || lower == "unknown" {
            return true
        }
        if lower.hasPrefix("speaker ") { return true }
        if lower.hasPrefix("guest-") { return true }
        if lower.hasPrefix("unknown-") { return true }
        if lower.hasPrefix("speaker-") { return true }
        return Speaker.remoteIndex(fromLegacyName: name) != nil
    }

    private static func resolvedPerson(
        named name: String,
        in people: [SpeakerLinkPerson],
        currentSpeakerName: String
    ) -> SpeakerLinkPerson {
        if let existing = people.first(where: { matches($0, name: name) }) {
            var copy = existing
            copy.isThisVoice = matches(existing, name: currentSpeakerName)
            return copy
        }
        return SpeakerLinkPerson(
            contactID: nil,
            name: name,
            hasVoicePrint: false,
            aliases: [],
            meetingCount: 0,
            isThisVoice: name.compare(currentSpeakerName, options: .caseInsensitive) == .orderedSame
        )
    }

    private static func matches(_ person: SpeakerLinkPerson, name: String) -> Bool {
        if person.isMe, isMeName(name, meName: person.name) { return true }
        if person.name.compare(name, options: .caseInsensitive) == .orderedSame { return true }
        return person.aliases.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    private static func isMeName(_ name: String, meName: String) -> Bool {
        if name.compare(meName, options: .caseInsensitive) == .orderedSame { return true }
        if name.compare(Speaker.defaultMeLabel, options: .caseInsensitive) == .orderedSame { return true }
        return SpeakerNameMatcher.samePerson(name, meName)
    }
}

enum VoicePrintUIState: Equatable {
    case ready(onto: String?)
    case enrolled(onto: String, at: Date?, samples: Int)
    case working
    case failed(String)
    case needsPerson
}

enum VoicePrintEnrollmentProgress: Equatable {
    case idle
    case working(Speaker.IdentityKey)
    case failed(Speaker.IdentityKey, String)
}
