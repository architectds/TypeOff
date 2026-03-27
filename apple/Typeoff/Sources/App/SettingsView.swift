import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var trialManager: TrialManager
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var engine: WhisperEngine

    @AppStorage("silenceDuration", store: UserDefaults(suiteName: "group.com.typeoff.shared"))
    private var silenceDuration: Double = 5.0

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .sectionContainer()
                .padding(.top, 16)

                // Keyboard setup
                keyboardSection

                // Precision
                precisionSection

                // Transcription
                transcriptionSection

                Spacer(minLength: 40)
            }
        }
        .background(Theme.surface)
    }

    // MARK: - Keyboard

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.headline("KEYBOARD")
                .padding(.leading, 4)

            VStack(spacing: 0) {
                Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                    HStack {
                        Image(systemName: "keyboard")
                            .font(.body)
                            .foregroundStyle(Theme.primary)
                            .frame(width: 32)

                        Text("Enable TypeOff Keyboard")
                            .font(.body)
                            .foregroundStyle(Theme.onSurface)

                        Spacer()

                        Image(systemName: "arrow.up.forward")
                            .font(.caption)
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }
                    .padding(16)
                }

                Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → TypeOff")
                    .font(.caption)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .background(Theme.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .sectionContainer()
    }

    // MARK: - Precision

    private var precisionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.headline("PRECISION")
                .padding(.leading, 4)

            VStack(spacing: 2) {
                ForEach(Precision.allCases) { precision in
                    precisionRow(precision)
                }
            }
            .background(Theme.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

            if engine.isDownloading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(engine.loadingProgress)
                        .font(.caption)
                        .foregroundStyle(Theme.onSurfaceVariant)
                }
                .padding(.leading, 4)
            }

            Text("Higher precision is more accurate but uses more storage and loads slower.")
                .font(.caption)
                .foregroundStyle(Theme.onSurfaceVariant)
                .padding(.leading, 4)
        }
        .sectionContainer()
    }

    private func precisionRow(_ precision: Precision) -> some View {
        Button {
            guard !engine.isDownloading else { return }
            Task { await engine.loadModel(precision: precision) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(precision.label)
                        .font(.body)
                        .foregroundStyle(Theme.onSurface)
                    Text("\(precision.sizeLabel) · \(precision.loadTimeHint)")
                        .font(.caption)
                        .foregroundStyle(Theme.onSurfaceVariant)
                }

                Spacer()

                if engine.activePrecision == precision && engine.isModelLoaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                } else if engine.downloadedModels.contains(precision) {
                    Circle()
                        .strokeBorder(Theme.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.primary)
                }
            }
            .padding(16)
        }
        .disabled(engine.isDownloading)
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.headline("TRANSCRIPTION")
                .padding(.leading, 4)

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Silence timeout")
                            .font(.body)
                            .foregroundStyle(Theme.onSurface)
                        Spacer()
                        Text("\(Int(silenceDuration))s")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Theme.onSurfaceVariant)
                    }

                    Slider(value: $silenceDuration, in: 3...15, step: 1)
                        .tint(Theme.primary)
                }
                .padding(16)
            }
            .background(Theme.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .sectionContainer()
    }
}

#Preview {
    SettingsView()
        .environmentObject(WhisperEngine())
        .environmentObject(TrialManager())
        .environmentObject(StoreManager())
}
