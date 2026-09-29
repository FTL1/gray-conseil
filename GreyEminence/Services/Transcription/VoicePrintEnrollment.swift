import Foundation
import SwiftData

/// Pull a speaker embedding out of a meeting's saved audio and write it
/// onto a Contact. Live sessions prefer the in-memory diarizer snapshot
/// and only fall back to this when that snapshot is missing.
enum VoicePrintEnrollment {
    enum EnrollmentError: LocalizedError {
        case notEnoughAudio
        case noRecording
        case extractionFailed
        case needsPerson

        var errorDescription: String? {
            switch self {
            case .notEnoughAudio:
                "Not enough audio yet — let them talk a few more seconds, then try again."
            case .noRecording:
                "No recording on disk to enroll from."
            case .extractionFailed:
                "Could not extract a voice print from this audio."
            case .needsPerson:
                "Pick someone in This meeting or Prior speakers first."
            }
        }
    }

    struct Request: Sendable {
        var audioBaseURLs: [URL]
        var ranges: [(start: TimeInterval, end: TimeInterval)]
        var audioOffset: TimeInterval
        var meetingID: UUID?
    }

    static func request(
        for speaker: Speaker,
        in meeting: Meeting,
        segments: [TranscriptSegment]
    ) -> Request? {
        let theirs = segments.filter { $0.speaker.matchesIdentity(speaker) && $0.isFinal }
        guard !theirs.isEmpty else { return nil }
        let audioID = meeting.audioSourceMeetingID ?? meeting.id
        // Always consider both tracks. A remote voice stamped as Me would
        // otherwise enroll from the microphone (the local user) and poison
        // the stamp.
        let bases = [
            StorageManager.shared.micAudioURL(for: audioID),
            StorageManager.shared.systemAudioURL(for: audioID)
        ].filter { !AudioFileWriter.existingChunkURLs(base: $0).isEmpty }
        guard !bases.isEmpty else { return nil }
        let ranges = theirs.prefix(40).map { ($0.startTime, $0.endTime) }
        return Request(
            audioBaseURLs: bases,
            ranges: Array(ranges),
            audioOffset: meeting.audioStartOffset,
            meetingID: meeting.id
        )
    }

    static func extractEmbedding(_ request: Request) async throws -> [Float] {
        let samples = try sliceSamples(request)
        guard samples.count >= 48_000 else { throw EnrollmentError.notEnoughAudio }
        let service = SpeakerDiarizationService()
        try await service.prepare()
        guard let embedding = try await service.extractDominantEmbedding(from: samples) else {
            throw EnrollmentError.extractionFailed
        }
        return embedding
    }

    static func resolveContact(
        for speaker: Speaker,
        contacts: [Contact],
        mapped: Contact?
    ) -> Contact? {
        if let mapped { return mapped }
        if speaker.isMe, let myID = Meeting.storedMyContactID {
            if let me = contacts.first(where: { $0.id == myID }) {
                let display = speaker.displayName
                if !me.matchesSpeakerName(display),
                   let other = contacts.first(where: {
                       !$0.isArchived && $0.id != myID && $0.matchesSpeakerName(display)
                   }) {
                    return other
                }
                return me
            }
        }
        if speaker.isGuestPlaceholder { return nil }
        return contacts.first { $0.matchesSpeakerName(speaker.displayName) }
    }

    private static func sliceSamples(_ request: Request) throws -> [Float] {
        var tracks: [[Float]] = []
        for base in request.audioBaseURLs {
            let urls = AudioFileWriter.existingChunkURLs(base: base)
            var full: [Float] = []
            for url in urls {
                if let chunk = try? HighQualityTranscriber.decodeFileTo16kFloatMono(url: url) {
                    full.append(contentsOf: chunk)
                }
            }
            if !full.isEmpty { tracks.append(full) }
        }
        guard !tracks.isEmpty else { throw EnrollmentError.noRecording }

        let rate: Double = 16_000
        var sliced: [Float] = []
        sliced.reserveCapacity(16_000 * 12)
        for range in request.ranges {
            var best: [Float] = []
            var bestRMS: Float = -1
            for full in tracks {
                let start = max(0, Int((range.start - request.audioOffset) * rate))
                let end = min(full.count, Int((range.end - request.audioOffset) * rate))
                guard end > start else { continue }
                let slice = Array(full[start..<end])
                let energy = rms(slice)
                if energy > bestRMS {
                    bestRMS = energy
                    best = slice
                }
            }
            sliced.append(contentsOf: best)
            if sliced.count >= 16_000 * 30 { break }
        }
        if sliced.count < 48_000 {
            if let longest = tracks.max(by: { $0.count < $1.count }), longest.count >= 48_000 {
                return Array(longest.prefix(16_000 * 20))
            }
        }
        return sliced
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func louder(_ a: [Float], _ b: [Float]) -> [Float] {
        rms(a) >= rms(b) ? a : b
    }
}
