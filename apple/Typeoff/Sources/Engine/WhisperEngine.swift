import Foundation
import WhisperKit

/// Local Whisper transcription engine using WhisperKit (CoreML + Neural Engine).
/// Downloads model on first launch, then runs fully offline.
@MainActor
final class WhisperEngine: ObservableObject {

    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var loadingProgress: String = ""
    @Published var detectedLanguage: String?

    private var whisperKit: WhisperKit?

    // Model variant — "base" is ~74MB, "small" is ~244MB
    private let modelVariant: String

    init(modelVariant: String = "base") {
        self.modelVariant = modelVariant
    }

    // MARK: - Model lifecycle

    /// Load model — downloads on first launch, then cached locally.
    func loadModel() async {
        guard whisperKit == nil else { return }

        loadingProgress = "Loading model..."

        do {
            whisperKit = try await WhisperKit(
                model: "openai_whisper-\(modelVariant)",
                verbose: false,
                prewarm: true
            )
            isModelLoaded = true
            loadingProgress = ""
            print("[Typeoff] WhisperKit loaded: \(modelVariant)")
        } catch {
            loadingProgress = "Model load failed"
            print("[Typeoff] WhisperKit load failed: \(error)")
        }
    }

    /// Unload model to free memory.
    func unloadModel() {
        whisperKit = nil
        isModelLoaded = false
        detectedLanguage = nil
        print("[Typeoff] Model unloaded")
    }

    // MARK: - Transcription

    /// Transcribe audio samples (16kHz mono Float32) → text.
    func transcribe(audioSamples: [Float]) async -> String {
        guard let kit = whisperKit else { return "" }

        isTranscribing = true
        defer { isTranscribing = false }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await kit.transcribe(
                audioArray: audioSamples
            )

            let text = result.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Pick up detected language from first segment
            if let firstResult = result.first,
               let lang = firstResult.language {
                detectedLanguage = lang
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("[Typeoff] Transcribed in \(String(format: "%.1f", elapsed))s: \"\(text.prefix(80))\"")

            return text
        } catch {
            print("[Typeoff] Transcription failed: \(error)")
            return ""
        }
    }
}
