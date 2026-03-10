import AppKit
import CodexBarCore

enum ProviderSwitcherSelection: Equatable {
    case overview
    case provider(UsageProvider)
}

final class ProviderSwitcherView: NSView {
    private struct Segment {
        let selection: ProviderSwitcherSelection
        let image: NSImage
        let title: String
    }

    private struct WeeklyIndicator {
        let track: NSView
        let fill: NSView
    }

    private let segments: [Segment]
    private let onSelect: (ProviderSwitcherSelection) -> Void
    private let showsIcons: Bool
    private let weeklyRemainingProvider: (UsageProvider) -> Double?
    private var buttons: [NSButton] = []
    private var weeklyIndicators: [ObjectIdentifier: WeeklyIndicator] = [:]
    private var hoverTrackingArea: NSTrackingArea?
    private var segmentWidths: [CGFloat] = []
    private let selectedBackground = NSColor.controlAccentColor.cgColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let selectedTextColor = NSColor.white
    private let unselectedTextColor = NSColor.secondaryLabelColor
    private let stackedIcons: Bool
    private let rowCount: Int
    private let rowSpacing: CGFloat
    private let rowHeight: CGFloat
    private var preferredWidth: CGFloat = 0
    private var hoveredButtonTag: Int?
    private let lightModeOverlayLayer = CALayer()

    init(
        providers: [UsageProvider],
        selected: ProviderSwitcherSelection?,
        includesOverview: Bool,
        width: CGFloat,
        showsIcons: Bool,
        iconProvider: (UsageProvider) -> NSImage,
        weeklyRemainingProvider: @escaping (UsageProvider) -> Double?,
        onSelect: @escaping (ProviderSwitcherSelection) -> Void)
    {
        let minimumGap: CGFloat = 1
        var segments = providers.map { provider in
            let fullTitle = Self.switcherTitle(for: provider)
            let icon = iconProvider(provider)
            icon.isTemplate = true
            // Avoid any resampling: we ship exact 16pt/32px assets for crisp rendering.
            icon.size = NSSize(width: 16, height: 16)
            return Segment(
                selection: .provider(provider),
                image: icon,
                title: fullTitle)
        }
        if includesOverview {
            let overviewIcon = Self.overviewIcon()
            overviewIcon.isTemplate = true
            overviewIcon.size = NSSize(width: 16, height: 16)
            segments.insert(
                Segment(
                    selection: .overview,
                    image: overviewIcon,
                    title: "Overview"),
                at: 0)
        }
        self.segments = segments
        self.onSelect = onSelect
        self.showsIcons = showsIcons
        self.weeklyRemainingProvider = weeklyRemainingProvider
        self.stackedIcons = showsIcons && self.segments.count > 3
        let initialOuterPadding = Self.switcherOuterPadding(
            for: width,
            count: self.segments.count,
            minimumGap: minimumGap)
        let initialMaxAllowedSegmentWidth = Self.maxAllowedUniformSegmentWidth(
            for: width,
            count: self.segments.count,
            outerPadding: initialOuterPadding,
            minimumGap: minimumGap)
        self.rowCount = Self.switcherRowCount(
            width: width,
            count: self.segments.count,
            maxAllowedSegmentWidth: initialMaxAllowedSegmentWidth,
            stackedIcons: self.stackedIcons)
        self.rowSpacing = self.stackedIcons ? 4 : 2
        if self.stackedIcons && self.rowCount >= 3 {
            self.rowHeight = 40
        } else {
            self.rowHeight = self.stackedIcons ? 36 : 30
        }
        let height: CGFloat = self.rowHeight * CGFloat(self.rowCount)
            + self.rowSpacing * CGFloat(max(0, self.rowCount - 1))
        self.preferredWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        Self.clearButtonWidthCache()
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        self.lightModeOverlayLayer.masksToBounds = false
        self.layer?.insertSublayer(self.lightModeOverlayLayer, at: 0)
        self.updateLightModeStyling()

        let layoutCount = Self.layoutCount(for: self.segments.count, rows: self.rowCount)
        let outerPadding: CGFloat = Self.switcherOuterPadding(
            for: width,
            count: layoutCount,
            minimumGap: minimumGap)
        let maxAllowedSegmentWidth = Self.maxAllowedUniformSegmentWidth(
            for: width,
            count: layoutCount,
            outerPadding: outerPadding,
            minimumGap: minimumGap)

        func makeButton(index: Int, segment: Segment) -> NSButton {
            let button: NSButton
            if self.stackedIcons {
                let stacked = StackedToggleButton(
                    title: segment.title,
                    image: segment.image,
                    target: self,
                    action: #selector(self.handleSelection(_:)))
                stacked.setAllowsTwoLineTitle(self.rowCount >= 3)
                if self.rowCount >= 4 {
                    stacked.setTitleFontSize(NSFont.smallSystemFontSize - 3)
                }
                button = stacked
            } else if self.showsIcons {
                let inline = InlineIconToggleButton(
                    title: segment.title,
                    image: segment.image,
                    target: self,
                    action: #selector(self.handleSelection(_:)))
                button = inline
            } else {
                button = PaddedToggleButton(
                    title: segment.title,
                    target: self,
                    action: #selector(self.handleSelection(_:)))
            }
            button.tag = index
            if self.showsIcons {
                if self.stackedIcons {
                    // StackedToggleButton manages its own image view.
                } else {
                    // InlineIconToggleButton manages its own image view.
                }
            } else {
                button.image = nil
                button.imagePosition = .noImage
            }

            let remaining: Double? = switch segment.selection {
            case let .provider(provider):
                self.weeklyRemainingProvider(provider)
            case .overview:
                nil
            }
            self.addWeeklyIndicator(to: button, selection: segment.selection, remainingPercent: remaining)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setButtonType(.toggle)
            button.contentTintColor = self.unselectedTextColor
            button.alignment = .center
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.state = (selected == segment.selection) ? .on : .off
            button.toolTip = nil
            button.translatesAutoresizingMaskIntoConstraints = false
            self.buttons.append(button)
            return button
        }

        for (index, segment) in self.segments.enumerated() {
            let button = makeButton(index: index, segment: segment)
            self.addSubview(button)
        }

        let uniformWidth: CGFloat
        if self.rowCount > 1 || !self.stackedIcons {
            uniformWidth = self.applyUniformSegmentWidth(maxAllowedWidth: maxAllowedSegmentWidth)
            if uniformWidth > 0 {
                self.segmentWidths = Array(repeating: uniformWidth, count: self.buttons.count)
            }
        } else {
            self.segmentWidths = self.applyNonUniformSegmentWidths(
                totalWidth: width,
                outerPadding: outerPadding,
                minimumGap: minimumGap)
            uniformWidth = 0
        }

        self.applyLayout(
            outerPadding: outerPadding,
            minimumGap: minimumGap,
            uniformWidth: uniformWidth)
        if width > 0 {
            self.preferredWidth = width
            self.frame.size.width = width
        }

        self.updateButtonStyles()
    }

    override func layout() {
        super.layout()
        self.lightModeOverlayLayer.frame = self.bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.updateLightModeStyling()
        self.updateButtonStyles()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            self.removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(trackingArea)
        self.hoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let location = self.convert(event.locationInWindow, from: nil)
        let hoveredTag = self.buttons.first(where: { $0.frame.contains(location) })?.tag
        guard hoveredTag != self.hoveredButtonTag else { return }
        self.hoveredButtonTag = hoveredTag
        self.updateButtonStyles()
    }

    override func mouseExited(with event: NSEvent) {
        guard self.hoveredButtonTag != nil else { return }
        self.hoveredButtonTag = nil
        self.updateButtonStyles()
    }

    private func applyLayout(
        outerPadding: CGFloat,
        minimumGap: CGFloat,
        uniformWidth: CGFloat)
    {
        if self.rowCount > 1 {
            self.applyMultiRowLayout(
                rowCount: self.rowCount,
                outerPadding: outerPadding,
                minimumGap: minimumGap,
                uniformWidth: uniformWidth)
            return
        }

        if self.buttons.count == 2 {
            let left = self.buttons[0]
            let right = self.buttons[1]
            let gap = right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: minimumGap)
            gap.priority = .defaultHigh
            NSLayoutConstraint.activate([
                left.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: outerPadding),
                left.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                right.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -outerPadding),
                right.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                gap,
            ])
            return
        }

        if self.buttons.count == 3 {
            let left = self.buttons[0]
            let mid = self.buttons[1]
            let right = self.buttons[2]

            let leftGap = mid.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: minimumGap)
            leftGap.priority = .defaultHigh
            let rightGap = right.leadingAnchor.constraint(
                greaterThanOrEqualTo: mid.trailingAnchor,
                constant: minimumGap)
            rightGap.priority = .defaultHigh

            NSLayoutConstraint.activate([
                left.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: outerPadding),
                left.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                mid.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                mid.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                right.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -outerPadding),
                right.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                leftGap,
                rightGap,
            ])
            return
        }

        if self.buttons.count >= 4 {
            let widths = self.segmentWidths.isEmpty
                ? self.buttons.map { ceil($0.fittingSize.width) }
                : self.segmentWidths
            let layoutWidth = self.preferredWidth > 0 ? self.preferredWidth : self.bounds.width
            let availableWidth = max(0, layoutWidth - outerPadding * 2)
            let gaps = max(1, widths.count - 1)
            let computedGap = gaps > 0
                ? max(minimumGap, (availableWidth - widths.reduce(0, +)) / CGFloat(gaps))
                : 0
            let rowContainer = NSView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(rowContainer)

            NSLayoutConstraint.activate([
                rowContainer.topAnchor.constraint(equalTo: self.topAnchor),
                rowContainer.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                rowContainer.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: outerPadding),
                rowContainer.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -outerPadding),
            ])

            var xOffset: CGFloat = 0
            for (index, button) in self.buttons.enumerated() {
                let width = index < widths.count ? widths[index] : 0
                if self.stackedIcons {
                    NSLayoutConstraint.activate([
                        button.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: xOffset),
                        button.topAnchor.constraint(equalTo: rowContainer.topAnchor),
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        button.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: xOffset),
                        button.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                    ])
                }
                xOffset += width + computedGap
            }
            return
        }

        if let first = self.buttons.first {
            NSLayoutConstraint.activate([
                first.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                first.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            ])
        }
    }

    private func applyMultiRowLayout(
        rowCount: Int,
        outerPadding: CGFloat,
        minimumGap: CGFloat,
        uniformWidth: CGFloat)
    {
        let rows = Self.splitRows(for: self.buttons, rowCount: rowCount)
        let columns = rows.map(\.count).max() ?? 0
        let layoutWidth = self.preferredWidth > 0 ? self.preferredWidth : self.bounds.width
        let availableWidth = max(0, layoutWidth - outerPadding * 2)
        let gaps = max(1, columns - 1)
        let totalWidth = uniformWidth * CGFloat(columns)
        let computedGap = gaps > 0
            ? max(minimumGap, (availableWidth - totalWidth) / CGFloat(gaps))
            : 0
        let gridContainer = NSView()
        gridContainer.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(gridContainer)

        NSLayoutConstraint.activate([
            gridContainer.topAnchor.constraint(equalTo: self.topAnchor),
            gridContainer.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            gridContainer.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: outerPadding),
            gridContainer.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -outerPadding),
        ])

        var rowViews: [NSView] = []
        for _ in 0..<rowCount {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            gridContainer.addSubview(row)
            rowViews.append(row)
        }

        var rowConstraints: [NSLayoutConstraint] = []
        for (index, row) in rowViews.enumerated() {
            rowConstraints.append(row.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor))
            rowConstraints.append(row.trailingAnchor.constraint(equalTo: gridContainer.trailingAnchor))
            rowConstraints.append(row.heightAnchor.constraint(equalToConstant: self.rowHeight))
            if index == 0 {
                rowConstraints.append(row.topAnchor.constraint(equalTo: gridContainer.topAnchor))
            } else {
                rowConstraints.append(row.topAnchor.constraint(
                    equalTo: rowViews[index - 1].bottomAnchor,
                    constant: self.rowSpacing))
            }
            if index == rowViews.count - 1 {
                rowConstraints.append(row.bottomAnchor.constraint(equalTo: gridContainer.bottomAnchor))
            }
        }
        NSLayoutConstraint.activate(rowConstraints)

        for (rowIndex, rowButtons) in rows.enumerated() {
            guard rowIndex < rowViews.count else { continue }
            let rowView = rowViews[rowIndex]
            for (columnIndex, button) in rowButtons.enumerated() {
                let xOffset = CGFloat(columnIndex) * (uniformWidth + computedGap)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor, constant: xOffset),
                    button.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                ])
            }
        }
    }

    private static func switcherRowCount(
        width: CGFloat,
        count: Int,
        maxAllowedSegmentWidth: CGFloat,
        stackedIcons: Bool) -> Int
    {
        guard count > 1 else { return 1 }
        let maxRows = min(4, count)
        let fourRowThreshold = 15
        let minimumComfortableAverage: CGFloat = stackedIcons ? 50 : 54
        if count >= fourRowThreshold { return maxRows }
        if maxAllowedSegmentWidth >= minimumComfortableAverage { return 1 }

        for rows in 2...maxRows {
            let perRow = self.layoutCount(for: count, rows: rows)
            let outerPadding = self.switcherOuterPadding(for: width, count: perRow, minimumGap: 1)
            let allowedWidth = self.maxAllowedUniformSegmentWidth(
                for: width,
                count: perRow,
                outerPadding: outerPadding,
                minimumGap: 1)
            if allowedWidth >= minimumComfortableAverage { return rows }
        }

        return maxRows
    }

    private static func layoutCount(for count: Int, rows: Int) -> Int {
        guard rows > 0 else { return count }
        return Int(ceil(Double(count) / Double(rows)))
    }

    private static func splitRows(for buttons: [NSButton], rowCount: Int) -> [[NSButton]] {
        guard rowCount > 1 else { return [buttons] }
        let base = buttons.count / rowCount
        let extra = buttons.count % rowCount
        var rows: [[NSButton]] = []
        var start = 0
        for index in 0..<rowCount {
            let size = base + (index < extra ? 1 : 0)
            if size == 0 {
                rows.append([])
                continue
            }
            let end = min(buttons.count, start + size)
            rows.append(Array(buttons[start..<end]))
            start = end
        }
        return rows
    }

    private static func switcherOuterPadding(for width: CGFloat, count: Int, minimumGap: CGFloat) -> CGFloat {
        // Align with the card's left/right content grid when possible.
        let preferred: CGFloat = 16
        let reduced: CGFloat = 10
        let minimal: CGFloat = 6

        func averageButtonWidth(outerPadding: CGFloat) -> CGFloat {
            let available = width - outerPadding * 2 - minimumGap * CGFloat(max(0, count - 1))
            guard count > 0 else { return 0 }
            return available / CGFloat(count)
        }

        // Only sacrifice padding when we'd otherwise squeeze buttons into unreadable widths.
        let minimumComfortableAverage: CGFloat = count >= 5 ? 50 : 54

        if averageButtonWidth(outerPadding: preferred) >= minimumComfortableAverage { return preferred }
        if averageButtonWidth(outerPadding: reduced) >= minimumComfortableAverage { return reduced }
        return minimal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.preferredWidth, height: self.frame.size.height)
    }

    @objc private func handleSelection(_ sender: NSButton) {
        let index = sender.tag
        guard self.segments.indices.contains(index) else { return }
        for (idx, button) in self.buttons.enumerated() {
            button.state = (idx == index) ? .on : .off
        }
        self.updateButtonStyles()
        self.onSelect(self.segments[index].selection)
    }

    private func updateButtonStyles() {
        for button in self.buttons {
            let isSelected = button.state == .on
            let isHovered = self.hoveredButtonTag == button.tag
            button.contentTintColor = isSelected ? self.selectedTextColor : self.unselectedTextColor
            button.layer?.backgroundColor = if isSelected {
                self.selectedBackground
            } else if isHovered {
                self.hoverPlateColor()
            } else {
                self.unselectedBackground
            }
            self.updateWeeklyIndicatorVisibility(for: button)
            (button as? StackedToggleButton)?.setContentTintColor(button.contentTintColor)
            (button as? InlineIconToggleButton)?.setContentTintColor(button.contentTintColor)
        }
    }

    private func isLightMode() -> Bool {
        self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    private func updateLightModeStyling() {
        guard self.isLightMode() else {
            self.lightModeOverlayLayer.backgroundColor = nil
            return
        }
        // The menu card background is very bright in light mode; add a subtle neutral wash to ground the switcher.
        self.lightModeOverlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.035).cgColor
    }

    private func hoverPlateColor() -> CGColor {
        if self.isLightMode() {
            return NSColor.black.withAlphaComponent(0.095).cgColor
        }
        return NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    /// Cache for button width measurements to avoid repeated layout passes.
    private static var buttonWidthCache: [ObjectIdentifier: CGFloat] = [:]

    private static func maxToggleWidth(for button: NSButton) -> CGFloat {
        let buttonId = ObjectIdentifier(button)

        // Return cached value if available.
        if let cached = buttonWidthCache[buttonId] {
            return cached
        }

        let originalState = button.state
        defer { button.state = originalState }

        button.state = .off
        button.layoutSubtreeIfNeeded()
        let offWidth = button.fittingSize.width

        button.state = .on
        button.layoutSubtreeIfNeeded()
        let onWidth = button.fittingSize.width

        let maxWidth = max(offWidth, onWidth)
        self.buttonWidthCache[buttonId] = maxWidth
        return maxWidth
    }

    private static func clearButtonWidthCache() {
        self.buttonWidthCache.removeAll()
    }

    private func applyUniformSegmentWidth(maxAllowedWidth: CGFloat) -> CGFloat {
        guard !self.buttons.isEmpty else { return 0 }

        var desiredWidths: [CGFloat] = []
        desiredWidths.reserveCapacity(self.buttons.count)

        for (index, button) in self.buttons.enumerated() {
            if self.stackedIcons,
               self.segments.indices.contains(index)
            {
                let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                let titleWidth = ceil(
                    (self.segments[index].title as NSString).size(withAttributes: [.font: font])
                        .width)
                let contentPadding: CGFloat = 4 + 4
                let extraSlack: CGFloat = 1
                desiredWidths.append(ceil(titleWidth + contentPadding + extraSlack))
            } else {
                desiredWidths.append(ceil(Self.maxToggleWidth(for: button)))
            }
        }

        let maxDesired = desiredWidths.max() ?? 0
        let evenMaxDesired = maxDesired.truncatingRemainder(dividingBy: 2) == 0 ? maxDesired : maxDesired + 1
        let evenMaxAllowed = maxAllowedWidth > 0
            ? (maxAllowedWidth.truncatingRemainder(dividingBy: 2) == 0 ? maxAllowedWidth : maxAllowedWidth - 1)
            : 0
        let finalWidth: CGFloat = if evenMaxAllowed > 0 {
            min(evenMaxDesired, evenMaxAllowed)
        } else {
            evenMaxDesired
        }

        if finalWidth > 0 {
            for button in self.buttons {
                button.widthAnchor.constraint(equalToConstant: finalWidth).isActive = true
            }
        }

        return finalWidth
    }

    @discardableResult
    private func applyNonUniformSegmentWidths(
        totalWidth: CGFloat,
        outerPadding: CGFloat,
        minimumGap: CGFloat) -> [CGFloat]
    {
        guard !self.buttons.isEmpty else { return [] }

        let count = self.buttons.count
        let available = totalWidth -
            outerPadding * 2 -
            minimumGap * CGFloat(max(0, count - 1))
        guard available > 0 else { return [] }

        func evenFloor(_ value: CGFloat) -> CGFloat {
            var v = floor(value)
            if Int(v) % 2 != 0 { v -= 1 }
            return v
        }

        let desired = self.buttons.map { ceil(Self.maxToggleWidth(for: $0)) }
        let desiredSum = desired.reduce(0, +)
        let avg = floor(available / CGFloat(count))
        let minWidth = max(24, min(40, avg))

        var widths: [CGFloat]
        if desiredSum <= available {
            widths = desired
        } else {
            let totalCapacity = max(0, desiredSum - minWidth * CGFloat(count))
            if totalCapacity <= 0 {
                widths = Array(repeating: available / CGFloat(count), count: count)
            } else {
                let overflow = desiredSum - available
                widths = desired.map { desiredWidth in
                    let capacity = max(0, desiredWidth - minWidth)
                    let shrink = overflow * (capacity / totalCapacity)
                    return desiredWidth - shrink
                }
            }
        }

        widths = widths.map { max(minWidth, evenFloor($0)) }
        var used = widths.reduce(0, +)

        while available - used >= 2 {
            if let best = widths.indices
                .filter({ desired[$0] - widths[$0] >= 2 })
                .max(by: { lhs, rhs in
                    (desired[lhs] - widths[lhs]) < (desired[rhs] - widths[rhs])
                })
            {
                widths[best] += 2
                used += 2
                continue
            }

            guard let best = widths.indices.min(by: { lhs, rhs in widths[lhs] < widths[rhs] }) else { break }
            widths[best] += 2
            used += 2
        }

        for (index, button) in self.buttons.enumerated() where index < widths.count {
            button.widthAnchor.constraint(equalToConstant: widths[index]).isActive = true
        }

        return widths
    }

    private static func maxAllowedUniformSegmentWidth(
        for totalWidth: CGFloat,
        count: Int,
        outerPadding: CGFloat,
        minimumGap: CGFloat) -> CGFloat
    {
        guard count > 0 else { return 0 }
        let available = totalWidth -
            outerPadding * 2 -
            minimumGap * CGFloat(max(0, count - 1))
        guard available > 0 else { return 0 }
        return floor(available / CGFloat(count))
    }

    private static func paddedImage(_ image: NSImage, leading: CGFloat) -> NSImage {
        let size = NSSize(width: image.size.width + leading, height: image.size.height)
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        let y = (size.height - image.size.height) / 2
        image.draw(
            at: NSPoint(x: leading, y: y),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0)
        newImage.unlockFocus()
        newImage.isTemplate = image.isTemplate
        return newImage
    }

    private func addWeeklyIndicator(to view: NSView, selection: ProviderSwitcherSelection, remainingPercent: Double?) {
        guard let remainingPercent else { return }

        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.22).cgColor
        track.layer?.cornerRadius = 2
        track.layer?.masksToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(track)

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Self.weeklyIndicatorColor(for: selection).cgColor
        fill.layer?.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let ratio = CGFloat(max(0, min(1, remainingPercent / 100)))

        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            track.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            track.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])

        fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: ratio).isActive = true

        self.weeklyIndicators[ObjectIdentifier(view)] = WeeklyIndicator(track: track, fill: fill)
        self.updateWeeklyIndicatorVisibility(for: view)
    }

    private func updateWeeklyIndicatorVisibility(for view: NSView) {
        guard let indicator = self.weeklyIndicators[ObjectIdentifier(view)] else { return }
        let isSelected = (view as? NSButton)?.state == .on
        indicator.track.isHidden = isSelected
        indicator.fill.isHidden = isSelected
    }

    private static func weeklyIndicatorColor(for selection: ProviderSwitcherSelection) -> NSColor {
        switch selection {
        case let .provider(provider):
            let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
            return NSColor(deviceRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        case .overview:
            return NSColor.secondaryLabelColor
        }
    }

    private static func overviewIcon() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) {
            return symbol
        }
        return NSImage(size: NSSize(width: 16, height: 16))
    }

    private static func switcherTitle(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }
}

final class TokenAccountSwitcherView: NSView {
    private let accounts: [ProviderTokenAccount]
    private let onSelect: (Int) -> Void
    private var selectedIndex: Int
    private var buttons: [NSButton] = []
    private let rowSpacing: CGFloat = 4
    private let rowHeight: CGFloat = 26
    private let selectedBackground = NSColor.controlAccentColor.cgColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let selectedTextColor = NSColor.white
    private let unselectedTextColor = NSColor.secondaryLabelColor

    init(accounts: [ProviderTokenAccount], selectedIndex: Int, width: CGFloat, onSelect: @escaping (Int) -> Void) {
        self.accounts = accounts
        self.onSelect = onSelect
        self.selectedIndex = min(max(selectedIndex, 0), max(0, accounts.count - 1))
        let useTwoRows = accounts.count > 3
        let rows = useTwoRows ? 2 : 1
        let height = self.rowHeight * CGFloat(rows) + (useTwoRows ? self.rowSpacing : 0)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.wantsLayer = true
        self.buildButtons(useTwoRows: useTwoRows)
        self.updateButtonStyles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildButtons(useTwoRows: Bool) {
        let perRow = useTwoRows ? Int(ceil(Double(self.accounts.count) / 2.0)) : self.accounts.count
        let rows: [[ProviderTokenAccount]] = {
            if !useTwoRows { return [self.accounts] }
            let first = Array(self.accounts.prefix(perRow))
            let second = Array(self.accounts.dropFirst(perRow))
            return [first, second]
        }()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        var globalIndex = 0
        for rowAccounts in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = self.rowSpacing
            row.translatesAutoresizingMaskIntoConstraints = false

            for account in rowAccounts {
                let button = PaddedToggleButton(
                    title: account.displayName,
                    target: self,
                    action: #selector(self.handleSelect))
                button.tag = globalIndex
                button.toolTip = account.displayName
                button.isBordered = false
                button.setButtonType(.toggle)
                button.controlSize = .small
                button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                button.wantsLayer = true
                button.layer?.cornerRadius = 6
                row.addArrangedSubview(button)
                self.buttons.append(button)
                globalIndex += 1
            }

            stack.addArrangedSubview(row)
        }

        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: self.rowHeight * CGFloat(rows.count) +
                (useTwoRows ? self.rowSpacing : 0)),
        ])
    }

    private func updateButtonStyles() {
        for (index, button) in self.buttons.enumerated() {
            let selected = index == self.selectedIndex
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? self.selectedBackground : self.unselectedBackground
            button.contentTintColor = selected ? self.selectedTextColor : self.unselectedTextColor
        }
    }

    @objc private func handleSelect(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < self.accounts.count else { return }
        self.selectedIndex = index
        self.updateButtonStyles()
        self.onSelect(index)
    }
}
