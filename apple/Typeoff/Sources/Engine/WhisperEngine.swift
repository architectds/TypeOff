import Foundation
import CoreML

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

    var loadTimeHint: String {
        switch self {
        case .standard: "Fastest loading (~0.3s)"
        case .better: "Slower loading (~1s)"
        case .best: "Slowest loading (~3s)"
        }
    }

    /// Directory name for model files on disk.
    var modelDirName: String {
        "whisper-\(rawValue)"
    }
}

/// Local Whisper transcription engine — raw CoreML, no WhisperKit.
///
/// Architecture:
///   - MelSpectrogram (Accelerate, incremental as audio streams)
///   - AudioEncoder.mlmodelc (CoreML, Neural Engine)
///   - TextDecoder.mlmodelc (CoreML, greedy argmax)
///   - WhisperTokenizer (BPE vocab lookup)
///
/// Loads ~2-5x faster than WhisperKit. Enables pipeline parallelism
/// because we own every stage.
@MainActor
final class WhisperEngine: ObservableObject {

    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var isDownloading = false
    @Published var loadingProgress: String = ""
    @Published var detectedLanguage: String?
    @Published var activePrecision: Precision = .standard
    @Published var downloadedModels: Set<Precision> = []

    private let pipeline = WhisperPipeline()

    init(modelVariant: String = "base") {
        activePrecision = Precision(rawValue: modelVariant) ?? .standard
        // Don't scan on init — do it lazily when needed
    }

    // MARK: - Model lifecycle

    /// Check if model files exist on disk for a given precision.
    static func isModelDownloaded(_ precision: Precision) -> Bool {
        let dir = modelDirectory(for: precision)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    func loadModel(precision: Precision? = nil) async {
        let target = precision ?? activePrecision

        // Don't even try if model files aren't on disk
        guard Self.isModelDownloaded(target) else {
            loadingProgress = "No model"
            print("[Typeoff] Model not downloaded: \(target.label)")
            return
        }

        if target != activePrecision || pipeline.isLoaded {
            pipeline.unload()
            isModelLoaded = false
        }

        activePrecision = target
        loadingProgress = "Loading \(target.label)..."

        do {
            let modelDir = Self.modelDirectory(for: target)
            try await pipeline.load(modelDir: modelDir)
            downloadedModels.insert(target)
            isModelLoaded = true
            loadingProgress = ""

            UserDefaults(suiteName: "group.com.typeoff.shared")?
                .set(target.rawValue, forKey: "modelVariant")

            print("[Typeoff] Engine ready: \(target.label)")
        } catch {
            loadingProgress = "Failed to load"
            print("[Typeoff] Load failed: \(error)")
        }
    }

    func unloadModel() {
        pipeline.unload()
        isModelLoaded = false
        detectedLanguage = nil
    }

    // MARK: - Transcription

    func transcribe(audioSamples: [Float]) async -> String {
        guard pipeline.isLoaded else { return "" }

        isTranscribing = true
        defer { isTranscribing = false }

        let startTime = CFAbsoluteTimeGetCurrent()
        let text = await pipeline.transcribe(audioSamples: audioSamples)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        print("[Typeoff] [\(activePrecision.label)] \(String(format: "%.2f", elapsed))s: \"\(text.prefix(80))\"")
        return text
    }

    // MARK: - Streaming mel (call from recorder for precomputation)

    /// Feed audio chunk to mel processor as it streams in.
    /// Precomputes mel frames so transcribe() skips mel computation.
    func streamMel(_ audioChunk: [Float]) {
        pipeline.streamMel(audioChunk)
    }

    /// Release mel frames before given index (after window slide).
    func trimMel(beforeFrameIndex: Int) {
        pipeline.trimMel(beforeFrameIndex: beforeFrameIndex)
    }

    // MARK: - Model directory management

    /// App Group container — accessible from both main app and keyboard extension.
    private static let appGroupID = "group.com.typeoff.shared"

    private static func modelsRoot() -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            // Fallback to Documents if App Group unavailable (shouldn't happen)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent("WhisperModels")
        }
        let root = container.appendingPathComponent("WhisperModels")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func modelDirectory(for precision: Precision) -> URL {
        modelsRoot().appendingPathComponent(precision.modelDirName)
    }

    private func scanDownloadedModels() {
        for precision in Precision.allCases {
            let dir = Self.modelDirectory(for: precision)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                downloadedModels.insert(precision)
            }
        }
    }
}
