import AppKit
import CodexBarCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
private final class CodeReviewLogsPanelModel {
    var entries: [OpenAICodeReviewLogEntry] = []
}

@MainActor
final class CodeReviewLogsPanelWindowController: NSWindowController {
    private static let defaultSize = NSSize(width: 760, height: 520)
    private let model = CodeReviewLogsPanelModel()
    private var hasCenteredWindow = false

    init() {
        let rootView = CodeReviewLogsPanelView(model: self.model, onOpenURL: Self.openLogURL)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Code Review Logs"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 620, height: 360)
        window.setContentSize(Self.defaultSize)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(entries: [OpenAICodeReviewLogEntry]) {
        self.model.entries = entries
        guard let window = self.window else { return }
        if !self.hasCenteredWindow {
            window.center()
            self.hasCenteredWindow = true
        }
        self.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private nonisolated static func openLogURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    nonisolated static func sanitizedLogURL(_ rawURL: String?) -> URL? {
        guard let rawURL else { return nil }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absoluteURL = URL(string: trimmed), self.isAllowedCodeReviewLogURL(absoluteURL) {
            return absoluteURL
        }
        guard let baseURL = URL(string: "https://chatgpt.com"),
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              self.isAllowedCodeReviewLogURL(resolved) else { return nil }
        return resolved
    }

    private nonisolated static func isAllowedCodeReviewLogURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }

        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if normalizedHost == "chatgpt.com" || normalizedHost.hasSuffix(".chatgpt.com") {
            return true
        }

        guard normalizedHost == "github.com" else { return false }

        let path = url.path.lowercased()
        return path.contains("/pull/")
            || path.contains("/review/")
            || path.contains("/commit/")
            || path.contains("/compare/")
    }
}

private struct CodeReviewLogsPanelView: View {
    @Bindable var model: CodeReviewLogsPanelModel
    let onOpenURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Code Reviews")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(self.model.entries.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if self.displayedEntries.isEmpty {
                Text("No code review logs found yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(self.displayedEntries) { entry in
                            CodeReviewLogRowView(entry: entry, onOpenURL: self.onOpenURL)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 400, alignment: .topLeading)
    }

    private var displayedEntries: [OpenAICodeReviewLogEntry] {
        Array(self.model.entries.prefix(200))
    }
}

private struct CodeReviewLogRowView: View {
    let entry: OpenAICodeReviewLogEntry
    let onOpenURL: (URL) -> Void

    var body: some View {
        let dateText = self.sanitizedText(self.entry.dateText)
        let stateText = self.normalizedStateText(self.entry.stateText)
        let actionText = self.sanitizedText(self.entry.actionText)
        let openURL = CodeReviewLogsPanelWindowController.sanitizedLogURL(self.entry.url)
        VStack(alignment: .leading, spacing: 6) {
            Text(self.entry.title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle = self.entry.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if let dateText {
                    self.pill(text: dateText, style: .neutral)
                }
                if let bugCount = self.entry.bugCount {
                    let label = bugCount == 1 ? "1 bug" : "\(bugCount) bugs"
                    self.pill(text: label, style: .warning)
                }
                if let stateText {
                    self.pill(text: stateText, style: self.stateStyle(for: stateText))
                }
                if let openURL {
                    Button(action: { self.onOpenURL(openURL) }, label: {
                        self.pill(text: actionText ?? "Open", style: .action)
                    })
                    .buttonStyle(.plain)
                } else if let actionText {
                    self.pill(text: actionText, style: .neutral)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum PillStyle {
        case neutral
        case warning
        case success
        case error
        case action
    }

    private func stateStyle(for state: String) -> PillStyle {
        switch state.lowercased() {
        case "merged":
            .success
        case "closed":
            .error
        default:
            .neutral
        }
    }

    @ViewBuilder
    private func pill(text: String, style: PillStyle) -> some View {
        let colors = self.colors(for: style)
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(colors.foreground)
            .background(
                Capsule(style: .continuous)
                    .fill(colors.background))
    }

    private func colors(for style: PillStyle) -> (foreground: Color, background: Color) {
        switch style {
        case .neutral:
            (Color.secondary, Color(nsColor: .quaternaryLabelColor).opacity(0.25))
        case .warning:
            (Color(nsColor: .systemOrange), Color(nsColor: .systemOrange).opacity(0.16))
        case .success:
            (Color(nsColor: .systemGreen), Color(nsColor: .systemGreen).opacity(0.16))
        case .error:
            (Color(nsColor: .systemRed), Color(nsColor: .systemRed).opacity(0.16))
        case .action:
            (Color.primary, Color(nsColor: .controlAccentColor).opacity(0.18))
        }
    }

    private func sanitizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedStateText(_ value: String?) -> String? {
        guard let state = self.sanitizedText(value) else { return nil }
        if state.localizedCaseInsensitiveCompare("open") == .orderedSame {
            return nil
        }
        return state
    }
}
