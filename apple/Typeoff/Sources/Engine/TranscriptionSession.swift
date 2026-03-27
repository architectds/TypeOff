import Foundation
import Combine

/// Orchestrates recording → rolling transcription → silence detection → final output.
/// Mirrors the Python streaming approach: record continuously, transcribe every 3s,
/// lock text at 30s windows, auto-stop on 8s silence.
@MainActor
final class TranscriptionSession: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case finalizing
        case done
    }

    @Published var state: State = .idle
    @Published var displayText: String = ""
    @Published var lockedText: String = ""

    var engine: WhisperEngine
    private let recorder = AudioRecorder()
    private let silenceDetector = SilenceDetector()

    private let rollInterval: TimeInterval = 3.0
    private let maxWindowSeconds: TimeInterval = 30.0
    private let minAudioForRoll: TimeInterval = 1.5

    private var lockSample: Int = 0
    private var rollTask: Task<Void, Never>?

    /// Callback fired each time a new chunk of text is ready to paste.
    /// In keyboard mode, this calls insertText().
    var onTextReady: ((String) -> Void)?

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    // MARK: - Session control

    func start() {
        guard state == .idle || state == .done else { return }

        lockedText = ""
        displayText = ""
        lockSample = 0
        state = .recording

        do {
            try recorder.start()
        } catch {
            print("[Typeoff] Recorder start failed: \(error)")
            state = .idle
            return
        }

        rollTask = Task { await recordingLoop() }
    }

    func stop() {
        guard state == .recording else { return }
        state = .finalizing
        rollTask?.cancel()
        rollTask = nil

        Task { await finalize() }
    }

    // MARK: - Recording loop

    private func recordingLoop() async {
        while state == .recording && !Task.isCancelled {
            let audio = recorder.getAudio()
            let duration = Double(audio.count) / 16000.0

            // Auto-stop on silence
            if duration > 8.0 && silenceDetector.hasSpeech(audio: audio) {
                if silenceDetector.detectEndOfSpeech(audio: audio) {
                    print("[Typeoff] Silence detected — auto-stopping")
                    stop()
                    return
                }
            }

            // Rolling transcription
            if duration >= minAudioForRoll {
                let windowAudio = lockSample < audio.count
                    ? Array(audio[lockSample...])
                    : audio
                let windowDuration = Double(windowAudio.count) / 16000.0

                if windowDuration >= minAudioForRoll {
                    let text = await engine.transcribe(audioSamples: windowAudio)

                    if !text.isEmpty && !isHallucination(text) {
                        let fullText = lockedText.isEmpty
                            ? text
                            : lockedText + " " + text
                        displayText = fullText
                    }

                    // Slide window at 30s to keep transcription fast
                    if windowDuration > maxWindowSeconds {
                        lockedText = displayText
                        lockSample = audio.count
                        print("[Typeoff] Locked at \(String(format: "%.0f", duration))s")
                    }
                }
            }

            try? await Task.sleep(for: .seconds(rollInterval))
        }
    }

    // MARK: - Finalize

    private func finalize() async {
        let audio = recorder.stop()

        guard silenceDetector.hasSpeech(audio: audio) else {
            displayText = ""
            state = .done
            return
        }

        // Final pass on audio after locked point
        let windowAudio = lockSample < audio.count
            ? Array(audio[lockSample...])
            : audio

        let text = await engine.transcribe(audioSamples: windowAudio)

        if !text.isEmpty && !isHallucination(text) {
            let fullText = lockedText.isEmpty ? text : lockedText + " " + text
            displayText = fullText
            onTextReady?(fullText)
        }

        state = .done
    }

    // MARK: - Hallucination filter

    private static let hallucinations: Set<String> = [
        "", "you", "thank you.", "thanks for watching!", "thanks for watching.",
        "subscribe", "bye.", "bye", "thank you", "you.", "the end.",
        "thanks for listening.", "see you next time.", "thank you for watching.",
        "...",
    ]

    private func isHallucination(_ text: String) -> Bool {
        Self.hallucinations.contains(text.lowercased().trimmingCharacters(in: .whitespaces))
    }
}
