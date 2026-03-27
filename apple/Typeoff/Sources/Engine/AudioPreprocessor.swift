import Accelerate
import Foundation

/// Audio preprocessing for voice enhancement before Whisper.
///
/// 1. Bandpass filter: 80 Hz – 8000 Hz (human speech range)
///    - Cuts low rumble (AC, traffic, handling noise)
///    - Cuts high hiss (electronics, sibilance artifacts)
/// 2. Simple noise gate: suppress sub-threshold silence to true zero
///    - Prevents Whisper from hallucinating on quiet background noise
///
/// Runs on every audio chunk before mel spectrogram, using Accelerate for speed.
final class AudioPreprocessor {

    private let sampleRate: Float = 16000

    // Bandpass: 80 Hz – 8000 Hz (covers fundamental + harmonics of speech)
    // Biquad coefficients for 2nd-order Butterworth
    private var highpassState = BiquadState()
    private var lowpassState = BiquadState()
    private let highpassCoeffs: BiquadCoeffs   // 80 Hz high-pass
    private let lowpassCoeffs: BiquadCoeffs    // 8000 Hz low-pass

    // Adaptive noise gate — learns background noise level in first 0.5s
    /// Calibrated noise floor — exposed so SilenceDetector can sync.
    private(set) var noiseFloor: Float = 0.003
    private(set) var isCalibrated: Bool = false
    private var noiseFloorSamples: Int = 0      // How many calibration samples seen
    private var noiseFloorSum: Float = 0        // Running sum for calibration
    private let calibrationDuration: Int = 8000 // 0.5s at 16kHz — learn noise floor
    private let gateMargin: Float = 2.5         // Gate opens at 2.5x noise floor

    init() {
        // 80 Hz high-pass (remove rumble)
        highpassCoeffs = AudioPreprocessor.butterworthHighpass(cutoff: 80, sampleRate: sampleRate)
        // 8 kHz low-pass (remove hiss, Whisper doesn't use above 8kHz anyway)
        lowpassCoeffs = AudioPreprocessor.butterworthLowpass(cutoff: 8000, sampleRate: sampleRate)
    }

    /// Process audio chunk in-place: bandpass → noise gate → normalize.
    ///
    /// Pipeline:
    /// 1. Bandpass 80-8000 Hz — cut rumble + hiss outside speech range
    /// 2. Adaptive noise gate — calibrates from first 0.5s, soft-gates noise
    /// 3. Gentle normalization — keep voice level consistent for Whisper
    func process(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }

        // 1. Bandpass filter
        applyBiquad(&samples, coeffs: highpassCoeffs, state: &highpassState)
        applyBiquad(&samples, coeffs: lowpassCoeffs, state: &lowpassState)

        // 2. Adaptive noise gate (soft gate, no clicks)
        applyNoiseGate(&samples, windowSize: 320)  // 20ms windows at 16kHz

        // 3. Gentle peak normalization — keep levels consistent for Whisper
        //    Only boost if too quiet; never clip
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        if peak > 0.001 && peak < 0.5 {
            let gain = min(0.7 / peak, 3.0)  // Target 0.7 peak, max 3x boost
            vDSP_vsmul(samples, 1, [gain], &samples, 1, vDSP_Length(samples.count))
        }
    }

    /// Reset filter state (call when starting a new recording).
    func reset() {
        highpassState = BiquadState()
        lowpassState = BiquadState()
        noiseFloor = 0.003
        isCalibrated = false
        noiseFloorSamples = 0
        noiseFloorSum = 0
    }

    // MARK: - Adaptive noise gate

    private func applyNoiseGate(_ samples: inout [Float], windowSize: Int) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + windowSize, samples.count)
            let chunk = Array(samples[offset..<end])

            // RMS of this window
            var rms: Float = 0
            vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(chunk.count))

            // Calibrate noise floor from first 0.5s of audio
            // User hasn't started speaking yet — this is pure background noise
            if noiseFloorSamples < calibrationDuration {
                noiseFloorSum += rms
                noiseFloorSamples += chunk.count
                if noiseFloorSamples >= calibrationDuration {
                    let windowCount = Float(calibrationDuration) / Float(windowSize)
                    noiseFloor = max(noiseFloorSum / windowCount, 0.001)
                    isCalibrated = true
                    print("[Typeoff] Noise floor calibrated: \(String(format: "%.4f", noiseFloor)) RMS")
                }
            }

            let threshold = noiseFloor * gateMargin

            if rms < threshold {
                // Soft gate: fade to zero (avoids clicks)
                let attenuation = rms / threshold  // 0..1
                for i in offset..<end {
                    samples[i] *= attenuation
                }
            }

            offset += windowSize
        }
    }

    // MARK: - Biquad filter (2nd order IIR)

    struct BiquadCoeffs {
        let b0, b1, b2, a1, a2: Float
    }

    struct BiquadState {
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0
    }

    private func applyBiquad(_ samples: inout [Float], coeffs: BiquadCoeffs, state: inout BiquadState) {
        for i in 0..<samples.count {
            let x0 = samples[i]
            let y0 = coeffs.b0 * x0 + coeffs.b1 * state.x1 + coeffs.b2 * state.x2
                    - coeffs.a1 * state.y1 - coeffs.a2 * state.y2
            state.x2 = state.x1
            state.x1 = x0
            state.y2 = state.y1
            state.y1 = y0
            samples[i] = y0
        }
    }

    // MARK: - Butterworth filter design

    private static func butterworthHighpass(cutoff: Float, sampleRate: Float) -> BiquadCoeffs {
        let omega = 2.0 * Float.pi * cutoff / sampleRate
        let cosOmega = cos(omega)
        let alpha = sin(omega) / (2.0 * sqrt(2.0))  // Q = sqrt(2)/2 for Butterworth

        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: ((1.0 + cosOmega) / 2.0) / a0,
            b1: (-(1.0 + cosOmega)) / a0,
            b2: ((1.0 + cosOmega) / 2.0) / a0,
            a1: (-2.0 * cosOmega) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private static func butterworthLowpass(cutoff: Float, sampleRate: Float) -> BiquadCoeffs {
        let omega = 2.0 * Float.pi * cutoff / sampleRate
        let cosOmega = cos(omega)
        let alpha = sin(omega) / (2.0 * sqrt(2.0))

        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: ((1.0 - cosOmega) / 2.0) / a0,
            b1: (1.0 - cosOmega) / a0,
            b2: ((1.0 - cosOmega) / 2.0) / a0,
            a1: (-2.0 * cosOmega) / a0,
            a2: (1.0 - alpha) / a0
        )
    }
}
