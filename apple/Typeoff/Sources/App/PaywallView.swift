import SwiftUI

struct PaywallView: View {

    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var trialManager: TrialManager
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "mic.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)

                Text("Typeoff Unlimited")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 12) {
                    feature(icon: "infinity", text: "Unlimited transcription")
                    feature(icon: "wifi.slash", text: "100% offline — no cloud")
                    feature(icon: "lock.shield", text: "Your voice stays on device")
                    feature(icon: "dollarsign.arrow.circlepath", text: "One-time purchase — no subscription")
                }
                .padding(.horizontal)

                Spacer()

                // Price
                VStack(spacing: 8) {
                    if let product = storeManager.product {
                        Button {
                            isPurchasing = true
                            Task {
                                await storeManager.purchase()
                                isPurchasing = false
                                if trialManager.isPurchased {
                                    dismiss()
                                }
                            }
                        } label: {
                            Text("Unlock — \(product.displayPrice)")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isPurchasing)
                    } else {
                        ProgressView()
                    }

                    Button("Restore Purchase") {
                        Task { await storeManager.restorePurchases() }
                    }
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                }

                Spacer().frame(height: 20)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func feature(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    PaywallView()
        .environmentObject(StoreManager())
        .environmentObject(TrialManager())
}
