import Foundation

/// Downloads Whisper CoreML models from HuggingFace.
/// Source: argmaxinc/whisperkit-coreml (pre-compiled .mlmodelc bundles)
@MainActor
final class ModelDownloader: ObservableObject {

    @Published var isDownloading = false
    @Published var progress: Double = 0       // 0..1
    @Published var statusText: String = ""
    @Published var error: String?

    private let repo = "argmaxinc/whisperkit-coreml"
    private let session = URLSession.shared

    // Model directory names on HuggingFace
    private static let hfModelDirs: [Precision: String] = [
        .standard: "openai_whisper-base",
        .better: "openai_whisper-small",
        .best: "openai_whisper-large-v3",
    ]

    // The two mlmodelc bundles we need
    private let modelComponents = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    /// Download a model to the App Group container.
    func download(precision: Precision) async -> Bool {
        guard let hfDir = Self.hfModelDirs[precision] else { return false }

        isDownloading = true
        progress = 0
        error = nil
        statusText = "Preparing download..."

        let destDir = WhisperEngine.modelDirectory(for: precision)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            var totalFiles = 0
            var downloadedFiles = 0

            // For each model component (AudioEncoder, TextDecoder), list files then download
            for component in modelComponents {
                statusText = "Fetching \(component) file list..."
                let files = try await listFiles(repo: repo, path: "\(hfDir)/\(component)")
                totalFiles += files.count

                for file in files {
                    let relativePath = file.replacingOccurrences(of: "\(hfDir)/", with: "")
                    statusText = "Downloading \(relativePath.split(separator: "/").last ?? "...")..."

                    let fileURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
                    let localPath = destDir.appendingPathComponent(relativePath)

                    try FileManager.default.createDirectory(
                        at: localPath.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )

                    try await downloadFile(from: fileURL, to: localPath)
                    downloadedFiles += 1
                    progress = Double(downloadedFiles) / Double(max(totalFiles, 1))
                }
            }

            // Also download vocab.json if not bundled
            statusText = "Finalizing..."
            progress = 1.0
            isDownloading = false
            statusText = "Ready"
            return true

        } catch {
            self.error = error.localizedDescription
            statusText = "Download failed"
            isDownloading = false
            // Clean up partial download
            try? FileManager.default.removeItem(at: destDir)
            return false
        }
    }

    /// List all files in a HuggingFace repo directory (recursive).
    private func listFiles(repo: String, path: String) async throws -> [String] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(path)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DownloadError.listFailed(path)
        }

        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.parseFailed
        }

        var files: [String] = []
        for item in items {
            guard let type = item["type"] as? String,
                  let rpath = item["path"] as? String else { continue }

            if type == "file" {
                files.append(rpath)
            } else if type == "directory" {
                // Recurse into subdirectories
                let subFiles = try await listFiles(repo: repo, path: rpath)
                files.append(contentsOf: subFiles)
            }
        }
        return files
    }

    /// Download a single file with resume support.
    private func downloadFile(from url: URL, to localPath: URL) async throws {
        // Skip if already downloaded
        if FileManager.default.fileExists(atPath: localPath.path) {
            return
        }

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DownloadError.downloadFailed(url.lastPathComponent)
        }

        try FileManager.default.moveItem(at: tempURL, to: localPath)
    }

    enum DownloadError: LocalizedError {
        case listFailed(String)
        case parseFailed
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .listFailed(let path): "Failed to list files at \(path)"
            case .parseFailed: "Failed to parse file list"
            case .downloadFailed(let file): "Failed to download \(file)"
            }
        }
    }
}
