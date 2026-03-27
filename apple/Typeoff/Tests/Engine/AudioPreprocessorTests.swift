import XCTest
@testable import Typeoff

final class AudioPreprocessorTests: XCTestCase {

    func testBandpassRemovesLowFreq() {
        let preprocessor = AudioPreprocessor()

        // 20 Hz sine wave (below 80 Hz cutoff) — should be attenuated
        var lowFreq = [Float](repeating: 0, count: 16000)
        for i in 0..<lowFreq.count {
            lowFreq[i] = sin(2.0 * .pi * 20.0 * Float(i) / 16000.0) * 0.5
        }

        let originalRMS = rms(lowFreq)
        preprocessor.process(&lowFreq)
        let filteredRMS = rms(lowFreq)

        XCTAssertLessThan(filteredRMS, originalRMS * 0.3,
                          "20 Hz should be significantly attenuated by 80 Hz highpass")
    }

    func testBandpassPassesSpeech() {
        let preprocessor = AudioPreprocessor()

        // 500 Hz sine wave (well within speech band) — should pass through
        var speech = [Float](repeating: 0, count: 16000)
        for i in 0..<speech.count {
            speech[i] = sin(2.0 * .pi * 500.0 * Float(i) / 16000.0) * 0.5
        }

        let originalRMS = rms(speech)
        preprocessor.process(&speech)
        let filteredRMS = rms(speech)

        // Should retain most energy (some loss from normalization is ok)
        XCTAssertGreaterThan(filteredRMS, originalRMS * 0.5,
                             "500 Hz should pass through bandpass with >50% energy")
    }

    func testNoiseGateAttenuatesSilence() {
        let preprocessor = AudioPreprocessor()

        // Very quiet noise (below gate threshold)
        var quiet = [Float](repeating: 0, count: 16000)
        for i in 0..<quiet.count {
            quiet[i] = Float.random(in: -0.001...0.001)
        }

        preprocessor.process(&quiet)

        // After noise gate, should be even quieter
        let rmsAfter = rms(quiet)
        XCTAssertLessThan(rmsAfter, 0.002, "Quiet noise should be gated close to zero")
    }

    func testCalibration() {
        let preprocessor = AudioPreprocessor()
        XCTAssertFalse(preprocessor.isCalibrated)

        // Feed enough samples for calibration (8000 samples = 0.5s)
        var audio = [Float](repeating: 0, count: 16000)
        for i in 0..<audio.count {
            audio[i] = Float.random(in: -0.01...0.01)
        }
        preprocessor.process(&audio)

        XCTAssertTrue(preprocessor.isCalibrated, "Should be calibrated after 0.5s of audio")
        XCTAssertGreaterThan(preprocessor.noiseFloor, 0, "Noise floor should be positive")
    }

    func testReset() {
        let preprocessor = AudioPreprocessor()

        var audio = [Float](repeating: 0.01, count: 16000)
        preprocessor.process(&audio)
        XCTAssertTrue(preprocessor.isCalibrated)

        preprocessor.reset()
        XCTAssertFalse(preprocessor.isCalibrated)
    }

    func testNormalizationBoostsQuietVoice() {
        let preprocessor = AudioPreprocessor()

        // Simulate quiet cubicle voice: 300 Hz at low amplitude
        var quiet = [Float](repeating: 0, count: 16000)
        for i in 0..<quiet.count {
            quiet[i] = sin(2.0 * .pi * 300.0 * Float(i) / 16000.0) * 0.05
        }

        let rmsBefore = rms(quiet)
        preprocessor.process(&quiet)
        let rmsAfter = rms(quiet)

        XCTAssertGreaterThan(rmsAfter, rmsBefore * 1.5,
                             "Quiet voice should be boosted by normalization")
    }

    // MARK: - Helper

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }
}
