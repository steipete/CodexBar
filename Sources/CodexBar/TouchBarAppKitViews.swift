import AppKit
import CodexBarCore

/// AppKit replacements for the Touch Bar row content that used to be SwiftUI
/// (`CodexBarTouchBarView`/`TouchBarUsageGraphView`, retired below).
///
/// `NSHostingView` doesn't receive touch input when its `NSTouchBarItem` is presented via the
/// undocumented `presentSystemModalTouchBar:` path (`SystemModalTouchBarRuntime`) — confirmed
/// against the OSS precedent this app reverse-engineered that API from (Toxblh/MTMR's
/// `CustomButtonTouchBarItem` wires a real `NSButton` directly as `item.view`) and against a
/// sibling app using the same private API (binlabongbom/codex-status-touch-bar's
/// `RateMetricView`, an `NSStackView` with `NSClickGestureRecognizer`, not SwiftUI). Neither
/// `.onTapGesture` nor a SwiftUI `Button` (both tried first) fixed it — both still route through
/// `NSHostingView`'s own hit-testing, which the private modal path never forwards into. These
/// views are plain `NSView`/`NSControl` content instead, matching both precedents.

// MARK: - Progress capsule

@MainActor
final class TouchBarProgressCapsuleView: NSView {
    var fraction: Double = 0 { didSet { self.needsDisplay = true } }
    var fillColor: NSColor = .systemGreen { didSet { self.needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(self.bounds.width, self.bounds.height) / 2
        let backgroundPath = NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius)
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
        backgroundPath.fill()

        let fillWidth = self.bounds.width * CGFloat(max(0, min(1, self.fraction)))
        guard fillWidth > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        backgroundPath.addClip()
        self.fillColor.setFill()
        NSRect(x: 0, y: 0, width: fillWidth, height: self.bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Logo

@MainActor
final class TouchBarLogoView: NSView {
    private let imageView = NSImageView()
    private let letterLabel = NSTextField(labelWithString: "")
    private var accent: NSColor = .labelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.imageView.imageScaling = .scaleProportionallyUpOrDown
        self.imageView.contentTintColor = .white
        self.letterLabel.font = .systemFont(ofSize: 10, weight: .bold)
        self.letterLabel.textColor = .white
        self.letterLabel.alignment = .center
        self.addSubview(self.imageView)
        self.addSubview(self.letterLabel)
        self.imageView.translatesAutoresizingMaskIntoConstraints = false
        self.letterLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: 20),
            self.heightAnchor.constraint(equalToConstant: 20),
            self.imageView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.imageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.imageView.widthAnchor.constraint(equalToConstant: 11),
            self.imageView.heightAnchor.constraint(equalToConstant: 11),
            self.letterLabel.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.letterLabel.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        self.accent.setFill()
        NSBezierPath(ovalIn: self.bounds).fill()
    }

    func apply(descriptor: ProviderDescriptor) {
        let color = descriptor.branding.color
        self.accent = NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        if let logo = ProviderBrandIcon.image(for: descriptor.id) {
            self.imageView.image = logo
            self.imageView.isHidden = false
            self.letterLabel.isHidden = true
        } else {
            self.imageView.isHidden = true
            self.letterLabel.isHidden = false
            self.letterLabel.stringValue = String(descriptor.metadata.displayName.prefix(1))
        }
        self.needsDisplay = true
    }
}

// MARK: - Rate row (one 5h/wk line inside a card)

@MainActor
final class TouchBarRateRowView: NSView {
    let nameLabel = NSTextField(labelWithString: "")
    let capsule = TouchBarProgressCapsuleView()
    let percentLabel = NSTextField(labelWithString: "")
    let resetLabel = NSTextField(labelWithString: "")

    init(label: String) {
        super.init(frame: .zero)
        self.nameLabel.stringValue = label
        self.nameLabel.font = .systemFont(ofSize: 8.5, weight: .bold)
        self.nameLabel.textColor = .secondaryLabelColor
        self.percentLabel.font = .systemFont(ofSize: 9.5, weight: .bold)
        self.resetLabel.font = .systemFont(ofSize: 8.5)
        self.resetLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [self.nameLabel, self.capsule, self.percentLabel, self.resetLabel])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        self.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.nameLabel.widthAnchor.constraint(equalToConstant: 14).isActive = true
        self.capsule.widthAnchor.constraint(equalToConstant: 50).isActive = true
        self.capsule.heightAnchor.constraint(equalToConstant: 5).isActive = true
        self.percentLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(label: String, window: RateWindow?, accent: NSColor) {
        self.nameLabel.stringValue = label
        let remaining = 100 - (window?.usedPercent ?? 100)
        let isCritical = remaining < 10
        self.nameLabel.textColor = isCritical ? .systemRed : .secondaryLabelColor
        self.capsule.fraction = max(0, min(1, remaining / 100))
        self.capsule.fillColor = isCritical ? .systemRed : accent
        self.percentLabel.stringValue = UsageFormatter.percentString(remaining)
        self.percentLabel.textColor = isCritical ? .systemRed : .labelColor
        if let resetsAt = window?.resetsAt {
            self.resetLabel.stringValue = "Reset at \(UsageFormatter.resetDescription(from: resetsAt))"
            self.resetLabel.isHidden = false
        } else {
            self.resetLabel.isHidden = true
        }
    }
}

// MARK: - Card (overview row — one per provider)

@MainActor
final class TouchBarProviderCardView: NSView {
    let provider: UsageProvider
    var onTap: (() -> Void)?

    private let logoView = TouchBarLogoView(frame: .zero)
    let primaryRow = TouchBarRateRowView(label: "5h")
    let secondaryRow = TouchBarRateRowView(label: "wk")

    init(provider: UsageProvider) {
        self.provider = provider
        super.init(frame: .zero)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)

        let rows = NSStackView(views: [self.primaryRow, self.secondaryRow])
        rows.orientation = .vertical
        rows.spacing = 1
        rows.alignment = .leading

        let content = NSStackView(views: [self.logoView, rows])
        content.orientation = .horizontal
        content.spacing = 7
        content.alignment = .centerY
        self.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.heightAnchor.constraint(equalToConstant: 26),
        ])
        // NSStackView's `.fill` distribution stretches arranged subviews to consume any
        // slack in a wider-than-content container (the touch bar item is a fixed 400pt
        // frame) — SwiftUI's HStack never did this, it just left the trailing space blank.
        // Pin hugging high so cards/rows stay packed left instead of spreading apart.
        self.setContentHuggingPriority(.required, for: .horizontal)
        // Touch Bar delivers NSTouch as .direct — NSGestureRecognizer's default
        // allowedTouchTypes only covers mouse/indirect, so it never fires here without
        // this. MTMR (the precedent this app's private-API path was reverse-engineered
        // from) sets this explicitly on every recognizer it attaches to a Touch Bar item.
        let click = NSClickGestureRecognizer(target: self, action: #selector(self.handleTap))
        click.allowedTouchTypes = .direct
        self.allowedTouchTypes = .direct
        self.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() { self.onTap?() }

    override func accessibilityPerformPress() -> Bool {
        guard let onTap else { return false }
        onTap()
        return true
    }

    func apply(descriptor: ProviderDescriptor, snapshot: UsageSnapshot?) {
        self.logoView.apply(descriptor: descriptor)
        let color = descriptor.branding.color
        let accent = NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        self.primaryRow.apply(
            label: compactWindowLabel(windowMinutes: snapshot?.primary?.windowMinutes, fallback: descriptor.metadata.sessionLabel),
            window: snapshot?.primary,
            accent: accent)
        self.secondaryRow.apply(
            label: compactWindowLabel(windowMinutes: snapshot?.secondary?.windowMinutes, fallback: descriptor.metadata.weeklyLabel),
            window: snapshot?.secondary,
            accent: accent)
        self.setAccessibilityLabel(descriptor.metadata.displayName)
    }
}

// MARK: - Graph (expanded row — shown after tapping a card)

@MainActor
final class TouchBarProviderGraphView: NSView {
    let provider: UsageProvider
    var onTap: (() -> Void)?

    private let logoView = TouchBarLogoView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    let resetLabel = NSTextField(labelWithString: "")
    let capsule = TouchBarProgressCapsuleView()
    private let percentLabel = NSTextField(labelWithString: "")

    init(provider: UsageProvider) {
        self.provider = provider
        super.init(frame: .zero)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)

        self.nameLabel.font = .systemFont(ofSize: 9, weight: .bold)
        self.resetLabel.font = .systemFont(ofSize: 8)
        self.resetLabel.textColor = .secondaryLabelColor
        self.percentLabel.font = .systemFont(ofSize: 11, weight: .bold)
        self.percentLabel.alignment = .right

        let labels = NSStackView(views: [self.nameLabel, self.resetLabel])
        labels.orientation = .vertical
        labels.spacing = 1
        labels.alignment = .leading

        let content = NSStackView(views: [self.logoView, labels, self.capsule, self.percentLabel])
        content.orientation = .horizontal
        content.spacing = 8
        content.alignment = .centerY
        self.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        self.capsule.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.capsule.heightAnchor.constraint(equalToConstant: 5).isActive = true
        self.percentLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.heightAnchor.constraint(equalToConstant: 26),
        ])
        // NSStackView's `.fill` distribution stretches arranged subviews to consume any
        // slack in a wider-than-content container (the touch bar item is a fixed 400pt
        // frame) — SwiftUI's HStack never did this, it just left the trailing space blank.
        // Pin hugging high so cards/rows stay packed left instead of spreading apart.
        self.setContentHuggingPriority(.required, for: .horizontal)
        // Touch Bar delivers NSTouch as .direct — NSGestureRecognizer's default
        // allowedTouchTypes only covers mouse/indirect, so it never fires here without
        // this. MTMR (the precedent this app's private-API path was reverse-engineered
        // from) sets this explicitly on every recognizer it attaches to a Touch Bar item.
        let click = NSClickGestureRecognizer(target: self, action: #selector(self.handleTap))
        click.allowedTouchTypes = .direct
        self.allowedTouchTypes = .direct
        self.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() { self.onTap?() }

    override func accessibilityPerformPress() -> Bool {
        guard let onTap else { return false }
        onTap()
        return true
    }

    func apply(descriptor: ProviderDescriptor, snapshot: UsageSnapshot?, window kind: TouchBarWindowKind) {
        self.logoView.apply(descriptor: descriptor)
        let color = descriptor.branding.color
        let accent = NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        self.nameLabel.stringValue = descriptor.metadata.displayName
        let window = kind.window(in: snapshot)
        let label = kind.label(descriptor: descriptor, window: window)
        if let resetsAt = window?.resetsAt {
            self.resetLabel.stringValue = "\(label) · Reset at \(UsageFormatter.resetDescription(from: resetsAt))"
        } else {
            self.resetLabel.stringValue = label
        }
        let remaining = 100 - (window?.usedPercent ?? 100)
        let isCritical = remaining < 10
        self.capsule.fraction = max(0, min(1, remaining / 100))
        self.capsule.fillColor = isCritical ? .systemRed : accent
        self.percentLabel.stringValue = UsageFormatter.percentString(remaining)
        self.percentLabel.textColor = isCritical ? .systemRed : .labelColor
        self.setAccessibilityLabel("\(descriptor.metadata.displayName) \(label), \(UsageFormatter.percentString(remaining)) remaining")
    }
}

/// Compact window label derived from the window's actual length, not an assumption about
/// which provider it belongs to — Codex/Claude's primary window is a real 5h rolling window,
/// but Kiro's primary window is a monthly credit grant (`windowMinutes: nil`) labeled
/// "Credits"/"Bonus" in its own `ProviderMetadata`. Falls back to that per-provider label
/// when the window length doesn't match a known compact form.
func compactWindowLabel(windowMinutes: Int?, fallback: String) -> String {
    switch windowMinutes {
    case 300: "5h"
    case 10080: "wk"
    case 43200: "mo"
    default: fallback
    }
}

/// Which usage window the expanded graph row is currently showing — tapping cycles
/// primary -> secondary -> back to the overview cards.
enum TouchBarWindowKind {
    case primary
    case secondary

    func label(descriptor: ProviderDescriptor, window: RateWindow?) -> String {
        let fallback = switch self {
        case .primary: descriptor.metadata.sessionLabel
        case .secondary: descriptor.metadata.weeklyLabel
        }
        return compactWindowLabel(windowMinutes: window?.windowMinutes, fallback: fallback)
    }

    func window(in snapshot: UsageSnapshot?) -> RateWindow? {
        switch self {
        case .primary: snapshot?.primary
        case .secondary: snapshot?.secondary
        }
    }
}

