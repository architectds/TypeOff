import SwiftUI

@main
struct TypeoffApp: App {

    @StateObject private var engine = WhisperEngine(modelVariant: "base")
    @StateObject private var trialManager = TrialManager()
    @StateObject private var storeManager = StoreManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(trialManager)
                .environmentObject(storeManager)
                .task {
                    await engine.loadModel()
                    await storeManager.loadProducts()
                }
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
    var body: some View {
        TabView {
            NotesView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
