import CodexBariOSShared
import SwiftUI

struct DashboardView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HeroPanel(model: self.model)
                        ProviderPanel(provider: .codex, model: self.model)
                        ProviderPanel(provider: .claude, model: self.model)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("CodexBar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await self.model.refreshAll()
                        }
                    } label: {
                        if self.model.isRefreshing {
                            ProgressView()
                        } else {
                            Text("Refresh")
                        }
                    }
                    .disabled(self.model.isRefreshing)
                }
            }
            .fullScreenCover(item: self.$model.claudeLoginSession) { session in
                ClaudeBrowserLoginExperience(
                    session: session,
                    onCancel: {
                        self.model.cancelClaudeBrowserLogin()
                    },
                    onComplete: { result in
                        Task {
                            await self.model.completeClaudeBrowserLogin(result)
                        }
                    })
            }
        }
    }
}

private struct HeroPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Token usage on your phone.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("Codex uses OAuth browser sign-in, Claude uses a captured `claude.ai` web session, and both feed the same widget snapshot store.")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                InfoChip(
                    title: "Snapshot",
                    value: self.model.snapshot.map { DisplayFormat.relativeDate($0.generatedAt) } ?? "none")
                InfoChip(
                    title: "Providers",
                    value: "\(self.model.snapshot?.entries.count ?? 0)/2")
                InfoChip(
                    title: "State",
                    value: self.model.isRefreshing ? "refreshing" : "ready")
                InfoChip(
                    title: "Widget",
                    value: self.model.widgetRefreshSummary)
            }

            if let status = self.model.statusMessage {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.92 : 0.82)))
            }

            if let detail = self.model.widgetRefreshDetail {
                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let diagnostics = self.model.widgetRefreshDiagnostics?.message {
                Text(diagnostics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(uiColor: .secondarySystemBackground),
                            Color(uiColor: .tertiarySystemBackground),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(self.colorScheme == .dark ? 0.08 : 0.4), lineWidth: 1)))
        .shadow(color: Color.black.opacity(self.colorScheme == .dark ? 0.24 : 0.06), radius: 18, y: 10)
    }
}

private struct ProviderPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: UsageProvider
    @Bindable var model: DashboardModel

    private var palette: ProviderPalette {
        .init(provider: self.provider)
    }

    private var entry: WidgetSnapshot.ProviderEntry? {
        self.model.entry(for: self.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.provider.displayName)
                        .font(.title3.weight(.bold))
                    if let hint = self.model.browserLoginHint(provider: self.provider) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if let label = self.model.storedCredentialLabel(provider: self.provider) {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(self.palette.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.94 : 0.86)))
                    }

                    Text(self.entry.map { DisplayFormat.relativeDate($0.updatedAt) } ?? "Not synced")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.92 : 0.8)))
                }
            }

            if let entry = self.entry {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    WindowTile(title: "Session", window: entry.primary, accent: self.palette.tint)
                    WindowTile(title: "Week", window: entry.secondary, accent: self.palette.tint)
                }

                if entry.tertiary != nil || entry.creditsRemaining != nil || entry.tokenUsage != nil {
                    ProviderSummaryCard(entry: entry, accent: self.palette.tint)
                }
            } else {
                EmptyProviderState(provider: self.provider)
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        await self.model.browserLogin(provider: self.provider)
                    }
                } label: {
                    if self.model.isAuthenticating(provider: self.provider) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Text("Browser Sign In")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(self.palette.tint)
                .disabled(!self.model.browserLoginSupported(provider: self.provider) || self.model.activeBrowserLoginProvider != nil)

                Button("Refresh") {
                    Task {
                        await self.model.refreshAll()
                    }
                }
                .buttonStyle(.bordered)
                .tint(self.palette.tint)
                .disabled(self.model.isRefreshing || self.model.activeBrowserLoginProvider != nil)
            }

            ManualFallbackForm(provider: self.provider, model: self.model, accent: self.palette.tint)

            if let error = self.model.error(for: self.provider) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(self.palette.background(for: self.colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(self.palette.stroke(for: self.colorScheme), lineWidth: 1)))
        .shadow(color: self.palette.tint.opacity(self.colorScheme == .dark ? 0.18 : 0.12), radius: 18, y: 10)
    }
}

private struct ManualFallbackForm: View {
    let provider: UsageProvider
    @Bindable var model: DashboardModel
    let accent: Color

    var body: some View {
        DisclosureGroup("Manual token fallback") {
            VStack(alignment: .leading, spacing: 12) {
                switch self.provider {
                case .codex:
                    SecureField("Access token", text: self.$model.codexAccessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    TextField("Account ID (optional)", text: self.$model.codexAccountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                case .claude:
                    SecureField("Access token", text: self.$model.claudeAccessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Button("Save") {
                        self.model.save(provider: self.provider)
                    }
                    .buttonStyle(.bordered)
                    .tint(self.accent)

                    Button("Clear") {
                        self.model.clear(provider: self.provider)
                    }
                    .buttonStyle(.bordered)
                    .tint(self.accent)

                    Button("Save & Refresh") {
                        self.model.save(provider: self.provider)
                        Task {
                            await self.model.refreshAll()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(self.accent)
                }
            }
            .padding(.top, 10)
        }
        .font(.footnote)
        .tint(self.accent)
    }
}

private struct EmptyProviderState: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: UsageProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No usage snapshot yet.")
                .font(.headline)
            Text("Sign in to \(self.provider.displayName) and refresh once to push a real snapshot into the widget container.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.96 : 0.76)))
    }
}

private struct ProviderSummaryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: WidgetSnapshot.ProviderEntry
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let secondary = self.entry.secondary {
                SummaryRow(title: "Weekly reset", value: DisplayFormat.resetLine(for: secondary) ?? "Unavailable")
            }
            if let tertiary = self.entry.tertiary {
                SummaryRow(title: "Extra window", value: self.describe(tertiary))
            }
            if let credits = self.entry.creditsRemaining {
                SummaryRow(title: "Credits", value: DisplayFormat.credits(credits))
            }
            if let tokenUsage = self.entry.tokenUsage {
                if let sessionCost = tokenUsage.sessionCostUSD {
                    SummaryRow(title: "Session cost", value: DisplayFormat.usd(sessionCost))
                }
                if let sessionTokens = tokenUsage.sessionTokens {
                    SummaryRow(title: "Session tokens", value: DisplayFormat.tokenCount(sessionTokens))
                }
                if let last30DaysCost = tokenUsage.last30DaysCostUSD {
                    SummaryRow(title: "30-day cost", value: DisplayFormat.usd(last30DaysCost))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.98 : 0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(self.accent.opacity(self.colorScheme == .dark ? 0.22 : 0.15), lineWidth: 1)))
    }

    private func describe(_ window: RateWindow) -> String {
        let percent = DisplayFormat.percentRemaining(window.remainingPercent)
        if let reset = DisplayFormat.resetLine(for: window) {
            return "\(percent) · \(reset)"
        }
        return percent
    }
}

private struct WindowTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let window: RateWindow?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let window = self.window {
                Text(DisplayFormat.percentRemaining(window.remainingPercent))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                if let reset = DisplayFormat.resetLine(for: window) {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reset unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { proxy in
                    let availableWidth = max(0, proxy.size.width - 10)
                    let remainingWidth = availableWidth * CGFloat(window.remainingPercent / 100)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(self.accent)
                            .frame(width: max(10, remainingWidth))
                    }
                }
                .frame(height: 10)
            } else {
                Text("No data")
                    .font(.headline)
                Text("Refresh after sign-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.98 : 0.84)))
    }
}

private struct InfoChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground).opacity(self.colorScheme == .dark ? 0.96 : 0.82)))
    }
}

private struct SummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(self.title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(self.value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
        .font(.footnote)
    }
}

private struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: self.colorScheme == .dark ? .systemGroupedBackground : .systemBackground),
                Color(uiColor: self.colorScheme == .dark ? .secondarySystemGroupedBackground : .secondarySystemBackground),
                Color(uiColor: self.colorScheme == .dark ? .systemGroupedBackground : .systemGroupedBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(self.colorScheme == .dark ? 0.08 : 0.32))
                .frame(width: 220, height: 220)
                .blur(radius: 20)
                .offset(x: 80, y: -40)
        }
        .ignoresSafeArea()
    }
}

private struct ProviderPalette {
    let tint: Color

    init(provider: UsageProvider) {
        switch provider {
        case .codex:
            self.tint = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude:
            self.tint = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        }
    }

    func background(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground),
                self.tint.opacity(colorScheme == .dark ? 0.18 : 0.1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    func stroke(for colorScheme: ColorScheme) -> Color {
        self.tint.opacity(colorScheme == .dark ? 0.26 : 0.14)
    }
}
