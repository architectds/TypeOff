import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var trialManager: TrialManager
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var engine: WhisperEngine

    @AppStorage("silenceDuration", store: UserDefaults(suiteName: "group.com.typeoff.shared"))
    private var silenceDuration: Double = 8.0

    var body: some View {
        NavigationStack {
            Form {
                // Keyboard setup — most important
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

                Section("Transcription") {
                    VStack(alignment: .leading) {
                        Text("Silence timeout: \(Int(silenceDuration))s")
                        Slider(value: $silenceDuration, in: 3...15, step: 1)
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        Text(engine.isModelLoaded ? "Ready" : "Loading...")
                            .foregroundStyle(engine.isModelLoaded ? .green : .secondary)
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
}

#Preview {
    SettingsView()
        .environmentObject(WhisperEngine())
        .environmentObject(TrialManager())
        .environmentObject(StoreManager())
}
