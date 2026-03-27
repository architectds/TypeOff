import Accelerate
import Foundation

/// Incremental mel spectrogram using Accelerate vDSP.
/// Computes mel frames as audio streams in — zero wait at transcription time.
///
/// Whisper parameters:
///   Sample rate: 16000, N_FFT: 400, Hop: 160, Mel bins: 80
final class MelSpectrogram {

    let sampleRate = 16000
    let nFFT = 400
    let hopLength = 160
    let nMels = 80

    /// Accumulated mel frames — append-only during recording, trim after window slide.
    private(set) var frames: [[Float]] = []

    /// How many audio samples have been processed into mel frames.
    private(set) var samplesProcessed: Int = 0

    // DSP state
    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private let hannWindow: [Float]
    private let melFilterbank: [[Float]]  // [nMels][nFFT/2 + 1]

    init() {
        let log2n = vDSP_Length(log2(Float(nFFT)))
        fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!

        // Hann window
        hannWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: nFFT, isHalfWindow: false)

        // Mel filterbank: maps nFFT/2+1 frequency bins → nMels
        melFilterbank = MelSpectrogram.buildMelFilterbank(nMels: nMels, nFFT: nFFT, sampleRate: sampleRate)
    }

    // MARK: - Incremental processing

    /// Process new audio samples into mel frames.
    /// Call this as audio streams in (e.g., every 100ms from recorder).
    func processAudio(_ samples: [Float]) {
        // We need at least nFFT samples for one frame
        // Process all complete frames from new audio
        let allSamples = samples
        var offset = 0

        while offset + nFFT <= allSamples.count {
            let frame = computeOneFrame(Array(allSamples[offset..<offset + nFFT]))
            frames.append(frame)
            offset += hopLength
        }

        samplesProcessed += offset
    }

    /// Process audio from a specific sample index (for recomputing after window slide).
    func processAudioWindow(_ samples: [Float]) -> [[Float]] {
        var result: [[Float]] = []
        var offset = 0

        while offset + nFFT <= samples.count {
            let frame = computeOneFrame(Array(samples[offset..<offset + nFFT]))
            result.append(frame)
            offset += hopLength
        }

        return result
    }

    /// Trim frames before a given frame index (after window slide).
    /// Releases memory from flushed audio.
    func trimFrames(before frameIndex: Int) {
        guard frameIndex > 0 && frameIndex < frames.count else { return }
        frames = Array(frames[frameIndex...])
    }

    /// Convert accumulated frames to flat Float array for CoreML input.
    /// Shape: [numFrames * nMels] (row-major, will be reshaped to [1, numFrames, nMels])
    func toFlatArray() -> [Float] {
        frames.flatMap { $0 }
    }

    /// Reset all state.
    func reset() {
        frames = []
        samplesProcessed = 0
    }

    // MARK: - Single frame computation

    private func computeOneFrame(_ windowSamples: [Float]) -> [Float] {
        assert(windowSamples.count == nFFT)

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: nFFT)
        vDSP_vmul(windowSamples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(nFFT))

        // FFT
        let halfN = nFFT / 2
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        windowed.withUnsafeBufferPointer { windowedPtr in
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(
                        realp: realPtr.baseAddress!,
                        imagp: imagPtr.baseAddress!
                    )
                    // Pack real signal into split complex
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                    // Forward FFT
                    fftSetup.forward(input: splitComplex, output: &splitComplex)
                }
            }
        }

        // Power spectrum: |FFT|^2, only first nFFT/2 + 1 bins
        var powerSpectrum = [Float](repeating: 0, count: halfN + 1)
        for i in 0..<halfN {
            powerSpectrum[i] = realPart[i] * realPart[i] + imagPart[i] * imagPart[i]
        }
        // DC and Nyquist
        powerSpectrum[halfN] = powerSpectrum[0]  // Nyquist fold

        // Apply mel filterbank
        var melFrame = [Float](repeating: 0, count: nMels)
        for m in 0..<nMels {
            var sum: Float = 0
            vDSP_dotpr(powerSpectrum, 1, melFilterbank[m], 1, &sum, vDSP_Length(halfN + 1))
            melFrame[m] = sum
        }

        // Log mel: Whisper uses natural log, then normalizes to [-1, 1]
        // Exact spec from openai/whisper/audio.py:
        //   log_spec = torch.clamp(mel_spec, min=1e-10).log10()
        //   log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
        //   log_spec = (log_spec + 4.0) / 4.0
        let floor: Float = 1e-10
        for i in 0..<nMels {
            melFrame[i] = log10(max(melFrame[i], floor))
        }

        return melFrame
    }

    // MARK: - Mel filterbank construction

    /// Build mel filterbank matrix [nMels][nFFT/2 + 1].
    /// Standard HTK mel scale as used by Whisper.
    private static func buildMelFilterbank(nMels: Int, nFFT: Int, sampleRate: Int) -> [[Float]] {
        let numBins = nFFT / 2 + 1
        let maxFreq = Float(sampleRate) / 2.0

        // Mel scale conversion
        func hzToMel(_ hz: Float) -> Float {
            2595.0 * log10(1.0 + hz / 700.0)
        }
        func melToHz(_ mel: Float) -> Float {
            700.0 * (pow(10.0, mel / 2595.0) - 1.0)
        }

        let melMin: Float = 0
        let melMax = hzToMel(maxFreq)

        // nMels + 2 equally spaced points in mel space
        var melPoints = [Float](repeating: 0, count: nMels + 2)
        for i in 0..<(nMels + 2) {
            melPoints[i] = melMin + Float(i) * (melMax - melMin) / Float(nMels + 1)
        }

        // Convert back to Hz, then to FFT bin indices
        let binPoints = melPoints.map { mel -> Float in
            let hz = melToHz(mel)
            return hz * Float(nFFT) / Float(sampleRate)
        }

        // Build triangular filters
        var filterbank = [[Float]](repeating: [Float](repeating: 0, count: numBins), count: nMels)

        for m in 0..<nMels {
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]

            for k in 0..<numBins {
                let freq = Float(k)
                if freq >= left && freq <= center {
                    filterbank[m][k] = (freq - left) / max(center - left, 1e-10)
                } else if freq > center && freq <= right {
                    filterbank[m][k] = (right - freq) / max(right - center, 1e-10)
                }
            }
        }

        return filterbank
    }
}
