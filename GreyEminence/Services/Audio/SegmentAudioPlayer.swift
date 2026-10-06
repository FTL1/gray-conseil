import AVFoundation
import Foundation

/// Plays the recorded audio behind one transcript segment.
///
/// Built for a diagnostic question — "is the audio bad, or is the transcript
/// bad?" — so it plays the track the words actually came from: the
/// microphone for the user's own segments, system audio for everyone else.
/// Mixing the two would hide exactly the difference being listened for; the
/// user can still pick a track explicitly.
///
/// One player, app-wide: starting a segment stops whatever was playing.
struct AudioPlaySlice: Equatable {
    var url: URL
    var localStart: TimeInterval
    var duration: TimeInterval
}

/// Plays the saved mic or system-audio slice for one transcript line.
/// A merged line plays the full start…end range, walking consecutive
/// on-disk chunks if the recording was split across files.
@Observable
@MainActor
final class SegmentAudioPlayer {

    static let shared = SegmentAudioPlayer()

    enum Track: String, CaseIterable, Identifiable {
        /// Microphone for "Me", system audio for everyone else.
        case speaker
        case mic
        case system
        case both

        var id: String { rawValue }

        var label: String {
            switch self {
            case .speaker: "Speaker's own track"
            case .mic: "Microphone only"
            case .system: "System audio only"
            case .both: "Both, mixed"
            }
        }
    }

    static let trackKey = "segmentPlaybackTrack"
    static let trackDefaultedToBothKey = "segmentPlaybackTrackDefaultedToBoth"

    /// The segment currently playing, for the row that started it.
    private(set) var playingSegmentID: UUID?
    /// Why the last attempt could not play, keyed to the segment it was for.
    private(set) var failure: (segmentID: UUID, message: String)?

    var track: Track {
        didSet { UserDefaults.standard.set(track.rawValue, forKey: Self.trackKey) }
    }

    /// One chain per recorded file (mic, system, or both). AVAudioPlayer
    /// plays the file at its own sample rate — a composition with the
    /// video timescale 600 was the 10×-fast path.
    private var chains: [PlayChain] = []

    private init() {
        if !UserDefaults.standard.bool(forKey: Self.trackDefaultedToBothKey) {
            // Lines stamped as Me used to play only the microphone, so a
            // remote voice labeled as you sounded like the wrong person.
            track = .both
            UserDefaults.standard.set(true, forKey: Self.trackDefaultedToBothKey)
            UserDefaults.standard.set(Track.both.rawValue, forKey: Self.trackKey)
        } else {
            let stored = UserDefaults.standard.string(forKey: Self.trackKey) ?? ""
            track = Track(rawValue: stored) ?? .both
        }
    }

    func toggle(
        _ segment: TranscriptSegment,
        in meeting: Meeting,
        until nextStart: TimeInterval? = nil,
        previousEnd: TimeInterval? = nil
    ) {
        if playingSegmentID == segment.id {
            stop()
        } else {
            play(segment, in: meeting, until: nextStart, previousEnd: previousEnd)
        }
    }

    func play(
        _ segment: TranscriptSegment,
        in meeting: Meeting,
        until nextStart: TimeInterval? = nil,
        previousEnd: TimeInterval? = nil
    ) {
        stop()
        failure = nil

        // Read models here on the main actor; AVAudioPlayer never touches SwiftData.
        let segmentID = segment.id
        let sourceMeetingID = meeting.audioSourceMeetingID ?? meeting.id
        let window = SegmentAudioLocator.window(
            segmentStart: segment.startTime,
            segmentEnd: segment.endTime,
            offset: meeting.audioStartOffset,
            nextStart: nextStart,
            previousEnd: previousEnd
        )
        let sources = Self.sources(for: track, isMe: segment.speaker.isMe)
        let storage = StorageManager.shared
        let bases: [(Track, URL)] = sources.map { source in
            (source, source == .mic
                ? storage.micAudioURL(for: sourceMeetingID)
                : storage.systemAudioURL(for: sourceMeetingID))
        }

        do {
            playingSegmentID = segmentID
            var started = false
            for (_, base) in bases {
                let chunks = AudioFileWriter.existingChunkURLs(base: base)
                let slices = SegmentAudioLocator.slices(covering: window, chunks: chunks) {
                    HighQualityTranscriber.assumedDuration(of: $0, fallback: 10)
                }.map {
                    AudioPlaySlice(url: $0.url, localStart: $0.start, duration: $0.duration)
                }
                guard !slices.isEmpty else { continue }
                let chain = PlayChain(remaining: slices)
                chains.append(chain)
                try playNext(chain, segmentID: segmentID)
                started = true
            }
            guard started else { throw PlaybackError.noAudio }
        } catch {
            stop()
            failure = (segmentID, error.localizedDescription)
            LogManager.send(
                "Segment playback failed: \(error.localizedDescription)",
                category: .audio,
                level: .warning,
                meetingID: meeting.id
            )
        }
    }

    func stop() {
        for chain in chains {
            chain.work?.cancel()
            chain.work = nil
            chain.player?.stop()
            chain.player = nil
            chain.remaining = []
        }
        chains = []
        playingSegmentID = nil
    }

    // MARK: - Internals

    /// Which recorded tracks to play for a segment.
    static func sources(for track: Track, isMe: Bool) -> [Track] {
        switch track {
        case .speaker: isMe ? [.mic] : [.system]
        case .mic: [.mic]
        case .system: [.system]
        case .both: [.mic, .system]
        }
    }

    private func playNext(_ chain: PlayChain, segmentID: UUID) throws {
        guard let slice = chain.remaining.first else {
            chain.player?.stop()
            chain.player = nil
            if chains.allSatisfy({ $0.remaining.isEmpty && $0.player == nil }) {
                stop()
            }
            return
        }
        chain.remaining.removeFirst()
        let player = try AVAudioPlayer(contentsOf: slice.url)
        player.enableRate = false
        player.currentTime = min(slice.localStart, max(0, player.duration - 0.05))
        let playFor = Self.playDuration(playerDuration: player.duration, slice: slice)
        guard player.play() else { throw PlaybackError.noAudio }
        chain.player = player
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.playingSegmentID == segmentID else { return }
                try? self.playNext(chain, segmentID: segmentID)
            }
        }
        chain.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + playFor, execute: work)
    }

    /// How long AVAudioPlayer should run this slice. Uses the file's own
    /// duration so a 1 s window never finishes in 0.1 s.
    nonisolated static func playDuration(
        playerDuration: TimeInterval,
        slice: AudioPlaySlice
    ) -> TimeInterval {
        let start = min(slice.localStart, max(0, playerDuration - 0.05))
        return min(slice.duration, max(0.05, playerDuration - start))
    }

    enum PlaybackError: LocalizedError {
        case noAudio

        var errorDescription: String? {
            "No recorded audio on disk for this segment"
        }
    }

    /// Walk the recording's chunk files and return the slices covering [from, to).
    nonisolated static func slices(
        files: [(url: URL, duration: TimeInterval)],
        from: TimeInterval,
        to: TimeInterval
    ) -> [AudioPlaySlice] {
        guard to > from else { return [] }
        var cursor: TimeInterval = 0
        var result: [AudioPlaySlice] = []
        for file in files {
            let fileEnd = cursor + file.duration
            if fileEnd > from && cursor < to {
                let localStart = max(0, from - cursor)
                let localEnd = min(file.duration, to - cursor)
                if localEnd > localStart {
                    result.append(AudioPlaySlice(
                        url: file.url,
                        localStart: localStart,
                        duration: localEnd - localStart
                    ))
                }
            }
            cursor = fileEnd
            if cursor >= to { break }
        }
        return result
    }

    private final class PlayChain {
        var remaining: [AudioPlaySlice]
        var player: AVAudioPlayer?
        var work: DispatchWorkItem?

        init(remaining: [AudioPlaySlice]) {
            self.remaining = remaining
        }
    }
}
