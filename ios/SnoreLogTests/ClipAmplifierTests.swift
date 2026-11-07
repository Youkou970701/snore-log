import Foundation
import AVFAudio
import CryptoKit
import XCTest
@testable import SnoreLog

final class ClipAmplifierTests: XCTestCase {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amplifier-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func write(_ samples: [Float], directory: URL, rate: Double = 16_000) throws -> URL {
        let url = directory.appendingPathComponent("original.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    private func hash(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    func testQuietAudioTargetsMinus20AndPreservesSourceHash() throws {
        let dir = try scratch()
        // A square wave has exactly -58 dBFS RMS without rounding of sine periods.
        let level = Float(pow(10, -58.0 / 20))
        let source = try write((0..<3000).map { $0 % 2 == 0 ? level : -level }, directory: dir)
        let before = try hash(source)
        let result = try ClipAmplifier.prepare(source: source, directory: dir.appendingPathComponent("copies"))
        XCTAssertEqual(result.gainDb, 38, accuracy: 0.001)
        let output = try ClipAmplifier.measure(url: result.url)
        XCTAssertEqual(output.loudestSecondDbFS, -20, accuracy: 0.001)
        XCTAssertLessThanOrEqual(output.peakDbFS, -1 + 0.0001)
        XCTAssertEqual(try hash(source), before)
        XCTAssertTrue(result.url.lastPathComponent.contains("-放大"))
    }

    func testLoudestSecondUsesSlidingWindow() throws {
        let dir = try scratch()
        var samples = [Float](repeating: 0, count: 32_000)
        for i in 8_000..<24_000 { samples[i] = 0.001 }
        let source = try write(samples, directory: dir)
        let probe = try AVAudioFile(forReading: source)
        XCTAssertEqual(probe.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(probe.length) / probe.processingFormat.sampleRate, 2)
        let result = try ClipAmplifier.prepare(source: source, directory: dir.appendingPathComponent("copies"))
        XCTAssertEqual(try ClipAmplifier.measure(url: source).loudestSecondOffset, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.gainDb, 40, accuracy: 0.001)
        XCTAssertEqual(try ClipAmplifier.measure(url: result.url).loudestSecondDbFS, -20, accuracy: 0.001)
    }

    func testTransientPeakLimitsGainEvenIfRMSMissesTarget() throws {
        let dir = try scratch()
        var samples = [Float](repeating: 0.00001, count: 3000)
        samples[100] = 0.2
        let source = try write(samples, directory: dir)
        let result = try ClipAmplifier.prepare(source: source, directory: dir.appendingPathComponent("copies"))
        XCTAssertEqual(result.gainDb, -1 - 20 * log10(0.2), accuracy: 0.001)
        let output = try ClipAmplifier.measure(url: result.url)
        XCTAssertLessThanOrEqual(output.peakDbFS, -1 + 0.0001)
        XCTAssertLessThan(output.loudestSecondDbFS, -20)
    }

    func testGainCapAndShortAudioAndSilence() throws {
        let dir = try scratch()
        let source = try write([Float](repeating: 0.00001, count: 100), directory: dir)
        let result = try ClipAmplifier.prepare(source: source, directory: dir.appendingPathComponent("copies"))
        XCTAssertEqual(result.gainDb, 45)
        XCTAssertEqual(try ClipAmplifier.measure(url: result.url).loudestSecondDbFS, -55, accuracy: 0.001)
        let silenceDir = try scratch()
        let silence = try write([Float](repeating: 0, count: 100), directory: silenceDir)
        let quiet = try ClipAmplifier.prepare(source: silence, directory: silenceDir.appendingPathComponent("copies"))
        XCTAssertEqual(quiet.gainDb, 0)
        XCTAssertEqual(try ClipAmplifier.measure(url: quiet.url).peakDbFS, -.infinity)
    }

    func testAlreadyLoudAudioDoesNotAttenuateToTargetButPeakIsAlwaysSafe() throws {
        let dir = try scratch()
        let source = try write([Float](repeating: 1, count: 500), directory: dir)
        let result = try ClipAmplifier.prepare(source: source, directory: dir.appendingPathComponent("copies"))
        XCTAssertEqual(result.gainDb, -1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(try ClipAmplifier.measure(url: result.url).peakDbFS, -1 + 0.0001)
        let loudDir = try scratch()
        let loud = try write([Float](repeating: 0.2, count: 500), directory: loudDir)
        let unchanged = try ClipAmplifier.prepare(source: loud, directory: loudDir.appendingPathComponent("copies"))
        XCTAssertEqual(unchanged.gainDb, 0)
        XCTAssertEqual(try ClipAmplifier.measure(url: unchanged.url).loudestSecondDbFS, 20 * log10(0.2), accuracy: 0.001)
    }

    func testRealRetainedAACWhenAvailablePreservesOriginal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("fixtures/real/20261107/clip-165.m4a")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Real recording is not present on this test host") }
        let before = try hash(source)
        let input = try ClipAmplifier.measure(url: source)
        let result = try ClipAmplifier.prepare(source: source, directory: try scratch())
        let output = try ClipAmplifier.measure(url: result.url)
        let expectedGain = min(45, max(0, -20 - input.loudestSecondDbFS), -1 - input.peakDbFS)
        XCTAssertEqual(result.gainDb, expectedGain, accuracy: 0.001)
        XCTAssertEqual(output.loudestSecondDbFS, input.loudestSecondDbFS + expectedGain, accuracy: 0.001)
        XCTAssertLessThanOrEqual(output.peakDbFS, -1 + 0.0001)
        XCTAssertEqual(try hash(source), before)
        print("03b real playback: gain=\(result.gainDb) dB, loudest second=\(output.loudestSecondDbFS) dBFS, peak=\(output.peakDbFS) dBFS; SHA256 unchanged")
    }
}
