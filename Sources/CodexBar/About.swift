import AppKit

@MainActor
func showAbout() {
    NSApp.activate(ignoringOtherApps: true)

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let versionString = build.isEmpty ? version : "\(version) (\(build))"
    let buildTimestamp = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String
    let gitCommit = Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String

    let separator = NSAttributedString(string: " · ", attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
    ])

    func makeLink(_ title: String, urlString: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .link: URL(string: urlString) as Any,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
    }

    let credits = NSMutableAttributedString(string: "Peter Steinberger — MIT License\n")
    credits.append(makeLink("GitHub", urlString: "https://github.com/steipete/CodexBar"))
    credits.append(separator)
    credits.append(makeLink("Website", urlString: "https://codexbar.app"))
    credits.append(separator)
    credits.append(makeLink("Twitter", urlString: "https://twitter.com/steipete"))
    credits.append(separator)
    credits.append(makeLink("Email", urlString: "mailto:peter@steipete.me"))
    if let buildTimestamp, let formatted = formattedBuildTimestamp(buildTimestamp) {
        var builtLine = "Built \(formatted)"
        if let gitCommit, !gitCommit.isEmpty, gitCommit != "unknown" {
            builtLine += " (\(gitCommit)"
            #if DEBUG
            builtLine += " DEBUG BUILD"
            #endif
            builtLine += ")"
        }
        credits.append(NSAttributedString(string: "\n\(builtLine)", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }

    let options: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: "CodexBar",
        .applicationVersion: versionString,
        .version: versionString,
        .credits: credits,
        .applicationIcon: (NSApplication.shared.applicationIconImage ?? NSImage()) as Any,
    ]

    NSApp.orderFrontStandardAboutPanel(options: options)

    // Remove the focus ring around the app icon in the standard About panel for a cleaner look.
    if let aboutPanel = NSApp.windows.first(where: { $0.className.contains("About") }) {
        removeFocusRings(in: aboutPanel.contentView)
    }
}

private func formattedBuildTimestamp(_ timestamp: String) -> String? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    guard let date = parser.date(from: timestamp) else { return timestamp }

    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.locale = .current
    return formatter.string(from: date)
}

@MainActor
private func removeFocusRings(in view: NSView?) {
    guard let view else { return }
    if let imageView = view as? NSImageView {
        imageView.focusRingType = .none
    }
    for subview in view.subviews {
        removeFocusRings(in: subview)
    }
}
