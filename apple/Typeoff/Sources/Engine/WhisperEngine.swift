import Foundation
import WhisperKit

/// Precision tiers — user-facing names, no model names shown.
enum Precision: String, CaseIterable, Identifiable {
    case standard = "base"
    case better = "small"
    case best = "large-v3"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Default"
        case .better: "Better"
        case .best: "Best"
        }
    }

    var sizeLabel: String {
        switch self {
        case .standard: "74 MB"
        case .better: "244 MB"
        case .best: "1.5 GB"
        }
    }

    var whisperKitModel: String {
        "openai_whisper-\(rawValue)"
    }
}

/// Local Whisper transcription engine using WhisperKit (CoreML + Neural Engine).
/// Downloads model on first use per precision tier, then cached locally.
@MainActor
final class WhisperEngine: ObservableObject {

    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var isDownloading = false
    @Published var loadingProgress: String = ""
    @Published var detectedLanguage: String?
    @Published var activePrecision: Precision = .standard

    /// Which models have been downloaded (cached locally).
    @Published var downloadedModels: Set<Precision> = []

    private var whisperKit: WhisperKit?

    init(modelVariant: String = "base") {
        activePrecision = Precision(rawValue: modelVariant) ?? .standard
    }

    // MARK: - Model lifecycle

    /// Load model for given precision. Downloads if not cached.
    func loadModel(precision: Precision? = nil) async {
        let target = precision ?? activePrecision

        // If switching precision, unload current
        if target != activePrecision || whisperKit != nil {
            unloadModel()
        }

        activePrecision = target
        isDownloading = true
        loadingProgress = downloadedModels.contains(target)
            ? "Loading \(target.label)..."
            : "Downloading \(target.label) (\(target.sizeLabel))..."

        do {
            whisperKit = try await WhisperKit(
                model: target.whisperKitModel,
                verbose: false,
                prewarm: true
            )
            downloadedModels.insert(target)
            isModelLoaded = true
            isDownloading = false
            loadingProgress = ""

            // Persist selection to App Group so keyboard picks it up
            UserDefaults(suiteName: "group.com.typeoff.shared")?
                .set(target.rawValue, forKey: "modelVariant")

            print("[Typeoff] Loaded: \(target.label) (\(target.whisperKitModel))")
        } catch {
            isDownloading = false
            loadingProgress = "Failed to load model"
            print("[Typeoff] Load failed: \(error)")
        }
    }

    /// Unload model to free memory.
    func unloadModel() {
        whisperKit = nil
        isModelLoaded = false
        detectedLanguage = nil
    }

    // MARK: - Transcription

    func transcribe(audioSamples: [Float]) async -> String {
        guard let kit = whisperKit else { return "" }

        isTranscribing = true
        defer { isTranscribing = false }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await kit.transcribe(audioArray: audioSamples)

            let text = result.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let firstResult = result.first, let lang = firstResult.language {
                detectedLanguage = lang
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("[Typeoff] [\(activePrecision.label)] \(String(format: "%.1f", elapsed))s: \"\(text.prefix(80))\"")

            return text
        } catch {
            print("[Typeoff] Transcription failed: \(error)")
            return ""
        }
    }
}
