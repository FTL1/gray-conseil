import AVFoundation
import XCTest
@testable import Grey_Eminence

final class SegmentAudioPlayerTests: XCTestCase {
    func testSlicesSpanConsecutiveFiles() {
        let a = URL(fileURLWithPath: "/tmp/a.m4a")
        let b = URL(fileURLWithPath: "/tmp/b.m4a")
        let slices = SegmentAudioPlayer.slices(
            files: [(a, 10), (b, 10)],
            from: 8,
            to: 14
        )
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].url, a)
        XCTAssertEqual(slices[0].localStart, 8, accuracy: 0.01)
        XCTAssertEqual(slices[0].duration, 2, accuracy: 0.01)
        XCTAssertEqual(slices[1].url, b)
        XCTAssertEqual(slices[1].localStart, 0, accuracy: 0.01)
        XCTAssertEqual(slices[1].duration, 4, accuracy: 0.01)
    }

    func testSliceInsideSingleFile() {
        let a = URL(fileURLWithPath: "/tmp/a.m4a")
        let slices = SegmentAudioPlayer.slices(
            files: [(a, 60)],
            from: 27,
            to: 41
        )
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].localStart, 27, accuracy: 0.01)
        XCTAssertEqual(slices[0].duration, 14, accuracy: 0.01)
    }

    func testPlayDurationNeverRunsPastTheFile() {
        let url = URL(fileURLWithPath: "/tmp/x.m4a")
        let whole = AudioPlaySlice(url: url, localStart: 0, duration: 2)
        XCTAssertEqual(SegmentAudioPlayer.playDuration(playerDuration: 1, slice: whole), 1, accuracy: 0.001)
        let tail = AudioPlaySlice(url: url, localStart: 0.8, duration: 1)
        XCTAssertEqual(SegmentAudioPlayer.playDuration(playerDuration: 1, slice: tail), 0.2, accuracy: 0.001)
    }

    /// AVAudioPlayer reads the AAC file's own sample rate, so a 1 s window
    /// lasts ~1 s. The old AVMutableComposition path could finish in ~0.1 s.
    ///
    /// Writes through `AVAudioFile` (same as `TranscriptTimelineTests`) so
    /// the non-Sendable `AVAudioFormat` is never sent into the
    /// `AudioFileWriter` actor.
    func testPlayDurationMatchesOneSecondAACFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-play-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: AudioFileWriter.encoderSettings(for: format),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let frames: AVAudioFrameCount = 48_000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                return XCTFail("buffer alloc")
            }
            buffer.frameLength = frames
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<Int(frames) {
                    channel[i] = sin(2 * Float.pi * 440 * Float(i) / 48_000) * 0.2
                }
            }
            try file.write(from: buffer)
        }

        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertEqual(
            player.duration,
            1.0,
            accuracy: 0.25,
            "recorded AAC must be ~1 s, not ~0.1 s"
        )
        let slice = AudioPlaySlice(url: url, localStart: 0, duration: 1)
        let playFor = SegmentAudioPlayer.playDuration(playerDuration: player.duration, slice: slice)
        XCTAssertEqual(
            playFor,
            1.0,
            accuracy: 0.25,
            "snippet play must last ~the window, not ~0.1s (10× fast)"
        )
        XCTAssertFalse(player.enableRate)
    }
}
