import SwiftUI

/// SwiftUI view for the keyboard extension — mic button + live preview.
/// Text is inserted sentence-by-sentence via onSentence callback (not all at once at the end).
struct KeyboardView: View {

    let onInsertText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onNextKeyboard: () -> Void

    @StateObject private var engine = WhisperEngine(modelVariant: "base")
    @State private var session: TranscriptionSession?
    @State private var isRecording = false
    @State private var previewText = ""
    @State private var hasAccess = true

    var body: some View {
        VStack(spacing: 0) {
            // Preview bar — shows pending (in-progress) text
            if !previewText.isEmpty || !engine.isModelLoaded {
                Text(engine.isModelLoaded ? previewText : engine.loadingProgress)
                    .font(.caption)
                    .foregroundStyle(engine.isModelLoaded ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
            }

            // Button row
            HStack(spacing: 16) {
                // Globe — switch keyboard
                Button { onNextKeyboard() } label: {
                    Image(systemName: "globe")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.primary)

                Spacer()

                // Mic button
                Button { handleMicTap() } label: {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.blue)
                            .frame(width: 52, height: 52)

                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
                .disabled(!engine.isModelLoaded)

                Spacer()

                // Backspace
                Button { onDeleteBackward() } label: {
                    Image(systemName: "delete.backward")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 80)
        .background(Color(.systemBackground))
        .task {
            hasAccess = TrialManager.hasAccessStatic()
            await engine.loadModel()
        }
    }

    private func handleMicTap() {
        guard hasAccess else { return }

        if isRecording {
            session?.stop()
            isRecording = false
            previewText = ""
        } else {
            let s = TranscriptionSession(engine: engine)

            // Sentence-by-sentence insertion — each locked sentence goes into the text field
            s.onSentence = { sentence in
                onInsertText(sentence)
            }
            // Final remainder after recording stops
            s.onFinalRemainder = { remainder in
                onInsertText(remainder)
                previewText = ""
            }

            session = s
            s.start()
            isRecording = true

            // Poll display text for preview bar
            Task {
                while isRecording {
                    previewText = s.displayText
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }
}
