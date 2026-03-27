import XCTest
import CoreML
@testable import Typeoff

/// Integration test — requires CoreML model files at ~/Documents/WhisperModels/whisper-base/
/// Run on device or simulator with models present. Skips gracefully if models not found.
final class WhisperPipelineTests: XCTestCase {

    private var modelDir: URL {
        WhisperEngine.modelDirectory(for: .standard)
    }

    private var modelsAvailable: Bool {
        FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("AudioEncoder.mlmodelc").path
        )
    }

    // MARK: - Encoder tests

    func testEncoderLoadsAndRuns() async throws {
        try XCTSkipUnless(modelsAvailable, "CoreML models not found — skipping")

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let encoderURL = modelDir.appendingPathComponent("AudioEncoder.mlmodelc")
        let encoder = try await MLModel.load(contentsOf: encoderURL, configuration: config)

        // Create dummy mel input: [1, 80, 1, 3000]
        let melArray = try MLMultiArray(shape: [1, 80, 1, 3000], dataType: .float16)
        // Fill with zeros (silence)
        for i in 0..<(80 * 3000) {
            melArray[i] = NSNumber(value: Float16(0))
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "melspectrogram_features": MLFeatureValue(multiArray: melArray)
        ])

        let output = try encoder.prediction(from: input)

        let encoderOutput = output.featureValue(for: "encoder_output_embeds")?.multiArrayValue
        XCTAssertNotNil(encoderOutput, "Encoder should produce output")
        XCTAssertEqual(encoderOutput?.shape.count, 4, "Output should be 4D")

        // Shape: [1, 512, 1, 1500]
        if let shape = encoderOutput?.shape {
            XCTAssertEqual(shape[0].intValue, 1)
            XCTAssertEqual(shape[1].intValue, 512, "Hidden dim should be 512 for base")
            XCTAssertEqual(shape[3].intValue, 1500, "Should have 1500 time steps")
        }
    }

    func testEncoderPerformance() async throws {
        try XCTSkipUnless(modelsAvailable, "CoreML models not found — skipping")

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let encoderURL = modelDir.appendingPathComponent("AudioEncoder.mlmodelc")
        let encoder = try await MLModel.load(contentsOf: encoderURL, configuration: config)

        let melArray = try MLMultiArray(shape: [1, 80, 1, 3000], dataType: .float16)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "melspectrogram_features": MLFeatureValue(multiArray: melArray)
        ])

        // Warm up
        _ = try encoder.prediction(from: input)

        // Measure
        let start = CFAbsoluteTimeGetCurrent()
        let iterations = 5
        for _ in 0..<iterations {
            _ = try encoder.prediction(from: input)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let avgMs = (elapsed / Double(iterations)) * 1000

        print("[TEST] Encoder avg: \(String(format: "%.0f", avgMs))ms per inference")
        XCTAssertLessThan(avgMs, 2000, "Encoder should complete in <2s")
    }

    // MARK: - Full pipeline test

    func testFullPipelineSilence() async throws {
        try XCTSkipUnless(modelsAvailable, "CoreML models not found — skipping")

        let pipeline = WhisperPipeline()
        try await pipeline.load(modelDir: modelDir)

        XCTAssertTrue(pipeline.isLoaded)

        // Transcribe 3 seconds of silence — should return empty or very short
        let silence = [Float](repeating: 0, count: 48000)
        let text = await pipeline.transcribe(audioSamples: silence)

        // Silence should produce empty or hallucination-filtered text
        print("[TEST] Silence transcription: \"\(text)\"")
        // Can't assert empty because Whisper sometimes hallucinates on silence,
        // but it should be short
        XCTAssertLessThan(text.count, 50, "Silence should not produce long text")
    }

    func testFullPipelineTone() async throws {
        try XCTSkipUnless(modelsAvailable, "CoreML models not found — skipping")

        let pipeline = WhisperPipeline()
        try await pipeline.load(modelDir: modelDir)

        // Generate a 440Hz tone (not speech, but should run without crashing)
        var tone = [Float](repeating: 0, count: 48000)
        for i in 0..<tone.count {
            tone[i] = sin(2.0 * .pi * 440.0 * Float(i) / 16000.0) * 0.3
        }

        let start = CFAbsoluteTimeGetCurrent()
        let text = await pipeline.transcribe(audioSamples: tone)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("[TEST] Tone transcription (\(String(format: "%.1f", elapsed))s): \"\(text)\"")

        // Just verify it doesn't crash and completes in reasonable time
        XCTAssertLessThan(elapsed, 30, "Full pipeline should complete in <30s")
    }

    func testModelLoadPerformance() async throws {
        try XCTSkipUnless(modelsAvailable, "CoreML models not found — skipping")

        let pipeline = WhisperPipeline()

        let start = CFAbsoluteTimeGetCurrent()
        try await pipeline.load(modelDir: modelDir)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("[TEST] Model load time: \(String(format: "%.2f", elapsed))s")
        XCTAssertTrue(pipeline.isLoaded)
        XCTAssertLessThan(elapsed, 5, "Model load should complete in <5s")

        pipeline.unload()
        XCTAssertFalse(pipeline.isLoaded)
    }
}
