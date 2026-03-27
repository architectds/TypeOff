import CoreML
import Foundation

/// Raw CoreML Whisper pipeline — converted from OpenAI's original model.
///
/// Encoder input:  melspectrogram_features  Float16 [1, 80, 3000]
/// Encoder output: encoder_output_embeds    Float16 [1, 1500, 512]
/// Decoder input:  input_ids [1, seq_len], encoder_output_embeds [1, 1500, 512]
/// Decoder output: logits [1, seq_len, 51865]
final class WhisperPipeline {

    let tokenizer = WhisperTokenizer()
    let melProcessor = MelSpectrogram()

    private var encoder: MLModel?
    private var decoder: MLModel?
    private(set) var isLoaded = false

    private let maxTokens = 124  // Max sequence length (128 - 4 initial tokens)
    private let vocabSize = 51865

    // MARK: - Model loading

    func load(modelDir: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let encoderURL = modelDir.appendingPathComponent("AudioEncoder.mlmodelc")
        let decoderURL = modelDir.appendingPathComponent("TextDecoder.mlmodelc")

        print("[Typeoff] Loading encoder from \(encoderURL.path)")
        print("[Typeoff] Loading decoder from \(decoderURL.path)")

        async let enc = MLModel.load(contentsOf: encoderURL, configuration: config)
        async let dec = MLModel.load(contentsOf: decoderURL, configuration: config)

        encoder = try await enc
        decoder = try await dec

        tokenizer.load()
        isLoaded = true
        print("[Typeoff] Pipeline loaded")
    }

    func unload() {
        encoder = nil
        decoder = nil
        isLoaded = false
        melProcessor.reset()
    }

    // MARK: - Transcription

    func transcribe(audioSamples: [Float], language: String? = nil) async -> String {
        guard let encoder = encoder, let decoder = decoder else {
            print("[Typeoff] Pipeline not loaded")
            return ""
        }

        // Step 1: Mel spectrogram
        let melFrames = melProcessor.processAudioWindow(audioSamples)
        guard !melFrames.isEmpty else {
            print("[Typeoff] No mel frames from \(audioSamples.count) samples")
            return ""
        }
        print("[Typeoff] Mel frames: \(melFrames.count)")

        // Step 2: Encode
        let encoderOutput: MLMultiArray
        do {
            encoderOutput = try runEncoder(encoder, melFrames: melFrames)
            print("[Typeoff] Encoder output shape: \(encoderOutput.shape)")
        } catch {
            print("[Typeoff] Encoder failed: \(error)")
            return ""
        }

        // Step 3: Greedy decode
        let tokens: [Int32]
        do {
            tokens = try greedyDecode(decoder, encoderOutput: encoderOutput, language: language)
            print("[Typeoff] Decoded \(tokens.count) tokens")
        } catch {
            print("[Typeoff] Decoder failed: \(error)")
            return ""
        }

        guard !tokens.isEmpty else { return "" }
        return tokenizer.decode(tokens)
    }

    // MARK: - Encoder

    private func runEncoder(_ model: MLModel, melFrames: [[Float]]) throws -> MLMultiArray {
        let targetFrames = 3000
        let nMels = 80
        let numFrames = min(melFrames.count, targetFrames)

        // Whisper normalization
        var globalMax: Float = -Float.infinity
        for f in 0..<numFrames {
            for m in 0..<nMels {
                globalMax = max(globalMax, melFrames[f][m])
            }
        }
        let clampFloor = globalMax - 8.0

        // Shape: [1, 80, 3000]
        let melArray = try MLMultiArray(shape: [1, NSNumber(value: nMels), NSNumber(value: targetFrames)], dataType: .float16)

        // Zero-fill with normalized silence
        let paddingValue: Float = (clampFloor + 4.0) / 4.0
        let totalElements = nMels * targetFrames
        for i in 0..<totalElements {
            melArray[i] = paddingValue as NSNumber
        }

        // Fill: layout [1, nMels, numFrames]
        for f in 0..<numFrames {
            for m in 0..<nMels {
                let val = max(melFrames[f][m], clampFloor)
                let normalized: Float = (val + 4.0) / 4.0
                let idx = m * targetFrames + f
                melArray[idx] = normalized as NSNumber
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "melspectrogram_features": MLFeatureValue(multiArray: melArray)
        ])

        let output = try model.prediction(from: input)

        guard let encoderOutput = output.featureValue(for: "encoder_output_embeds")?.multiArrayValue else {
            throw PipelineError.encoderOutputMissing
        }

        return encoderOutput
    }

    // MARK: - Greedy decoder (no KV cache — full sequence each step)

    private func greedyDecode(_ model: MLModel, encoderOutput: MLMultiArray, language: String?) throws -> [Int32] {
        var tokens = tokenizer.initialTokens(language: language)
        var outputTokens: [Int32] = []

        for _ in 0..<maxTokens {
            // Run decoder with full token sequence
            let logits = try runDecoder(model, tokens: tokens, encoderOutput: encoderOutput)

            // Argmax on last token's logits
            let nextToken = argmaxLastToken(logits, seqLen: tokens.count)

            // Stop conditions
            if nextToken == WhisperTokenizer.eot || nextToken == WhisperTokenizer.noSpeech {
                break
            }

            // Skip timestamp tokens but keep going
            if nextToken > WhisperTokenizer.noTimestamps {
                tokens.append(nextToken)
                continue
            }

            outputTokens.append(nextToken)
            tokens.append(nextToken)

            // Safety: max 128 tokens (CoreML model limit)
            if tokens.count >= 128 { break }
        }

        return outputTokens
    }

    private func runDecoder(_ model: MLModel, tokens: [Int32], encoderOutput: MLMultiArray) throws -> MLMultiArray {
        let seqLen = tokens.count

        // input_ids: [1, seqLen]
        let inputIds = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        for i in 0..<seqLen {
            inputIds[i] = tokens[i] as NSNumber
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "encoder_output_embeds": MLFeatureValue(multiArray: encoderOutput),
        ])

        let output = try model.prediction(from: input)

        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw PipelineError.decoderOutputMissing
        }

        return logits
    }

    /// Argmax on the last token position of logits [1, seqLen, vocabSize]
    private func argmaxLastToken(_ logits: MLMultiArray, seqLen: Int) -> Int32 {
        let lastTokenOffset = (seqLen - 1) * vocabSize
        var maxVal: Float = -Float.infinity
        var maxIdx: Int32 = 0

        for v in 0..<vocabSize {
            let val = logits[lastTokenOffset + v].floatValue
            if val > maxVal {
                maxVal = val
                maxIdx = Int32(v)
            }
        }

        return maxIdx
    }

    enum PipelineError: Error {
        case encoderOutputMissing
        case decoderOutputMissing
    }
}
