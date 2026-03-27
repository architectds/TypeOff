import Foundation
import StoreKit

/// StoreKit 2 manager for the one-time $9.99 purchase.
@MainActor
final class StoreManager: ObservableObject {

    @Published var product: Product?
    @Published var isPurchased = false

    private static let productID = "com.typeoff.unlimited"

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            print("[Typeoff] Failed to load products: \(error)")
        }

        // Check existing entitlement
        await updatePurchaseStatus()

        // Listen for transaction updates (e.g. family sharing, ask-to-buy)
        Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let tx) = result {
                    await tx.finish()
                    await self?.updatePurchaseStatus()
                }
            }
        }
    }

    func purchase() async {
        guard let product else { return }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    await tx.finish()
                    isPurchased = true
                    TrialManager.markPurchased()
                }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            print("[Typeoff] Purchase failed: \(error)")
        }
    }

    func restorePurchases() async {
        try? await AppStore.sync()
        await updatePurchaseStatus()
    }

    private func updatePurchaseStatus() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               tx.productID == Self.productID {
                isPurchased = true
                TrialManager.markPurchased()
                return
            }
        }
    }
}
