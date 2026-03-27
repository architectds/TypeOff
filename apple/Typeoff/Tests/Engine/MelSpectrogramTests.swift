import XCTest
@testable import Typeoff

final class MelSpectrogramTests: XCTestCase {

    func testOutputShape() {
        let mel = MelSpectrogram()

        // 1 second of 16kHz audio = 16000 samples
        // Expected frames: floor((16000 - 400) / 160) + 1 ≈ 97 frames
        let audio = [Float](repeating: 0, count: 16000)
        let frames = mel.processAudioWindow(audio)

        XCTAssertGreaterThan(frames.count, 90, "Should produce ~97 mel frames for 1s audio")
        XCTAssertLessThan(frames.count, 105)

        // Each frame should have 80 mel bins
        for frame in frames {
            XCTAssertEqual(frame.count, 80, "Each mel frame must have 80 bins")
        }
    }

    func testSilenceProducesLowValues() {
        let mel = MelSpectrogram()

        let silence = [Float](repeating: 0, count: 16000)
        let frames = mel.processAudioWindow(silence)

        // Silence should produce very low log-mel values (close to log10(1e-10) = -10)
        for frame in frames {
            for val in frame {
                XCTAssertLessThan(val, -5, "Silence should have very low mel energy")
            }
        }
    }

    func testSineWaveProducesEnergy() {
        let mel = MelSpectrogram()

        // 440 Hz sine wave at 16kHz — should produce energy in mel bins around that frequency
        var audio = [Float](repeating: 0, count: 16000)
        for i in 0..<audio.count {
            audio[i] = sin(2.0 * .pi * 440.0 * Float(i) / 16000.0) * 0.5
        }

        let frames = mel.processAudioWindow(audio)

        // At least some bins should have significant energy
        let maxVal = frames.flatMap { $0 }.max() ?? -100
        XCTAssertGreaterThan(maxVal, -5, "440Hz tone should produce measurable mel energy")
    }

    func testIncrementalMatchesBatch() {
        let mel1 = MelSpectrogram()
        let mel2 = MelSpectrogram()

        // Generate 2 seconds of noise
        var audio = [Float](repeating: 0, count: 32000)
        for i in 0..<audio.count {
            audio[i] = Float.random(in: -0.1...0.1)
        }

        // Batch: process all at once
        let batchFrames = mel1.processAudioWindow(audio)

        // Incremental: process in chunks
        let chunk1 = Array(audio[0..<16000])
        let chunk2 = Array(audio[16000..<32000])
        mel2.processAudio(chunk1)
        mel2.processAudio(chunk2)

        // Frame counts should match (incremental might differ slightly due to boundary handling)
        XCTAssertEqual(mel2.frames.count, batchFrames.count,
                       "Incremental and batch should produce same frame count")
    }

    func testTrimFrames() {
        let mel = MelSpectrogram()
        let audio = [Float](repeating: 0.1, count: 32000)
        mel.processAudio(audio)

        let originalCount = mel.frames.count
        XCTAssertGreaterThan(originalCount, 100)

        mel.trimFrames(before: 50)
        XCTAssertEqual(mel.frames.count, originalCount - 50, "Trim should remove frames before index")
    }

    func testReset() {
        let mel = MelSpectrogram()
        mel.processAudio([Float](repeating: 0.1, count: 16000))
        XCTAssertGreaterThan(mel.frames.count, 0)

        mel.reset()
        XCTAssertEqual(mel.frames.count, 0)
        XCTAssertEqual(mel.samplesProcessed, 0)
    }
}
