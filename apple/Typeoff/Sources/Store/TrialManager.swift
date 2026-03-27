import Foundation

/// Manages 7-day free trial. Stores first launch date in App Group UserDefaults
/// so the keyboard extension can also check trial status.
@MainActor
final class TrialManager: ObservableObject {

    @Published var isTrialActive = false
    @Published var isPurchased = false
    @Published var trialDaysRemaining = 7

    private static let suiteName = "group.com.typeoff.shared"
    private static let firstLaunchKey = "firstLaunchDate"
    private static let purchasedKey = "isPurchased"
    private static let trialDays = 7

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    init() {
        // Don't hit UserDefaults on init — refresh when UI needs it
    }

    /// Check access: either in trial or purchased.
    var hasAccess: Bool {
        isPurchased || isTrialActive
    }

    /// Refresh trial state from UserDefaults.
    func refresh() {
        guard let defaults = Self.sharedDefaults else {
            isTrialActive = true  // Fallback: allow access if defaults unavailable
            return
        }

        // Check purchase
        if defaults.bool(forKey: Self.purchasedKey) {
            isPurchased = true
            isTrialActive = true
            return
        }

        // Record first launch if not set
        if defaults.object(forKey: Self.firstLaunchKey) == nil {
            defaults.set(Date(), forKey: Self.firstLaunchKey)
        }

        guard let firstLaunch = defaults.object(forKey: Self.firstLaunchKey) as? Date else {
            isTrialActive = true
            return
        }

        let daysSince = Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
        trialDaysRemaining = max(0, Self.trialDays - daysSince)
        isTrialActive = trialDaysRemaining > 0
    }

    /// Mark as purchased (called by StoreManager).
    static func markPurchased() {
        sharedDefaults?.set(true, forKey: purchasedKey)
    }

    /// Check access without instance (for keyboard extension).
    static func hasAccessStatic() -> Bool {
        guard let defaults = sharedDefaults else { return true }
        if defaults.bool(forKey: purchasedKey) { return true }
        guard let firstLaunch = defaults.object(forKey: firstLaunchKey) as? Date else { return true }
        let days = Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
        return days < trialDays
    }
}
