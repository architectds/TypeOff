import SwiftUI

/// SwiftUI view for the keyboard extension — mic button + live preview.
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
            // Preview bar
            if !previewText.isEmpty {
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
            }

            // Button row
            HStack(spacing: 16) {
                // Globe button — switch keyboard
                Button { onNextKeyboard() } label: {
                    Image(systemName: "globe")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.primary)

                Spacer()

                // Mic button
                Button {
                    handleMicTap()
                } label: {
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
            // Stop
            session?.stop()
            isRecording = false
        } else {
            // Start
            let s = TranscriptionSession(engine: engine)
            s.onTextReady = { text in
                onInsertText(text)
                previewText = ""
            }
            session = s

            // Update preview during recording
            Task {
                s.start()
                isRecording = true
                while isRecording {
                    previewText = s.displayText
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }
}
