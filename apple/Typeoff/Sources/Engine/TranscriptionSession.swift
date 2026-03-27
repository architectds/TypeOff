import Foundation
import Combine

/// Port of Python `streamer.py` — sentence-based sliding window + LocalAgreement.
///
/// Strategy:
///   1. Record continuously, transcribe rolling buffer every 3s
///   2. Word-level LocalAgreement: only trust words that match across 2 runs
///   3. When a complete sentence is confirmed → LOCK it, fire onSentence, slide window
///   4. Re-transcribe only the audio after the locked sentence (~5-10s)
///   5. Final pass: re-transcribe last incomplete sentence for accuracy
@MainActor
final class TranscriptionSession: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case finalizing
        case done
    }

    @Published var state: State = .idle
    @Published var displayText: String = ""   // full text (locked + pending) — for Notes/app use
    @Published var previewText: String = ""   // pending only — for keyboard preview bar

    var engine: WhisperEngine
    private let recorder = AudioRecorder()
    private let silenceDetector = SilenceDetector()

    // Streaming state — mirrors Python StreamingTranscriber
    private var prevWords: [String] = []
    private var confirmedWords: [String] = []
    private var lockedText: String = ""
    private var pendingText: String = ""
    private var windowStartSample: Int = 0

    // One-sentence buffer: only flush N when N+1 starts confirming OR timeout
    private var bufferedSentence: String? = nil
    private var bufferTimestamp: Date? = nil      // when sentence entered the buffer
    private var bufferStableCount: Int = 0        // how many rolls the buffer survived unchanged
    private let bufferTimeoutSeconds: TimeInterval = 8.0  // max wait before force-flush
    private let bufferStableThreshold: Int = 3            // flush if stable across 3 rolls

    // Delayed trim: only release audio/mel after the buffer is flushed (N+2 safety)
    private var pendingTrimPoint: Int? = nil
    private var lastTrimPoint: Int? = nil

    private let sampleRate = 16000
    private let rollInterval: TimeInterval = 3.0
    private var rollTask: Task<Void, Never>?

    /// Called each time a complete sentence is locked — keyboard calls insertText() here.
    var onSentence: ((String) -> Void)?
    /// Called once at the end with any remaining fragment.
    var onFinalRemainder: ((String) -> Void)?

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    // MARK: - Session control

    func start() {
        guard state == .idle || state == .done else { return }

        // Reset streaming state
        prevWords = []
        confirmedWords = []
        lockedText = ""
        pendingText = ""
        windowStartSample = 0
        bufferedSentence = nil
        bufferTimestamp = nil
        bufferStableCount = 0
        pendingTrimPoint = nil
        lastTrimPoint = nil
        displayText = ""
        previewText = ""
        state = .recording

        // Wire recorder → engine mel precomputation (zero mel wait at transcribe time)
        recorder.onAudioChunk = { [weak self] chunk in
            self?.engine.streamMel(chunk)
        }

        // Graceful stop on audio interruption (phone call, Siri, etc.)
        recorder.onInterruption = { [weak self] in
            self?.stop()
        }

        // Sync silence detector with calibrated noise floor
        recorder.onNoiseFloorCalibrated = { [weak self] noiseFloor in
            self?.silenceDetector.updateThreshold(noiseFloor: noiseFloor)
        }

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

    // MARK: - Buffer flush

    private func flushBuffer() {
        guard let buffered = bufferedSentence else { return }
        onSentence?(buffered)
        bufferedSentence = nil
        bufferTimestamp = nil
        bufferStableCount = 0

        // Trim old audio/mel now that flushed sentence is committed
        if let trimPoint = lastTrimPoint {
            engine.trimMel(beforeFrameIndex: trimPoint)
        }
    }

    // MARK: - Recording loop

    private func recordingLoop() async {
        while state == .recording && !Task.isCancelled {
            let audio = recorder.getAudio()
            let duration = Double(audio.count) / Double(sampleRate)

            // Auto-stop on silence
            if duration > 5.0 && silenceDetector.hasSpeech(audio: audio) {
                if silenceDetector.detectEndOfSpeech(audio: audio) {
                    print("[Typeoff] Silence detected — auto-stopping")
                    stop()
                    return
                }
            }

            // Rolling transcription
            if duration >= 1.5 {
                let result = await rollingTranscribe(fullAudio: audio)
                if let sentence = result.newSentence {
                    // New sentence locked — flush the PREVIOUS buffered one
                    flushBuffer()
                    bufferedSentence = sentence
                    bufferTimestamp = Date()
                    bufferStableCount = 0
                    lastTrimPoint = pendingTrimPoint
                } else if bufferedSentence != nil {
                    // No new sentence — check if buffer should flush on timeout or stability
                    bufferStableCount += 1

                    let timedOut = bufferTimestamp.map { Date().timeIntervalSince($0) >= bufferTimeoutSeconds } ?? false
                    let stable = bufferStableCount >= bufferStableThreshold

                    if timedOut || stable {
                        let reason = timedOut ? "timeout" : "stable×\(bufferStableCount)"
                        print("[Typeoff] Buffer flush (\(reason))")
                        flushBuffer()
                    }
                }
                // Update displays
                previewText = pendingText  // keyboard: only show uncommitted text
                if !lockedText.isEmpty || !pendingText.isEmpty {
                    let display = pendingText.isEmpty
                        ? lockedText
                        : (lockedText + " " + pendingText).trimmingCharacters(in: .whitespaces)
                    displayText = display  // app: full text
                }
            }

            try? await Task.sleep(for: .seconds(rollInterval))
        }
    }

    // MARK: - Rolling transcription (port of Python rolling_transcribe)

    private struct RollResult {
        let newSentence: String?
        let pending: String
    }

    private func rollingTranscribe(fullAudio: [Float]) async -> RollResult {
        // Slice to current window
        let windowAudio: [Float]
        if windowStartSample < fullAudio.count {
            windowAudio = Array(fullAudio[windowStartSample...])
        } else {
            windowAudio = fullAudio
        }

        // Skip if too short
        guard windowAudio.count >= sampleRate / 2 else {
            return RollResult(newSentence: nil, pending: pendingText)
        }

        let text = await engine.transcribe(audioSamples: windowAudio)

        // Hallucination filter
        guard !Self.hallucinations.contains(text.lowercased().trimmingCharacters(in: .whitespaces)) else {
            return RollResult(newSentence: nil, pending: pendingText)
        }

        let currentWords = text.split(separator: " ").map(String.init)

        // Word-level LocalAgreement
        let agreed = commonPrefixWords(prevWords, currentWords)
        let newConfirmed = agreed.count > confirmedWords.count
            ? Array(agreed[confirmedWords.count...])
            : []
        prevWords = currentWords

        if !newConfirmed.isEmpty {
            confirmedWords = agreed
        }

        let confirmedText = confirmedWords.joined(separator: " ")

        // Check for complete sentences
        let (complete, remainder) = extractCompleteSentences(confirmedText)

        var newSentence: String? = nil

        if !complete.isEmpty && complete != lockedText {
            // New sentence confirmed — lock and slide
            var sentence = String(complete.dropFirst(lockedText.count))
                .trimmingCharacters(in: .whitespaces)
            if !lockedText.isEmpty {
                sentence = " " + sentence
            }
            newSentence = sentence

            lockedText = complete
            pendingText = remainder

            // Slide window: estimate where locked audio ends
            if !currentWords.isEmpty {
                let lockedWordCount = complete.split(separator: " ").count
                let ratio = Double(lockedWordCount) / Double(currentWords.count)
                let slideSamples = Int(ratio * Double(windowAudio.count))
                windowStartSample += slideSamples

                // Don't trim yet — store trim point, will trim when buffer flushes (N+2 safety)
                pendingTrimPoint = slideSamples / 160  // hop_length = 160
            }

            // Reset agreement for new window
            prevWords = remainder.isEmpty ? [] : remainder.split(separator: " ").map(String.init)
            confirmedWords = prevWords

            print("[Typeoff] LOCKED: \"\(sentence.trimmingCharacters(in: .whitespaces))\"")
        } else {
            // Update pending
            if confirmedText.hasPrefix(lockedText) {
                pendingText = String(confirmedText.dropFirst(lockedText.count))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                pendingText = confirmedText
            }
        }

        return RollResult(newSentence: newSentence, pending: pendingText)
    }

    // MARK: - Finalize (port of Python final_transcribe)

    private func finalize() async {
        let audio = recorder.stop()

        // Flush anything still in the buffer
        flushBuffer()

        guard silenceDetector.hasSpeech(audio: audio) else {
            previewText = ""
            state = .done
            return
        }

        // Transcribe remaining audio after last locked sentence
        let windowAudio: [Float]
        if windowStartSample < audio.count {
            windowAudio = Array(audio[windowStartSample...])
        } else {
            windowAudio = audio
        }

        guard windowAudio.count >= sampleRate / 3 else {
            previewText = ""
            state = .done
            return
        }

        var text = await engine.transcribe(audioSamples: windowAudio)

        if Self.hallucinations.contains(text.lowercased().trimmingCharacters(in: .whitespaces)) {
            text = ""
        }

        let finalRemainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalRemainder.isEmpty {
            let spacedRemainder = lockedText.isEmpty ? finalRemainder : " " + finalRemainder
            onFinalRemainder?(spacedRemainder)
            displayText = (lockedText + spacedRemainder).trimmingCharacters(in: .whitespaces)
        }

        previewText = ""
        state = .done
    }

    // MARK: - Helpers (ported from Python)

    /// Longest common prefix between two word lists.
    private func commonPrefixWords(_ a: [String], _ b: [String]) -> [String] {
        let length = min(a.count, b.count)
        for i in 0..<length {
            if a[i] != b[i] {
                return Array(a[0..<i])
            }
        }
        return Array(a[0..<length])
    }

    /// Split text into (complete sentences, remainder).
    private func extractCompleteSentences(_ text: String) -> (String, String) {
        let sentenceEndPattern = /[.!?。！？]\s*$/
        let sentenceSplitPattern = /(?<=[.!?。！？])\s+/

        let parts = text.split(separator: sentenceSplitPattern).map(String.init)

        if parts.count <= 1 {
            if text.firstMatch(of: sentenceEndPattern) != nil {
                return (text, "")
            }
            return ("", text)
        }

        // Check if last part also ends with punctuation
        if let last = parts.last, last.firstMatch(of: sentenceEndPattern) != nil {
            return (text, "")
        }

        let complete = parts.dropLast().joined(separator: " ")
        let remainder = parts.last ?? ""
        return (complete, remainder)
    }

    // MARK: - Hallucination filter

    private static let hallucinations: Set<String> = [
        "", "you", "thank you.", "thanks for watching!", "thanks for watching.",
        "subscribe", "bye.", "bye", "thank you", "you.", "the end.",
        "thanks for listening.", "see you next time.", "thank you for watching.",
        "...", "mbc 뉴스 , 이덕영입니다.", "字幕by索兰娅梦", "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
    ]
}
