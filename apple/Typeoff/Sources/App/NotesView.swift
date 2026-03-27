import SwiftUI

/// Placeholder notes tab — to be built out.
/// Will serve as a scratchpad for voice-transcribed text.
struct NotesView: View {

    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $noteText)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()

                HStack {
                    Button {
                        UIPasteboard.general.string = noteText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(noteText.isEmpty)

                    Button(role: .destructive) {
                        noteText = ""
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(noteText.isEmpty)
                }
                .padding(.bottom)
            }
            .navigationTitle("Notes")
        }
    }
}

#Preview {
    NotesView()
}
