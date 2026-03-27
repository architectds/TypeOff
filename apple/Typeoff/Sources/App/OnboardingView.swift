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
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Typeoff")
                .font(.largeTitle.bold())

            Text("Voice to text.\nOffline. Private. Forever.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Get Started") {
                withAnimation { currentPage = 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding()
    }

    private var micPermissionPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Microphone Access")
                .font(.title2.bold())

            Text("Typeoff needs microphone access to hear your voice. Audio is processed entirely on your device — nothing is sent anywhere.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Allow Microphone") {
                requestMicPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 40)
        }
        .padding()
    }

    private var keyboardSetupPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Enable Keyboard")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                step(number: 1, text: "Open Settings → General → Keyboard")
                step(number: 2, text: "Tap Keyboards → Add New Keyboard")
                step(number: 3, text: "Select Typeoff")
                step(number: 4, text: "Allow Full Access (for paste)")
            }
            .padding()

            Spacer()

            Button("Done") {
                hasCompletedOnboarding = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Skip for now") {
                hasCompletedOnboarding = true
            }
            .foregroundStyle(.secondary)

            Spacer().frame(height: 40)
        }
        .padding()
    }

    // MARK: - Helpers

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue))

            Text(text)
                .font(.body)
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
