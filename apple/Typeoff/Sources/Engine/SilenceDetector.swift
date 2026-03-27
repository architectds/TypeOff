import Foundation
import Accelerate

/// Detects silence in audio buffer tail. Uses adaptive threshold
/// that syncs with AudioPreprocessor's noise floor calibration.
struct SilenceDetector {

    var silenceThreshold: Float = 0.005  // Updated by preprocessor after calibration
    let silenceDuration: TimeInterval = 5.0
    let sampleRate: Int = 16000

    /// Update threshold from preprocessor's calibrated noise floor.
    /// Call after preprocessor finishes calibration (~0.5s).
    mutating func updateThreshold(noiseFloor: Float, margin: Float = 3.0) {
        silenceThreshold = noiseFloor * margin
        print("[Typeoff] Silence threshold updated: \(String(format: "%.4f", silenceThreshold))")
    }

    /// Check if the audio tail is all silence (user stopped speaking).
    func detectEndOfSpeech(audio: [Float]) -> Bool {
        let silenceSamples = Int(silenceDuration) * sampleRate
        guard audio.count >= silenceSamples else { return false }

        let tail = Array(audio.suffix(silenceSamples))

        // Check in 500ms windows
        let windowSize = sampleRate / 2
        for i in stride(from: 0, to: tail.count, by: windowSize) {
            let end = min(i + windowSize, tail.count)
            let chunk = Array(tail[i..<end])
            if rms(chunk) >= silenceThreshold {
                return false
            }
        }
        return true
    }

    /// Check if audio contains any speech at all.
    func hasSpeech(audio: [Float], minDuration: TimeInterval = 0.3) -> Bool {
        let windowSize = sampleRate / 5  // 200ms
        let needed = Int(minDuration / 0.2)
        var speechWindows = 0

        // Only scan first 10s + last 10s
        let scanSamples = 10 * sampleRate
        let regions: [[Float]]
        if audio.count > scanSamples * 2 {
            regions = [Array(audio.prefix(scanSamples)), Array(audio.suffix(scanSamples))]
        } else {
            regions = [audio]
        }

        for region in regions {
            for i in stride(from: 0, to: region.count, by: windowSize) {
                let end = min(i + windowSize, region.count)
                let chunk = Array(region[i..<end])
                if rms(chunk) >= silenceThreshold {
                    speechWindows += 1
                }
                if speechWindows >= needed { return true }
            }
        }
        return false
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }
}
