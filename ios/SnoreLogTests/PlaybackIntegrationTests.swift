#if os(iOS)
import XCTest
import AVFoundation
@testable import SnoreLog

@MainActor final class PlaybackIntegrationTests: XCTestCase {
    func testAmplifiedPlaybackProgressSessionAndRecordingGuard() async throws {
        let state = AppState()
        let night = NightRecord(id: "playback-test-" + UUID().uuidString, startDate: Date())
        let directory = state.store.directory(night.id)
        defer { state.stopPlayback(); try? FileManager.default.removeItem(at: directory) }
        let clips = directory.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let source = clips.appendingPathComponent("quiet.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
        pcm.frameLength = 64_000
        for i in 0..<64_000 { pcm.floatChannelData![0][i] = Float(pow(10, -58.0 / 20)) }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: pcm) }
        let original = try Data(contentsOf: source)
        let clip = ClipRecord(id: "quiet", segmentNumbers: [0], reason: .loud, fileName: "quiet.wav")
        state.active = true
        state.play(night, clip)
        XCTAssertNil(state.preparingClipID); XCTAssertNil(state.playingClipID)
        state.active = false
        state.selectPosition(id: "\(night.id)/quiet", seconds: 1.5)
        state.play(night, clip)
        for _ in 0..<100 {
            if state.playingClipID != nil || state.error != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.playingClipID, "\(night.id)/quiet")
        XCTAssertEqual(state.playbackGainDb, 38, accuracy: 0.01)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .default)
        XCTAssertGreaterThanOrEqual(state.playbackElapsed, 1.5)
        state.setScrubbing(true)
        let held = state.playbackElapsed
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(state.playbackElapsed, held)
        state.seekPlayback(0.5)
        state.setScrubbing(false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(state.playbackProgress, 0)
        XCTAssertGreaterThan(state.playbackElapsed, 0)
        state.play(night, clip) // Same button stops playback.
        XCTAssertNil(state.playingClipID)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
#endif
