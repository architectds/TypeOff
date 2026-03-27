import XCTest
@testable import Typeoff

final class SilenceDetectorTests: XCTestCase {

    func testSilenceDetectedOnZeros() {
        let detector = SilenceDetector()

        // 10 seconds of silence (need > silenceDuration of 5s)
        let silence = [Float](repeating: 0, count: 160000)  // 10s at 16kHz
        XCTAssertTrue(detector.detectEndOfSpeech(audio: silence))
    }

    func testSpeechNotDetectedAsEnd() {
        let detector = SilenceDetector()

        // 10 seconds with a loud tone in the tail
        var audio = [Float](repeating: 0, count: 160000)
        // Add speech-like energy in last 2 seconds
        for i in (160000 - 32000)..<160000 {
            audio[i] = sin(Float(i) * 0.1) * 0.3
        }

        XCTAssertFalse(detector.detectEndOfSpeech(audio: audio),
                        "Audio with speech in tail should not be detected as end")
    }

    func testTooShortAudioNotDetected() {
        let detector = SilenceDetector()

        // 2 seconds of silence (less than 5s silenceDuration)
        let silence = [Float](repeating: 0, count: 32000)
        XCTAssertFalse(detector.detectEndOfSpeech(audio: silence),
                        "Audio shorter than silence duration should return false")
    }

    func testHasSpeech() {
        let detector = SilenceDetector()

        // Silence
        let silence = [Float](repeating: 0, count: 16000)
        XCTAssertFalse(detector.hasSpeech(audio: silence))

        // Loud signal
        var speech = [Float](repeating: 0, count: 16000)
        for i in 0..<16000 {
            speech[i] = sin(Float(i) * 0.3) * 0.5
        }
        XCTAssertTrue(detector.hasSpeech(audio: speech))
    }

    func testAdaptiveThreshold() {
        var detector = SilenceDetector()
        XCTAssertEqual(detector.silenceThreshold, 0.005)

        detector.updateThreshold(noiseFloor: 0.01, margin: 3.0)
        XCTAssertEqual(detector.silenceThreshold, 0.03, accuracy: 0.001)
    }
}
