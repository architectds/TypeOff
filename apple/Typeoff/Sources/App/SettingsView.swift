import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var trialManager: TrialManager
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var engine: WhisperEngine

    @AppStorage("silenceDuration", store: UserDefaults(suiteName: "group.com.typeoff.shared"))
    private var silenceDuration: Double = 5.0

    var body: some View {
        NavigationStack {
            Form {
                // Keyboard setup
                Section {
                    Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                        HStack {
                            Label("Enable Typeoff Keyboard", systemImage: "keyboard")
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Typeoff")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Keyboard")
                }

                // Precision picker
                Section {
                    ForEach(Precision.allCases) { precision in
                        precisionRow(precision)
                    }

                    if engine.isDownloading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text(engine.loadingProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Precision")
                } footer: {
                    Text("Higher precision is more accurate but uses more storage and is slightly slower.")
                }

                Section("Transcription") {
                    VStack(alignment: .leading) {
                        Text("Silence timeout: \(Int(silenceDuration))s")
                        Slider(value: $silenceDuration, in: 3...15, step: 1)
                    }
                }

                Section("Account") {
                    if trialManager.isPurchased {
                        Label("Typeoff Unlimited", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else if trialManager.isTrialActive {
                        let days = trialManager.trialDaysRemaining
                        Label("Trial: \(days) day\(days == 1 ? "" : "s") left", systemImage: "clock")
                            .foregroundStyle(.orange)

                        Button("Unlock — $9.99") {
                            Task { await storeManager.purchase() }
                        }
                    } else {
                        Label("Trial expired", systemImage: "lock.fill")
                            .foregroundStyle(.red)

                        Button("Unlock — $9.99") {
                            Task { await storeManager.purchase() }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Restore Purchase") {
                        Task { await storeManager.restorePurchases() }
                    }
                    .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Precision row

    private func precisionRow(_ precision: Precision) -> some View {
        Button {
            guard !engine.isDownloading else { return }
            Task { await engine.loadModel(precision: precision) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(precision.label)
                        .foregroundStyle(.primary)
                    Text(precision.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if engine.activePrecision == precision && engine.isModelLoaded {
                    // Active
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if engine.downloadedModels.contains(precision) {
                    // Downloaded but not active
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                } else {
                    // Not downloaded — will trigger download
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
            }
        }
        .disabled(engine.isDownloading)
    }
}

#Preview {
    SettingsView()
        .environmentObject(WhisperEngine())
        .environmentObject(TrialManager())
        .environmentObject(StoreManager())
}
