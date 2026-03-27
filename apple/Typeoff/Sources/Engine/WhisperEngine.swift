import Foundation
import WhisperKit

/// Whisper transcription engine powered by WhisperKit.
@MainActor
final class WhisperEngine: ObservableObject {

    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var loadingProgress: String = ""

    private var whisperKit: WhisperKit?

    init(modelVariant: String = "base") {}

    // MARK: - Model lifecycle

    func loadModel() async {
        guard whisperKit == nil else { return }

        loadingProgress = "Loading model..."
        print("[Typeoff] Loading WhisperKit model...")

        do {
            // Let WhisperKit auto-select the best model for this device
            whisperKit = try await WhisperKit()
            isModelLoaded = true
            loadingProgress = ""
            print("[Typeoff] WhisperKit ready")
        } catch {
            loadingProgress = "Failed to load"
            print("[Typeoff] WhisperKit load failed: \(error)")
        }
    }

    func unloadModel() {
        whisperKit = nil
        isModelLoaded = false
    }

    // MARK: - Transcription

    func transcribe(audioSamples: [Float]) async -> String {
        guard let wk = whisperKit else { return "" }

        isTranscribing = true
        defer { isTranscribing = false }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await wk.transcribe(audioArray: audioSamples)
            let text = result.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("[Typeoff] \(String(format: "%.2f", elapsed))s: \"\(text.prefix(80))\"")
            return text
        } catch {
            print("[Typeoff] Transcribe failed: \(error)")
            return ""
        }
    }
}
