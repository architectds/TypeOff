import SwiftUI

/// SwiftUI view for the keyboard extension — mic button + live preview.
/// Text is inserted sentence-by-sentence via onSentence callback (not all at once at the end).
struct KeyboardView: View {

    @ObservedObject var engine: WhisperEngine
    let onInsertText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onNextKeyboard: () -> Void

    @State private var session: TranscriptionSession?
    @State private var isRecording = false
    @State private var previewText = ""
    @State private var hasAccess = true
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            // Preview bar — shows pending (in-progress) text, or loading hint
            if !previewText.isEmpty || !engine.isModelLoaded {
                Text(engine.isModelLoaded
                     ? previewText
                     : "Loading voice engine...")
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
                            .fill(isRecording ? Color.red : (engine.isModelLoaded ? Color.blue : Color.blue.opacity(0.3)))
                            .frame(width: 52, height: 52)

                        if !engine.isModelLoaded {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: isRecording ? "mic.slash.fill" : "mic.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
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
        .onAppear {
            hasAccess = TrialManager.hasAccessStatic()
        }
    }

    private func handleMicTap() {
        guard hasAccess, !isProcessing else { return }

        if isRecording {
            isProcessing = true
            session?.stop()
            isRecording = false
            previewText = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isProcessing = false }
        } else {
            let s = TranscriptionSession(engine: engine)

            s.onSentence = { sentence in
                onInsertText(sentence)
            }
            s.onFinalRemainder = { remainder in
                onInsertText(remainder)
                previewText = ""
            }

            session = s
            s.start()
            isRecording = true

            Task {
                while isRecording {
                    previewText = s.previewText
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }
}
