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

    /// How much a room/mic footprint may pull the blended distance. Voice
    /// still leads; 0.4 is enough for a wet, hissy far-end to beat a dry mix.
    static let footprintWeight: Float = 0.40
    /// Close enough to a known voice that this is probably them (or a mix
    /// that includes them), even when the unique-match margin fails.
    static let nearDistance: Float = 0.44
    /// When #1 and #2 are both near and this close to each other, the probe
    /// is two people talking at once — not a third person.
    static let mashupMargin: Float = 0.10

    enum AssignmentKind: Equatable, Sendable {
        case unique
        case near
        case mashup
    }

    static func blendedDistance(
        probeEmbedding: [Float],
        probeFootprint: [Float]?,
        candidateEmbedding: [Float],
        candidateFootprint: [Float]?,
        candidateUsesFootprint: Bool,
        footprintWeight: Float = footprintWeight
    ) -> Float {
        let voice = cosineDistance(probeEmbedding, candidateEmbedding)
        guard candidateUsesFootprint,
              let probeFootprint, probeFootprint.count >= 8,
              let candidateFootprint, candidateFootprint.count == probeFootprint.count
        else { return voice }
        let foot = cosineDistance(probeFootprint, candidateFootprint)
        return voice * (1 - footprintWeight) + foot * footprintWeight
    }

    /// Unique match, a near miss, or a two-voice mashup. Nil only when the
    /// probe is far from everyone — that is the only case that should mint
    /// a new speaker-N.
    static func identityAssignment<T, ID: Hashable>(
        embedding: [Float],
        footprint: [Float]? = nil,
        in candidates: [(item: T, embedding: [Float], footprint: [Float]?, usesFootprint: Bool)],
        identity: (T) -> ID,
        uniqueThreshold: Float = enrolledDistance,
        uniqueMargin: Float = matchMargin,
        nearThreshold: Float = nearDistance,
        mashupMargin: Float = mashupMargin
    ) -> (item: T, distance: Float, kind: AssignmentKind)? {
        guard embedding.count >= 8, !candidates.isEmpty else { return nil }
        var bestPerIdentity: [ID: (item: T, distance: Float)] = [:]
        for candidate in candidates {
            guard candidate.embedding.count >= 8 else { continue }
            let id = identity(candidate.item)
            let distance = blendedDistance(
                probeEmbedding: embedding,
                probeFootprint: footprint,
                candidateEmbedding: candidate.embedding,
                candidateFootprint: candidate.footprint,
                candidateUsesFootprint: candidate.usesFootprint
            )
            if let existing = bestPerIdentity[id] {
                if distance < existing.distance {
                    bestPerIdentity[id] = (candidate.item, distance)
                }
            } else {
                bestPerIdentity[id] = (candidate.item, distance)
            }
        }
        let ranked = bestPerIdentity.values.sorted { $0.distance < $1.distance }
        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first
        if best.distance <= uniqueThreshold {
            if let second {
                if second.distance - best.distance < uniqueMargin, second.distance <= nearThreshold {
                    return (best.item, best.distance, .mashup)
                }
                if second.distance - best.distance >= uniqueMargin {
                    return (best.item, best.distance, .unique)
                }
            } else {
                return (best.item, best.distance, .unique)
            }
        }
        if let second,
           best.distance <= nearThreshold,
           second.distance <= nearThreshold,
           second.distance - best.distance < mashupMargin {
            return (best.item, best.distance, .mashup)
        }
        if best.distance <= nearThreshold {
            return (best.item, best.distance, .near)
        }
        return nil
    }
}

enum VoicePrintSettings {
    static let includeFootprintKey = "voicePrintIncludeFootprint"

    /// Default on: WeSpeaker already tries to ignore the room, so the
    /// extra stamp is how a wet/hissy far-end stays identifiable.
    static var includeFootprint: Bool {
        if UserDefaults.standard.object(forKey: includeFootprintKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: includeFootprintKey)
    }
}

/// Channel / room vector: spectral envelope, noise floor, reverb smear.
/// WeSpeaker is trained to discard this; these numbers keep it.
enum AcousticFootprint {
    static let dimension = 24
    static let minSamples = 1_600

    static func extract(_ samples: [Float], sampleRate: Float = 16_000) -> [Float] {
        guard samples.count >= minSamples else { return [] }
        let bands = bandEnergies(samples, sampleRate: sampleRate)
        let frame = max(80, Int(sampleRate * 0.025))
        let hop = max(40, Int(sampleRate * 0.010))
        let energies = frameEnergies(samples, frame: frame, hop: hop)
        let quiet = quietSamples(samples, energies: energies, frame: frame, hop: hop)
        let quietBands: [Float]
        if quiet.count >= minSamples {
            quietBands = bandEnergies(quiet, sampleRate: sampleRate)
        } else {
            quietBands = Array(repeating: 0, count: 8)
        }
        let noise = percentileRMS(energies, percentile: 0.2)
        let peak = energies.max() ?? 0
        let mean = energies.reduce(0, +) / Float(max(energies.count, 1))
        let snr = noise > 0 ? (percentileRMS(energies, percentile: 0.8) / noise) : 0
        let crest = mean > 0 ? peak / mean : 0
        let zcr = zeroCrossingRate(samples)
        let corr25 = lagCorr(energies, lag: max(1, Int(0.025 * sampleRate / Float(hop))))
        let corr50 = lagCorr(energies, lag: max(1, Int(0.050 * sampleRate / Float(hop))))
        let corr100 = lagCorr(energies, lag: max(1, Int(0.100 * sampleRate / Float(hop))))
        let corr200 = lagCorr(energies, lag: max(1, Int(0.200 * sampleRate / Float(hop))))
        let high = bands.suffix(2).reduce(0, +)
        let total = bands.reduce(0, +)
        let highRatio = total > 0 ? high / total : 0
        var features = bands.map { log1p($0) }
        features.append(log1p(noise))
        features.append(log1p(snr))
        features.append(log1p(crest))
        features.append(zcr)
        features.append(contentsOf: [corr25, corr50, corr100, corr200])
        features.append(highRatio)
        features.append(contentsOf: quietBands.prefix(6).map { log1p($0) })
        while features.count < dimension { features.append(0) }
        if features.count > dimension { features = Array(features.prefix(dimension)) }
        return l2normalize(features)
    }

    static func slice(
        _ samples: [Float],
        start: TimeInterval,
        end: TimeInterval,
        sampleRate: Float = 16_000
    ) -> [Float] {
        guard !samples.isEmpty, end > start else { return [] }
        let lo = max(0, Int(start * TimeInterval(sampleRate)))
        let hi = min(samples.count, Int(end * TimeInterval(sampleRate)))
        guard hi > lo else { return [] }
        return Array(samples[lo..<hi])
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Mean envelope correlation at 100 ms and 200 ms. Far-end rooms and
    /// cheap mics stay high; a dry local headset does not.
    static func lateReverb(_ samples: [Float], sampleRate: Float = 16_000) -> Float {
        guard samples.count >= minSamples else { return 0 }
        let frame = max(80, Int(sampleRate * 0.025))
        let hop = max(40, Int(sampleRate * 0.010))
        let energies = frameEnergies(samples, frame: frame, hop: hop)
        let corr100 = lagCorr(energies, lag: max(1, Int(0.100 * sampleRate / Float(hop))))
        let corr200 = lagCorr(energies, lag: max(1, Int(0.200 * sampleRate / Float(hop))))
        return max(0, (corr100 + corr200) / 2)
    }

    private static func bandEnergies(_ samples: [Float], sampleRate: Float) -> [Float] {
        let cuts: [Float] = [250, 500, 1_000, 2_000, 4_000, 6_000, 8_000]
        var prev = samples
        var energies: [Float] = []
        for cutoff in cuts {
            let low = lowpass(prev, cutoffHz: cutoff, sampleRate: sampleRate)
            energies.append(meanSquare(low))
            var residual = [Float](repeating: 0, count: prev.count)
            for i in prev.indices { residual[i] = prev[i] - low[i] }
            prev = residual
        }
        energies.append(meanSquare(prev))
        while energies.count < 8 { energies.append(0) }
        return Array(energies.prefix(8))
    }

    private static func lowpass(_ x: [Float], cutoffHz: Float, sampleRate: Float) -> [Float] {
        let nyquist = sampleRate / 2
        let fc = min(max(cutoffHz, 1), nyquist * 0.95)
        let alpha = 1 - exp(-2 * Float.pi * fc / sampleRate)
        var y: Float = 0
        var out = [Float](repeating: 0, count: x.count)
        for i in x.indices {
            y += alpha * (x[i] - y)
            out[i] = y
        }
        return out
    }

    private static func meanSquare(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in x { sum += sample * sample }
        return sum / Float(x.count)
    }

    private static func frameEnergies(_ samples: [Float], frame: Int, hop: Int) -> [Float] {
        var out: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for n in i..<(i + frame) { e += samples[n] * samples[n] }
            out.append(e / Float(frame))
            i += hop
        }
        return out
    }

    private static func quietSamples(
        _ samples: [Float],
        energies: [Float],
        frame: Int,
        hop: Int
    ) -> [Float] {
        guard !energies.isEmpty else { return [] }
        let sorted = energies.sorted()
        let cutoff = sorted[min(sorted.count - 1, sorted.count / 3)]
        var quiet: [Float] = []
        for (index, energy) in energies.enumerated() where energy <= cutoff {
            let start = index * hop
            let end = min(samples.count, start + frame)
            if end > start { quiet.append(contentsOf: samples[start..<end]) }
        }
        return quiet
    }

    private static func percentileRMS(_ energies: [Float], percentile: Float) -> Float {
        guard !energies.isEmpty else { return 0 }
        let sorted = energies.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * percentile)))
        return sorted[idx].squareRoot()
    }

    private static func zeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            if samples[i] == 0 { continue }
            if samples[i - 1] == 0 { continue }
            if (samples[i] > 0) != (samples[i - 1] > 0) { crossings += 1 }
        }
        return Float(crossings) / Float(samples.count - 1)
    }

    private static func lagCorr(_ series: [Float], lag: Int) -> Float {
        guard series.count > lag + 4, lag > 0 else { return 0 }
        let n = series.count - lag
        var mean0: Float = 0
        var mean1: Float = 0
        for i in 0..<n {
            mean0 += series[i]
            mean1 += series[i + lag]
        }
        let count = Float(n)
        mean0 /= count
        mean1 /= count
        var num: Float = 0
        var d0: Float = 0
        var d1: Float = 0
        for i in 0..<n {
            let a = series[i] - mean0
            let b = series[i + lag] - mean1
            num += a * b
            d0 += a * a
            d1 += b * b
        }
        let den = (d0 * d1).squareRoot()
        return den > 0 ? max(-1, min(1, num / den)) : 0
    }

    private static func l2normalize(_ values: [Float]) -> [Float] {
        var sum: Float = 0
        for value in values { sum += value * value }
        let mag = sum.squareRoot()
        guard mag > 0 else { return values }
        return values.map { $0 / mag }
    }
}

/// Overlapping talk lands between two known voices. Label it Talk-over
/// instead of minting speaker-3.
enum OverlapMashup {
    static let minimumKeepSeconds: TimeInterval = 20

    static func reassign(
        turns: [DiarizedSegment],
        samples: [Float],
        sampleRate: Float = 16_000,
        expected: [MeetingSpeakerRecovery.ExpectedSpeaker]
    ) -> [DiarizedSegment] {
        var known: [(item: Speaker, embedding: [Float], footprint: [Float]?, usesFootprint: Bool)] = []
        for person in expected {
            let prints = person.allEmbeddings()
            for (index, embedding) in prints.enumerated() {
                let foot: [Float]?
                if person.footprints.isEmpty {
                    foot = nil
                } else {
                    foot = person.footprints[min(index, person.footprints.count - 1)]
                }
                known.append((
                    item: person.speaker,
                    embedding: embedding,
                    footprint: foot,
                    usesFootprint: person.usesFootprint
                ))
            }
        }
        guard !known.isEmpty else { return turns }

        var totals: [Speaker.IdentityKey: TimeInterval] = [:]
        for turn in turns {
            totals[turn.speaker.identityKey, default: 0] += max(0, turn.endTime - turn.startTime)
        }

        return turns.map { turn in
            let weak = turn.speaker.isUnknownPlaceholder
                || turn.speaker.isGuestPlaceholder
                || (totals[turn.speaker.identityKey] ?? 0) < minimumKeepSeconds
            guard weak else { return turn }
            let slice = AcousticFootprint.slice(
                samples,
                start: turn.startTime,
                end: turn.endTime,
                sampleRate: sampleRate
            )
            let footprint = AcousticFootprint.extract(slice, sampleRate: sampleRate)
            let probe = turn.embedding.count >= 8 ? turn.embedding : nil
            guard let probe else { return turn }
            guard let hit = VoicePrintMatcher.identityAssignment(
                embedding: probe,
                footprint: footprint.count >= 8 ? footprint : nil,
                in: known,
                identity: { $0.identityKey }
            ) else { return turn }
            return DiarizedSegment(
                speaker: hit.kind == .mashup ? .talkOver : hit.item,
                startTime: turn.startTime,
                endTime: turn.endTime,
                confidence: turn.confidence,
                speakerID: turn.speakerID,
                embedding: turn.embedding
            )
        }
    }
}

/// Where the sound came from beats the voice model: local mic is you,
/// system audio is everyone else, both at once is Talk-over.
enum DualTrackOverlap {
    static let speechRMS: Float = 0.012
    /// One track must be this many times louder to own the line.
    static let dominance: Float = 3
    /// Far-end rooms sit above this on system-track late reverb.
    static let reverbFloor: Float = 0.40

    enum Kind: Equatable, Sendable {
        case me
        case remote
        case talkOver
    }

    static func classify(
        micRMS: Float,
        sysRMS: Float,
        systemReverb: Float = 0
    ) -> Kind? {
        let micHot = micRMS >= speechRMS
        let sysHot = sysRMS >= speechRMS
        if !micHot && !sysHot { return nil }
        if micHot && !sysHot { return .me }
        if sysHot && !micHot { return .remote }
        if systemReverb >= reverbFloor, micRMS < sysRMS {
            return .remote
        }
        if micRMS >= sysRMS * dominance { return .me }
        if sysRMS >= micRMS * dominance { return .remote }
        return .talkOver
    }

    static func resolve(
        proposed: Speaker,
        start: TimeInterval,
        end: TimeInterval,
        offset: TimeInterval,
        mic: [Float],
        system: [Float],
        sampleRate: Float = 16_000,
        me: Speaker = .me,
        remotes: [Speaker] = []
    ) -> Speaker {
        let micRMS = sliceRMS(mic, start: start, end: end, offset: offset, sampleRate: sampleRate)
        let sysRMS = sliceRMS(system, start: start, end: end, offset: offset, sampleRate: sampleRate)
        let sysSlice = AcousticFootprint.slice(
            system,
            start: start - offset,
            end: end - offset,
            sampleRate: sampleRate
        )
        let reverb = AcousticFootprint.lateReverb(sysSlice, sampleRate: sampleRate)
        guard let kind = classify(micRMS: micRMS, sysRMS: sysRMS, systemReverb: reverb) else {
            return proposed
        }
        switch kind {
        case .me:
            return me
        case .talkOver:
            return .talkOver
        case .remote:
            if proposed.isMe || proposed.isTalkOver {
                return remotes.count == 1
                    ? remotes[0]
                    : .other(Speaker.placeholderLabel(index: 1))
            }
            return proposed
        }
    }

    static func sliceRMS(
        _ samples: [Float],
        start: TimeInterval,
        end: TimeInterval,
        offset: TimeInterval,
        sampleRate: Float
    ) -> Float {
        let slice = AcousticFootprint.slice(
            samples,
            start: start - offset,
            end: end - offset,
            sampleRate: sampleRate
        )
        return AcousticFootprint.rms(slice)
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
    var footprint: Data?
    var usesFootprint: Bool

    enum CodingKeys: String, CodingKey {
        case id, embedding, createdAt, meetingID, source, footprint, usesFootprint
    }

    init(
        id: UUID,
        embedding: Data,
        createdAt: Date,
        meetingID: UUID?,
        source: String,
        footprint: Data? = nil,
        usesFootprint: Bool = false
    ) {
        self.id = id
        self.embedding = embedding
        self.createdAt = createdAt
        self.meetingID = meetingID
        self.source = source
        self.footprint = footprint
        self.usesFootprint = usesFootprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        embedding = try container.decode(Data.self, forKey: .embedding)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        meetingID = try container.decodeIfPresent(UUID.self, forKey: .meetingID)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? VoicePrintSource.legacy
        footprint = try container.decodeIfPresent(Data.self, forKey: .footprint)
        usesFootprint = try container.decodeIfPresent(Bool.self, forKey: .usesFootprint) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(embedding, forKey: .embedding)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(meetingID, forKey: .meetingID)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(footprint, forKey: .footprint)
        try container.encode(usesFootprint, forKey: .usesFootprint)
    }

    func floats() -> [Float]? {
        VoicePrintCodec.decode(embedding)
    }

    func footprintFloats() -> [Float]? {
        VoicePrintCodec.decode(footprint)
    }

    static func make(
        embedding: [Float],
        meetingID: UUID? = nil,
        source: String,
        footprint: [Float]? = nil,
        usesFootprint: Bool = false
    ) -> VoicePrintSample {
        let foot = (usesFootprint && (footprint?.count ?? 0) >= 8) ? footprint : nil
        return VoicePrintSample(
            id: UUID(),
            embedding: VoicePrintCodec.encode(embedding),
            createdAt: .now,
            meetingID: meetingID,
            source: source,
            footprint: foot.map { VoicePrintCodec.encode($0) },
            usesFootprint: foot != nil
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
        currentSpeakerName: String,
        currentIsMe: Bool = false
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
            person.isThisVoice = isCurrentVoice(
                person,
                currentSpeakerName: currentSpeakerName,
                currentIsMe: currentIsMe
            )
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
            copy.isThisVoice = isCurrentVoice(
                copy,
                currentSpeakerName: currentSpeakerName,
                currentIsMe: currentIsMe
            )
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
        if Speaker.isTalkOverName(name) { return true }
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

    /// A Me line renamed to someone else's name is still Me. The Speakers
    /// list must not treat that name match as "already assigned" or the
    /// click that would turn this voice into that person is a no-op.
    private static func isCurrentVoice(
        _ person: SpeakerLinkPerson,
        currentSpeakerName: String,
        currentIsMe: Bool
    ) -> Bool {
        if person.isMe { return currentIsMe }
        if currentIsMe { return false }
        return matches(person, name: currentSpeakerName)
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
