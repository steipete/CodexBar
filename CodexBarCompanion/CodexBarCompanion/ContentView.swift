import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @State private var models: [CompanionCardModel] = []
    @State private var selectedProviderID: String? = "overview"
    @State private var lastSynced: Date? = nil
    @AppStorage("pollingMinutes") private var pollingMinutes: Double = 5
    @State private var isEditingInterval = false

    @State private var timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Main Dark Background
            Color(red: 0.08, green: 0.08, blue: 0.09)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                // Custom Top Header
                HStack {
                    Text("CodexBar")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Spacer()

                    Button(action: { withAnimation(.spring) { isEditingInterval.toggle() } }) {
                        Image(systemName: "clock")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(6)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                // Let the safe area naturally pad the top, no hardcoded top padding needed.
                .padding(.top, 4)
                .padding(.bottom, 8)

                if isEditingInterval {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Atualizar a cada")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(Int(pollingMinutes)) min")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                        }
                        Slider(value: $pollingMinutes, in: 1 ... 10, step: 1)
                            .tint(.accentColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(10)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Divider().background(Color.white.opacity(0.1))

                if models.isEmpty {
                    Spacer()
                    VStack(spacing: 20) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.4))
                        Text("Aguardando dados")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Abra o CodexBar no seu Mac com a mesma conta iCloud para sincronizar o uso.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                } else {
                    // Content Area
                    TabView(selection: $selectedProviderID) {
                        // Overview Tab
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 12) {
                                ForEach(models) { model in
                                    MiniOverviewCard(model: model)
                                        .onTapGesture {
                                            withAnimation { selectedProviderID = model.id }
                                        }
                                }
                            }
                            .padding(.top, 16)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 120) // space for bottom tab bar
                        }
                        .tag("overview" as String?)

                        // Individual Provider Tabs
                        ForEach(models) { model in
                            ScrollView(showsIndicators: false) {
                                CompanionCardView(model: model, width: UIScreen.main.bounds.width - 32)
                                    .padding(.top, 16)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 120) // space for bottom tab bar
                            }
                            .tag(model.id as String?)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }

            // Custom Bottom Tab Bar
            if !models.isEmpty {
                VStack(spacing: 0) {
                    Divider().background(Color.white.opacity(0.1))

                    HStack(alignment: .bottom, spacing: 0) {
                        // Overview Button
                        TabButton(
                            id: "overview",
                            title: "Visão geral",
                            icon: "square.grid.2x2",
                            color: .white,
                            isSelected: selectedProviderID == "overview",
                            metrics: [],
                            action: { withAnimation(.easeInOut(duration: 0.2)) { selectedProviderID = "overview" } }
                        )

                        // Provider Buttons
                        ForEach(models) { model in
                            TabButton(
                                id: model.id,
                                title: model.providerName,
                                icon: iconName(for: model.providerName),
                                color: model.progressColor,
                                isSelected: selectedProviderID == model.id,
                                metrics: model.metrics,
                                action: { withAnimation(.easeInOut(duration: 0.2)) { selectedProviderID = model.id } }
                            )
                        }
                    }
                    .padding(.top, 6)
                    // Use iOS safe area properly for the bottom instead of hardcoding padding
                }
                .background(
                    Color(white: 0.1)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(timer) { _ in
            fetchUsage()
        }
        .onChange(of: pollingMinutes) { _, newValue in
            restartTimer(minutes: newValue)
        }
        .onAppear {
            setupKVSObservation()
            restartTimer(minutes: pollingMinutes)
            fetchUsage()
        }
    }

    private func iconName(for provider: String) -> String {
        let name = provider.lowercased()
        if name.contains("codex") { return "terminal" } // Fixed Codex Icon
        if name.contains("claude") { return "asterisk" }
        if name.contains("gemini") { return "sparkles" }
        if name.contains("antigravity") { return "triangle" }
        return "circle.grid.cross"
    }

    private func restartTimer(minutes: Double) {
        timer.upstream.connect().cancel()
        timer = Timer.publish(every: max(60, minutes * 60), on: .main, in: .common).autoconnect()
    }

    private func fetchUsage() {
        // Source of truth is iCloud Key-Value Store, synced from the macOS app.
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        guard let data = store.data(forKey: "latestUsageSync"),
              let decoded = try? JSONDecoder().decode([CompanionCardModel].self, from: data)
        else { return }
        self.models = decoded.filter { !$0.metrics.isEmpty }
        self.lastSynced = Date()
        if selectedProviderID == nil {
            selectedProviderID = "overview"
        }
    }

    private func setupKVSObservation() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            Task { @MainActor in fetchUsage() }
        }
        // Pull the latest cloud value down to this device.
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

// Custom Tab Button with Progress Bars
struct TabButton: View {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let metrics: [CompanionCardModel.Metric]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                // Dual Progress Bars
                VStack(spacing: 2) {
                    if metrics.count >= 1 {
                        progressBar(percent: metrics[0].percent, color: color)
                    } else {
                        progressBar(percent: isSelected ? 100 : 0, color: color)
                    }

                    if metrics.count >= 2 {
                        progressBar(percent: metrics[1].percent, color: color)
                    } else if isSelected && id != "overview" {
                        // Invisible placeholder to keep height consistent
                        Rectangle().fill(Color.clear).frame(height: 2)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 10)

                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? color : .gray)
                    .frame(height: 24)

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : .gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func progressBar(percent: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .cornerRadius(1)

                Rectangle()
                    .fill(isSelected ? color : color.opacity(0.5))
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, percent))) / 100.0)
                    .cornerRadius(1)
            }
        }
        .frame(height: 2)
    }
}

// Mini Widget for the Overview Tab
struct MiniOverviewCard: View {
    let model: CompanionCardModel

    var body: some View {
        HStack(spacing: 16) {
            // Left: Icon & Name
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: model.providerName))
                        .foregroundColor(model.progressColor)
                    Text(model.providerName)
                        .font(.headline)
                        .foregroundColor(.white)
                }

                if let resetText = model.metrics.first?.resetText {
                    Text(resetText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 100, alignment: .leading)

            // Right: Metrics (5h, 7d, etc)
            VStack(spacing: 8) {
                ForEach(model.metrics) { metric in
                    VStack(spacing: 2) {
                        HStack {
                            Text(metric.title)
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                            Spacer()
                            Text(metric.percentLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(model.progressColor)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                Rectangle()
                                    .fill(model.progressColor)
                                    .frame(width: geo.size.width * CGFloat(max(0, min(100, metric.percent))) / 100.0)
                            }
                            .cornerRadius(1.5)
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.12))
        .cornerRadius(12)
    }

    private func iconName(for provider: String) -> String {
        let name = provider.lowercased()
        if name.contains("codex") { return "terminal" }
        if name.contains("claude") { return "asterisk" }
        if name.contains("gemini") { return "sparkles" }
        if name.contains("antigravity") { return "triangle" }
        return "circle.grid.cross"
    }
}

#Preview {
    ContentView()
}
