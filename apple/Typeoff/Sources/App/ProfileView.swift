import SwiftUI

struct ProfileView: View {

    @EnvironmentObject var trialManager: TrialManager
    @EnvironmentObject var storeManager: StoreManager
    @AppStorage("appearance") private var appearance: String = "system"

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                Text("Profile")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionContainer()
                    .padding(.top, 16)

                // Profile card
                profileCard

                // Account
                accountSection

                // Appearance
                appearanceSection

                // Info
                infoSection

                Spacer(minLength: 40)
            }
        }
        .background(Theme.surface)
    }

    // MARK: - Profile card

    private var profileCard: some View {
        HStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Theme.surfaceContainerHighest)
                    .frame(width: 64, height: 64)

                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.onSurfaceVariant)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("TypeOff User")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.onSurface)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }

            Spacer()
        }
        .tonalCard(color: Theme.surfaceContainerLowest)
        .sectionContainer()
    }

    private var statusText: String {
        if trialManager.isPurchased {
            return "TypeOff Unlimited"
        } else if trialManager.isTrialActive {
            let days = trialManager.trialDaysRemaining
            return "Trial · \(days) day\(days == 1 ? "" : "s") left"
        } else {
            return "Trial expired"
        }
    }

    private var statusColor: Color {
        if trialManager.isPurchased { return Theme.success }
        if trialManager.isTrialActive { return .orange }
        return Theme.error
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.headline("ACCOUNT")
                .padding(.leading, 4)

            VStack(spacing: 2) {
                if !trialManager.isPurchased {
                    Button {
                        Task { await storeManager.purchase() }
                    } label: {
                        HStack {
                            Image(systemName: "lock.open.fill")
                                .foregroundStyle(Theme.primary)
                                .frame(width: 32)

                            Text("Unlock TypeOff — $9.99")
                                .font(.body)
                                .foregroundStyle(Theme.onSurface)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.onSurfaceVariant)
                        }
                        .padding(16)
                    }
                }

                Button {
                    Task { await storeManager.restorePurchases() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Theme.primary)
                            .frame(width: 32)

                        Text("Restore Purchase")
                            .font(.body)
                            .foregroundStyle(Theme.onSurface)

                        Spacer()
                    }
                    .padding(16)
                }
            }
            .background(Theme.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .sectionContainer()
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.headline("APPEARANCE")
                .padding(.leading, 4)

            HStack(spacing: 0) {
                appearanceButton(label: "Light", icon: "sun.max.fill", value: "light")
                appearanceButton(label: "Dark", icon: "moon.fill", value: "dark")
                appearanceButton(label: "System", icon: "iphone", value: "system")
            }
            .background(Theme.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .sectionContainer()
    }

    private func appearanceButton(label: String, icon: String, value: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { appearance = value }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.body)
                Text(label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(appearance == value ? Theme.primary : Theme.onSurfaceVariant)
            .background(appearance == value ? Theme.primaryContainer.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(4)
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.headline("INFORMATION")
                .padding(.leading, 4)

            VStack(spacing: 2) {
                infoRow(icon: "info.circle", label: "About", trailing: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                infoRow(icon: "hand.raised", label: "Privacy")
            }
            .background(Theme.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .sectionContainer()
    }

    private func infoRow(icon: String, label: String, trailing: String? = nil) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Theme.primary)
                .frame(width: 32)

            Text(label)
                .font(.body)
                .foregroundStyle(Theme.onSurface)

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(Theme.onSurfaceVariant)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.onSurfaceVariant)
        }
        .padding(16)
    }
}

#Preview {
    ProfileView()
        .environmentObject(TrialManager())
        .environmentObject(StoreManager())
}
