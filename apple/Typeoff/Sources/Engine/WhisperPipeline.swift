import CoreML
import Foundation

/// Raw CoreML Whisper pipeline — no WhisperKit, no dependencies.
///
/// Model spec (from argmaxinc/whisperkit-coreml openai_whisper-base):
///   Encoder input:  melspectrogram_features  Float16 [1, 80, 1, 3000]
///   Encoder output: encoder_output_embeds    Float16 [1, 512, 1, 1500]
///   Decoder input:  input_ids, cache_length, key_cache, value_cache,
///                   kv_cache_update_mask, encoder_output_embeds, decoder_key_padding_mask
///   Decoder output: logits [1, 1, 51865], key_cache_updates, value_cache_updates
final class WhisperPipeline {

    let tokenizer = WhisperTokenizer()
    let melProcessor = MelSpectrogram()

    private var encoder: MLModel?
    private var decoder: MLModel?
    private(set) var isLoaded = false

    private let maxDecoderTokens = 224
    private let vocabSize = 51865
    private let kvDim = 3072        // 6 layers * 512 dim = 3072
    private let maxCacheLength = 224

    // MARK: - Model loading

    /// Load encoder + decoder in parallel.
    func load(modelDir: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let encoderURL = modelDir.appendingPathComponent("AudioEncoder.mlmodelc")
        let decoderURL = modelDir.appendingPathComponent("TextDecoder.mlmodelc")

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
        guard let encoder = encoder, let decoder = decoder else { return "" }

        // Step 1: Mel spectrogram → pad/truncate to 3000 frames (30s)
        let melFrames = melProcessor.processAudioWindow(audioSamples)
        guard !melFrames.isEmpty else { return "" }

        // Step 2: Encode
        guard let encoderOutput = try? runEncoder(encoder, melFrames: melFrames) else {
            return ""
        }

        // Step 3: Greedy decode with KV cache
        let tokens = (try? greedyDecode(decoder, encoderOutput: encoderOutput, language: language)) ?? []
        guard !tokens.isEmpty else { return "" }

        // Step 4: Tokens → text
        return tokenizer.decode(tokens)
    }

    /// Feed audio chunk to mel processor for precomputation.
    func streamMel(_ audioChunk: [Float]) {
        melProcessor.processAudio(audioChunk)
    }

    func trimMel(beforeFrameIndex: Int) {
        melProcessor.trimFrames(before: beforeFrameIndex)
    }

    // MARK: - Encoder

    private func runEncoder(_ model: MLModel, melFrames: [[Float]]) throws -> MLMultiArray {
        // Encoder expects [1, 80, 1, 3000] — pad or truncate mel frames to 3000
        let targetFrames = 3000
        let nMels = 80
        let numFrames = min(melFrames.count, targetFrames)

        // Whisper normalization (from openai/whisper/audio.py):
        //   log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
        //   log_spec = (log_spec + 4.0) / 4.0
        // Find global max across all mel frames
        var globalMax: Float = -Float.infinity
        for f in 0..<numFrames {
            for m in 0..<nMels {
                globalMax = max(globalMax, melFrames[f][m])
            }
        }
        let clampFloor = globalMax - 8.0

        let melArray = try MLMultiArray(shape: [1, NSNumber(value: nMels), 1, NSNumber(value: targetFrames)], dataType: .float16)

        // Zero-fill padding (maps to -1.0 after normalization for silence)
        let paddingValue: Float = (clampFloor + 4.0) / 4.0
        let totalElements = nMels * targetFrames
        for i in 0..<totalElements {
            melArray[i] = paddingValue as NSNumber
        }

        // Fill with normalized mel frames: layout is [1, nMels, 1, numFrames]
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

    // MARK: - Greedy decoder with KV cache

    private func greedyDecode(_ model: MLModel, encoderOutput: MLMultiArray, language: String?) throws -> [Int32] {
        let initialTokens = tokenizer.initialTokens(language: language)

        // Initialize KV cache (zeros)
        var keyCache = try MLMultiArray(shape: [1, NSNumber(value: kvDim), 1, NSNumber(value: maxCacheLength)], dataType: .float16)
        var valueCache = try MLMultiArray(shape: [1, NSNumber(value: kvDim), 1, NSNumber(value: maxCacheLength)], dataType: .float16)

        var outputTokens: [Int32] = []
        var cachePos: Int32 = 0

        // Feed initial tokens one by one to fill cache
        let allTokens = initialTokens
        for token in allTokens {
            let result = try runDecoderStep(
                model,
                inputId: token,
                cacheLength: cachePos,
                keyCache: keyCache,
                valueCache: valueCache,
                encoderOutput: encoderOutput
            )
            // Update KV cache
            updateCache(&keyCache, with: result.keyCacheUpdate, at: Int(cachePos))
            updateCache(&valueCache, with: result.valueCacheUpdate, at: Int(cachePos))
            cachePos += 1
        }

        // Autoregressive generation
        var lastToken = allTokens.last!
        for _ in 0..<maxDecoderTokens {
            let result = try runDecoderStep(
                model,
                inputId: lastToken,
                cacheLength: cachePos,
                keyCache: keyCache,
                valueCache: valueCache,
                encoderOutput: encoderOutput
            )

            // Argmax over logits
            let nextToken = argmax(result.logits)

            // Stop conditions
            if nextToken == WhisperTokenizer.eot || nextToken == WhisperTokenizer.noSpeech {
                break
            }

            // Skip timestamp tokens
            if nextToken > WhisperTokenizer.noTimestamps {
                // Still update cache
                updateCache(&keyCache, with: result.keyCacheUpdate, at: Int(cachePos))
                updateCache(&valueCache, with: result.valueCacheUpdate, at: Int(cachePos))
                cachePos += 1
                lastToken = nextToken
                continue
            }

            outputTokens.append(nextToken)
            lastToken = nextToken

            // Update cache
            updateCache(&keyCache, with: result.keyCacheUpdate, at: Int(cachePos))
            updateCache(&valueCache, with: result.valueCacheUpdate, at: Int(cachePos))
            cachePos += 1

            if cachePos >= maxCacheLength { break }
        }

        return outputTokens
    }

    // MARK: - Single decoder step

    private struct DecoderStepResult {
        let logits: MLMultiArray
        let keyCacheUpdate: MLMultiArray
        let valueCacheUpdate: MLMultiArray
    }

    private func runDecoderStep(
        _ model: MLModel,
        inputId: Int32,
        cacheLength: Int32,
        keyCache: MLMultiArray,
        valueCache: MLMultiArray,
        encoderOutput: MLMultiArray
    ) throws -> DecoderStepResult {

        // input_ids: [1]
        let inputIds = try MLMultiArray(shape: [NSNumber(value: 1)], dataType: .int32)
        inputIds[0] = inputId as NSNumber

        // cache_length: [1]
        let cacheLenArray = try MLMultiArray(shape: [NSNumber(value: 1)], dataType: .int32)
        cacheLenArray[0] = cacheLength as NSNumber

        // kv_cache_update_mask: [1, 224] — one-hot at cacheLength position
        let updateMask = try MLMultiArray(shape: [NSNumber(value: 1), NSNumber(value: maxCacheLength)], dataType: .float16)
        for i in 0..<maxCacheLength {
            let maskVal: Float = i == Int(cacheLength) ? 1 : 0
            updateMask[i] = maskVal as NSNumber
        }

        // decoder_key_padding_mask: [1, 224] — 0 for valid positions, -inf for padding
        let paddingMask = try MLMultiArray(shape: [NSNumber(value: 1), NSNumber(value: maxCacheLength)], dataType: .float16)
        for i in 0..<maxCacheLength {
            let padVal: Float = i <= Int(cacheLength) ? 0 : -10000
            paddingMask[i] = padVal as NSNumber
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "cache_length": MLFeatureValue(multiArray: cacheLenArray),
            "key_cache": MLFeatureValue(multiArray: keyCache),
            "value_cache": MLFeatureValue(multiArray: valueCache),
            "kv_cache_update_mask": MLFeatureValue(multiArray: updateMask),
            "encoder_output_embeds": MLFeatureValue(multiArray: encoderOutput),
            "decoder_key_padding_mask": MLFeatureValue(multiArray: paddingMask),
        ])

        let output = try model.prediction(from: input)

        guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
              let keyCacheUpdate = output.featureValue(for: "key_cache_updates")?.multiArrayValue,
              let valueCacheUpdate = output.featureValue(for: "value_cache_updates")?.multiArrayValue else {
            throw PipelineError.decoderOutputMissing
        }

        return DecoderStepResult(logits: logits, keyCacheUpdate: keyCacheUpdate, valueCacheUpdate: valueCacheUpdate)
    }

    // MARK: - Helpers

    /// Copy cache update [1, 3072, 1, 1] into cache [1, 3072, 1, 224] at position.
    private func updateCache(_ cache: inout MLMultiArray, with update: MLMultiArray, at position: Int) {
        guard position >= 0 && position < maxCacheLength else {
            print("[Typeoff] Cache position out of bounds: \(position)")
            return
        }
        let updateCount = min(kvDim, update.count)
        for d in 0..<updateCount {
            let idx = d * maxCacheLength + position
            cache[idx] = update[d]
        }
    }

    /// Argmax over logits [1, 1, vocabSize].
    private func argmax(_ logits: MLMultiArray) -> Int32 {
        let count = min(vocabSize, logits.count)
        guard count > 0 else { return WhisperTokenizer.eot }

        var maxVal: Float = -Float.infinity
        var maxIdx: Int32 = 0

        for v in 0..<count {
            let val = logits[v].floatValue
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
