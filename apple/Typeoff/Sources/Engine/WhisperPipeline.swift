import CoreML
import Foundation

/// Raw CoreML Whisper pipeline — encoder + greedy decoder.
/// No WhisperKit dependency. Loads AudioEncoder.mlmodelc + TextDecoder.mlmodelc directly.
///
/// Architecture:
///   Audio → MelSpectrogram (Accelerate) → Encoder (CoreML/ANE) → Decoder (CoreML, greedy) → Tokens → Text
///
/// Parallelism:
///   - Mel computed incrementally as audio streams in (zero wait at transcribe time)
///   - Encoder runs on Neural Engine, decoder on CPU/GPU — different hardware, natural overlap
///   - Old audio + mel frames released after window slide
final class WhisperPipeline {

    let tokenizer = WhisperTokenizer()
    let melProcessor = MelSpectrogram()

    private var encoder: MLModel?
    private var decoder: MLModel?
    private(set) var isLoaded = false

    private let maxDecoderTokens = 224  // Max output tokens per chunk

    // MARK: - Model loading

    /// Load encoder + decoder CoreML models.
    /// Models are .mlmodelc bundles stored in the app's documents or bundle.
    func load(modelDir: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // Neural Engine + GPU + CPU

        let encoderURL = modelDir.appendingPathComponent("AudioEncoder.mlmodelc")
        let decoderURL = modelDir.appendingPathComponent("TextDecoder.mlmodelc")

        // Load both in parallel
        async let enc = MLModel.load(contentsOf: encoderURL, configuration: config)
        async let dec = MLModel.load(contentsOf: decoderURL, configuration: config)

        encoder = try await enc
        decoder = try await dec

        tokenizer.load()
        isLoaded = true

        print("[Typeoff] Pipeline loaded from \(modelDir.lastPathComponent)")
    }

    /// Unload models to free memory.
    func unload() {
        encoder = nil
        decoder = nil
        isLoaded = false
        melProcessor.reset()
    }

    // MARK: - Transcription

    /// Transcribe audio samples → text.
    /// If mel frames were precomputed (via streamMel), uses those. Otherwise computes from scratch.
    func transcribe(audioSamples: [Float], language: String? = nil) async -> String {
        guard let encoder = encoder, let decoder = decoder else { return "" }

        // Step 1: Mel spectrogram
        let melFrames = melProcessor.processAudioWindow(audioSamples)
        guard !melFrames.isEmpty else { return "" }

        // Step 2: Encode
        guard let encoderOutput = try? await runEncoder(encoder, melFrames: melFrames) else {
            return ""
        }

        // Step 3: Greedy decode
        let tokens = try? await greedyDecode(decoder, encoderOutput: encoderOutput, language: language)
        guard let tokens = tokens, !tokens.isEmpty else { return "" }

        // Step 4: Detokenize
        return tokenizer.decode(tokens)
    }

    /// Feed audio to mel processor incrementally (call from recorder callback).
    /// This precomputes mel frames so transcribe() has zero mel wait.
    func streamMel(_ audioChunk: [Float]) {
        melProcessor.processAudio(audioChunk)
    }

    /// Trim mel frames + signal that audio before this point is released.
    /// Call after window slide to free memory.
    func trimMel(beforeFrameIndex: Int) {
        melProcessor.trimFrames(before: beforeFrameIndex)
    }

    // MARK: - Encoder

    private func runEncoder(_ model: MLModel, melFrames: [[Float]]) async throws -> MLMultiArray {
        let numFrames = melFrames.count
        let nMels = 80

        // Build input: [1, numFrames, 80]
        let melArray = try MLMultiArray(shape: [1, NSNumber(value: numFrames), NSNumber(value: nMels)], dataType: .float32)

        for f in 0..<numFrames {
            for m in 0..<nMels {
                melArray[[0, f, m] as [NSNumber]] = NSNumber(value: melFrames[f][m])
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["input_features": melArray])
        let output = try await model.prediction(from: input)

        // Encoder output: [1, numFrames, hiddenDim]
        guard let encoderOutput = output.featureValue(for: "encoder_output")?.multiArrayValue
                ?? output.featureValue(for: "last_hidden_state")?.multiArrayValue else {
            throw PipelineError.encoderOutputMissing
        }

        return encoderOutput
    }

    // MARK: - Greedy decoder

    private func greedyDecode(_ model: MLModel, encoderOutput: MLMultiArray, language: String?) async throws -> [Int32] {
        var tokens = tokenizer.initialTokens(language: language)
        var outputTokens: [Int32] = []

        for _ in 0..<maxDecoderTokens {
            // Build decoder input
            let tokenArray = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            for (i, token) in tokens.enumerated() {
                tokenArray[[0, i] as [NSNumber]] = NSNumber(value: token)
            }

            let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": tokenArray,
                "encoder_output": encoderOutput,
            ])

            let output = try await model.prediction(from: decoderInput)

            // Get logits: [1, seqLen, vocabSize] — take last position
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                break
            }

            // Argmax of last token position
            let vocabSize = logits.shape.last!.intValue
            let lastPos = tokens.count - 1
            var maxVal: Float = -Float.infinity
            var maxIdx: Int32 = 0

            for v in 0..<vocabSize {
                let val = logits[[0, lastPos, v] as [NSNumber]].floatValue
                if val > maxVal {
                    maxVal = val
                    maxIdx = Int32(v)
                }
            }

            // Stop on EOT or special tokens
            if maxIdx == WhisperTokenizer.eot || maxIdx == WhisperTokenizer.noSpeech {
                break
            }

            // Skip timestamp tokens (50364+)
            if maxIdx > WhisperTokenizer.noTimestamps {
                continue
            }

            outputTokens.append(maxIdx)
            tokens.append(maxIdx)
        }

        return outputTokens
    }

    // MARK: - Errors

    enum PipelineError: Error {
        case encoderOutputMissing
        case decoderOutputMissing
    }
}
