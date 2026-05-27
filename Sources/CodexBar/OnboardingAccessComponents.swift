import CodexBarCore
import SwiftUI

struct OnboardingAccessLogItem: Identifiable {
    enum Result {
        case found
        case checked
        case ready

        var title: String {
            switch self {
            case .found:
                L("onboarding_provider_detected")
            case .checked:
                "Checked"
            case .ready:
                "Ready"
            }
        }

        var color: Color {
            switch self {
            case .found:
                OnboardingPalette.success
            case .checked:
                OnboardingPalette.brandBlue
            case .ready:
                OnboardingPalette.accent
            }
        }
    }

    let id: String
    let systemImage: String
    let command: String
    let detail: String
    let result: Result
}

struct OnboardingAccessLogList: View {
    static let items: [OnboardingAccessLogItem] = [
        .init(
            id: "config",
            systemImage: "doc.text",
            command: "reading CodexBar config",
            detail: "config.json and saved provider settings",
            result: .found),
        .init(
            id: "clis",
            systemImage: "terminal",
            command: "checking installed CLIs",
            detail: "Codex, Claude, Gemini, and local PATH",
            result: .found),
        .init(
            id: "apps",
            systemImage: "macwindow",
            command: "checking local app sessions",
            detail: "running apps and app-specific auth",
            result: .found),
        .init(
            id: "credentials",
            systemImage: "key.fill",
            command: "checking saved account credentials",
            detail: "token accounts, API keys, and cookie headers",
            result: .found),
        .init(
            id: "browsers",
            systemImage: "globe",
            command: "checking browser session availability",
            detail: "only profiles that can be read safely",
            result: .checked),
        .init(
            id: "providers",
            systemImage: "square.grid.2x2",
            command: "preparing provider list",
            detail: "detected access becomes selectable next",
            result: .ready),
    ]

    static var itemCount: Int {
        items.count
    }

    let visibleCount: Int

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                ForEach(Array(Self.items.prefix(self.visibleCount).enumerated()), id: \.element.id) { index, item in
                    OnboardingAccessLogRow(
                        item: item,
                        isProcessing: index == self.visibleCount - 1 && self.visibleCount <= Self.items.count)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.thinMaterial)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.24))
            LinearGradient(
                colors: [.white.opacity(0.06), .clear, .white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                let progress = phase.truncatingRemainder(dividingBy: 3.2) / 3.2
                LinearGradient(
                    colors: [.clear, OnboardingPalette.brandBlue.opacity(0.12), .clear],
                    startPoint: .top,
                    endPoint: .bottom)
                    .frame(height: 88)
                    .offset(y: -205 + (410 * progress))
                    .blur(radius: 10)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.62), location: 0.12),
                    .init(color: .white, location: 0.28),
                    .init(color: .white, location: 0.76),
                    .init(color: .white.opacity(0.58), location: 0.9),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .shadow(color: .black.opacity(0.34), radius: 30, y: 22)
        .animation(.snappy(duration: 0.32), value: self.visibleCount)
    }
}

struct OnboardingTerminalScanPanel: View {
    let visibleCount: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.red.opacity(0.72))
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(Color.yellow.opacity(0.68))
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(OnboardingPalette.success.opacity(0.72))
                    .frame(width: 8, height: 8)

                Text("local-access")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .padding(.leading, 8)

                Spacer()

                Text(
                    "\(min(self.visibleCount, OnboardingAccessLogList.itemCount))/\(OnboardingAccessLogList.itemCount)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OnboardingPalette.brandBlue)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("$ codexbar scan --local")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.bottom, 4)

                ForEach(
                    Array(OnboardingAccessLogList.items.prefix(self.visibleCount).enumerated()),
                    id: \.element.id)
                { index, item in
                    OnboardingTerminalScanRow(
                        item: item,
                        isActive: index == self.visibleCount - 1 && self.visibleCount <= OnboardingAccessLogList
                            .itemCount)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.64))
            LinearGradient(
                colors: [
                    OnboardingPalette.brandBlue.opacity(0.12),
                    Color.clear,
                    OnboardingPalette.purple.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 28, y: 20)
        .animation(.easeOut(duration: 0.55), value: self.visibleCount)
    }
}

private struct OnboardingTerminalScanRow: View {
    let item: OnboardingAccessLogItem
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text(">")
                .foregroundStyle(self.isActive ? OnboardingPalette.brandBlue : Color.white.opacity(0.28))
            Image(systemName: self.item.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(self.isActive ? OnboardingPalette.brandBlue : Color.white.opacity(0.46))
                .frame(width: 16)
            Text("\(self.item.command)...")
                .foregroundStyle(.white.opacity(self.isActive ? 0.92 : 0.72))
            Spacer(minLength: 12)
            OnboardingTerminalStatusMark(isActive: self.isActive)
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.isActive ? OnboardingPalette.brandBlue.opacity(0.12) : Color.white.opacity(0.028))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    self.isActive ? OnboardingPalette.brandBlue.opacity(0.24) : Color.white.opacity(0.06),
                    lineWidth: 1)
        }
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }
}

private struct OnboardingTerminalStatusMark: View {
    let isActive: Bool

    var body: some View {
        Group {
            if self.isActive {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.05) / 1.05
                    Image(systemName: "arrow.trianglehead.clockwise")
                        .rotationEffect(.degrees(phase * 360))
                }
            } else {
                Image(systemName: "checkmark")
            }
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(self.isActive ? OnboardingPalette.brandBlue : OnboardingPalette.success)
        .frame(width: 18)
    }
}

struct OnboardingAccessCopyPanel: View {
    let visibleCount: Int

    private var progress: Double {
        guard OnboardingAccessLogList.itemCount > 0 else { return 0 }
        return Double(min(self.visibleCount, OnboardingAccessLogList.itemCount)) /
            Double(OnboardingAccessLogList.itemCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("onboarding_step_detecting"))
                .font(.caption.weight(.bold))
                .foregroundStyle(OnboardingPalette.brandBlue)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(OnboardingPalette.brandBlue.opacity(0.14))
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 10) {
                Text(L("onboarding_access_title"))
                    .font(.system(size: 32, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("onboarding_access_subtitle"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(OnboardingPalette.brandBlue)
                                .frame(width: self.progress >= 1 ? proxy.size.width :
                                    max(14, proxy.size.width * CGFloat(self.progress)))
                        }
                }
                .frame(height: 6)
                .clipShape(Capsule())

                Text("\(Int(self.progress * 100))% complete")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.56))
            }
            .padding(.top, 4)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                OnboardingAccessCopyLine(icon: "lock", text: L("onboarding_access_private"))
                OnboardingAccessCopyLine(icon: "terminal", text: L("onboarding_access_sources_first"))
                OnboardingAccessCopyLine(icon: "checkmark.circle", text: L("onboarding_access_confirm_next"))
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OnboardingAccessCopyLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: self.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnboardingPalette.brandBlue.opacity(0.82))
                .frame(width: 16)
            Text(self.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

private struct OnboardingAccessLogRow: View {
    let item: OnboardingAccessLogItem
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: self.item.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OnboardingPalette.brandBlue)
                .frame(width: 38, height: 38)
                .background(OnboardingPalette.brandBlue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.item.command)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(self.item.detail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 14)

            if self.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(OnboardingPalette.brandBlue)
            } else {
                Text(self.item.result.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(self.item.result.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(self.item.result.color.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(self.isProcessing ? 0.086 : 0.046))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(self.stroke, lineWidth: 1)
        }
    }

    private var stroke: Color {
        self.isProcessing ? OnboardingPalette.brandBlue.opacity(0.36) : Color.white.opacity(0.08)
    }
}

struct OnboardingDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 74)
    }
}
