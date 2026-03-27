import UIKit
import SwiftUI

/// Custom keyboard extension — mic button in toolbar for voice-to-text in any app.
class KeyboardViewController: UIInputViewController {

    private var engine: WhisperEngine?
    private var session: TranscriptionSession?
    private var hostingController: UIHostingController<KeyboardView>?
    private var unloadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let keyboardView = KeyboardView(
            onInsertText: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            onDeleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onNextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )

        let hc = UIHostingController(rootView: keyboardView)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hc)
        view.addSubview(hc.view)

        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hc.didMove(toParent: self)
        hostingController = hc
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Cancel any pending unload — user came back
        unloadTask?.cancel()
        unloadTask = nil

        // Preload from cache when keyboard appears
        Task {
            if engine == nil {
                let variant = UserDefaults(suiteName: "group.com.typeoff.shared")?
                    .string(forKey: "modelVariant") ?? "base"
                engine = WhisperEngine(modelVariant: variant)
            }
            await engine?.loadModel()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        // Unload after 30s idle — cancelled if keyboard reappears
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.engine?.unloadModel() }
        }
    }
}
