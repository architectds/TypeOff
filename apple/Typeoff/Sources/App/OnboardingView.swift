import SwiftUI
import AVFoundation

struct OnboardingView: View {

    @EnvironmentObject var engine: WhisperEngine
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var downloader = ModelDownloader()
    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            welcomePage.tag(0)
            micPermissionPage.tag(1)
            modelDownloadPage.tag(2)
            keyboardSetupPage.tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Theme.surface)
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.primary)

            VStack(spacing: 8) {
                Text("TypeOff")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.onSurface)

                Text("Voice to text.\nOffline. Private. Forever.")
                    .font(.system(size: 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineSpacing(4)
            }

            Spacer()

            Button("Get Started") {
                withAnimation { currentPage = 1 }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous))
            .sectionContainer()

            Spacer().frame(height: 50)
        }
    }

    // MARK: - Page 1: Mic permission

    private var micPermissionPage: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Microphone Access")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                Text("TypeOff needs microphone access to hear your voice. Audio is processed entirely on your device.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button("Allow Microphone") {
                requestMicPermission()
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous))
            .sectionContainer()

            Spacer().frame(height: 50)
        }
    }

    // MARK: - Page 2: Model download

    private var modelDownloadPage: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.primary)

            VStack(spacing: 8) {
                Text("Download Voice Engine")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                Text("TypeOff uses a 74 MB speech model that runs entirely on your device. Download it once, then go offline forever.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }

            if downloader.isDownloading {
                VStack(spacing: 12) {
                    ProgressView(value: downloader.progress)
                        .tint(Theme.primary)

                    Text(downloader.statusText)
                        .font(.caption)
                        .foregroundStyle(Theme.onSurfaceVariant)

                    Text("\(Int(downloader.progress * 100))%")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(Theme.onSurface)
                }
                .sectionContainer()
            } else if let error = downloader.error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        startDownload()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primary)
                }
                .sectionContainer()
            } else if engine.isModelLoaded {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.success)

                    Text("Voice engine ready")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.success)
                }
            }

            Spacer()

            if engine.isModelLoaded {
                Button("Continue") {
                    withAnimation { currentPage = 3 }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.primaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous))
                .sectionContainer()
            } else if !downloader.isDownloading {
                Button("Download (74 MB)") {
                    startDownload()
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.primaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous))
                .sectionContainer()
            }

            Spacer().frame(height: 50)
        }
    }

    // MARK: - Page 3: Keyboard setup

    private var keyboardSetupPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Image(systemName: "keyboard")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.success)

                Text("Enable Keyboard")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                VStack(alignment: .leading, spacing: 14) {
                    step(number: 1, text: "Open Settings → General → Keyboard")
                    step(number: 2, text: "Tap Keyboards → Add New Keyboard")
                    step(number: 3, text: "Select TypeOff")
                    step(number: 4, text: "Allow Full Access (for microphone)")
                }
                .tonalCard(color: Theme.surfaceContainerLowest)
                .sectionContainer()

                Text("Full Access is required for microphone recording. TypeOff never logs keystrokes, never sends data anywhere, and works 100% offline.")
                    .font(.caption)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 12) {
                    Button("Done") {
                        hasCompletedOnboarding = true
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.primaryGradient)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.pillRadius, style: .continuous))

                    Button("Skip for now") {
                        hasCompletedOnboarding = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.onSurfaceVariant)
                }
                .sectionContainer()

                Spacer().frame(height: 60)
            }
        }
    }

    // MARK: - Helpers

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.primary)
                .clipShape(Circle())
                .fixedSize()

            Text(text)
                .font(.body)
                .foregroundStyle(Theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                withAnimation { currentPage = 2 }
            }
        }
    }

    private func startDownload() {
        Task {
            let success = await downloader.download(precision: .standard)
            if success {
                await engine.loadModel(precision: .standard)
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(WhisperEngine())
}
