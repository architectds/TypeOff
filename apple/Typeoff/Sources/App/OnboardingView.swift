import SwiftUI
import AVFoundation

struct OnboardingView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            welcomePage.tag(0)
            micPermissionPage.tag(1)
            keyboardSetupPage.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Theme.surface)
    }

    // MARK: - Pages

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

    private var keyboardSetupPage: some View {
        VStack(spacing: 28) {
            Spacer()

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

            Spacer()

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

            Spacer().frame(height: 50)
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

            Text(text)
                .font(.body)
                .foregroundStyle(Theme.onSurface)
        }
    }

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                withAnimation { currentPage = 2 }
            }
        }
    }
}

#Preview {
    OnboardingView()
}
