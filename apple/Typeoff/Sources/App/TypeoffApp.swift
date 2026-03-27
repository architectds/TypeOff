import SwiftUI

@main
struct TypeoffApp: App {

    @StateObject private var engine = WhisperEngine(modelVariant: "base")
    @StateObject private var trialManager = TrialManager()
    @StateObject private var storeManager = StoreManager()
    @AppStorage("appearance") private var appearance: String = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(trialManager)
                .environmentObject(storeManager)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

struct ContentView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if !hasCompletedOnboarding {
            OnboardingView()
        } else {
            MainTabView()
        }
    }
}

struct MainTabView: View {

    @EnvironmentObject var trialManager: TrialManager
    @EnvironmentObject var storeManager: StoreManager
    @State private var selectedTab = 1  // Start on Notes (center)

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
                .tag(0)

            NotesView()
                .tabItem {
                    Image(systemName: "note.text")
                    Text("Notes")
                }
                .tag(1)

            ProfileView()
                .tabItem {
                    Image(systemName: "person")
                    Text("Profile")
                }
                .tag(2)
        }
        .tint(Theme.primary)
        .task {
            // Load trial + store only when user reaches the main app
            trialManager.refresh()
            Task { await storeManager.loadProducts() }
        }
    }
}
