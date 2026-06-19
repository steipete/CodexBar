import AppKit
import CodexBarCore
import SwiftUI

struct StorageMenuCardSectionView: View {
    let storageText: String
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(L("Storage"))
                .font(.body)
            Text(self.storageText)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, self.topPadding)
        .padding(.bottom, self.bottomPadding)
        .frame(width: self.width, alignment: .leading)
    }
}

struct StorageBreakdownMenuView: View {
    let footprint: ProviderStorageFootprint
    let width: CGFloat
    let maxHeight: CGFloat
    let onExpansionHeightChange: ((CGFloat) -> Void)?

    @State private var otherExpanded = false

    init(
        footprint: ProviderStorageFootprint,
        width: CGFloat,
        maxHeight: CGFloat = 560,
        onExpansionHeightChange: ((CGFloat) -> Void)? = nil)
    {
        self.footprint = footprint
        self.width = width
        self.maxHeight = maxHeight
        self.onExpansionHeightChange = onExpansionHeightChange
    }

    /// One entry in the segmented bar and its matching legend row. Overflow components past the row
    /// budget collapse into a single trailing "Other" segment with no copyable path of its own.
    private struct Segment: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
        let path: String?
    }

    /// How many legend rows we let the breakdown show before collapsing the tail into "Other".
    private static let maxRows = 8

    private static let segmentPalette: [Color] = [
        Color(red: 0.20, green: 0.51, blue: 0.96),
        Color(red: 0.96, green: 0.55, blue: 0.20),
        Color(red: 0.30, green: 0.78, blue: 0.47),
        Color(red: 0.66, green: 0.42, blue: 0.93),
        Color(red: 0.95, green: 0.74, blue: 0.22),
        Color(red: 0.92, green: 0.36, blue: 0.55),
        Color(red: 0.27, green: 0.76, blue: 0.82),
    ]

    private static let otherColor = Color(nsColor: .tertiaryLabelColor)
    private static let overflowRowHeight: CGFloat = 18
    private static let overflowRowSpacing: CGFloat = 4
    private static let overflowTopSpacing: CGFloat = 6

    var cleanupRecommendations: [ProviderStorageRecommendation] {
        self.footprint.cleanupRecommendations
    }

    var copyablePaths: [String] {
        let recommendationPaths = self.cleanupRecommendations.map(\.path)
        return self.footprint.components.map(\.path) + recommendationPaths
    }

    /// Visible components mapped to colored segments, with any tail beyond `maxRows` folded into a
    /// single "Other" entry so the bar and legend never exceed the row budget.
    private var segments: [Segment] {
        let components = self.footprint.components
        guard !components.isEmpty else { return [] }

        func color(_ index: Int) -> Color {
            Self.segmentPalette[index % Self.segmentPalette.count]
        }

        func segment(_ component: ProviderStorageFootprint.Component, _ index: Int) -> Segment {
            Segment(
                id: component.id,
                name: component.name,
                bytes: max(component.totalBytes, 0),
                color: color(index),
                path: component.path)
        }

        if components.count <= Self.maxRows {
            return components.enumerated().map { segment($1, $0) }
        }

        let visible = components.prefix(Self.maxRows - 1)
        let overflow = components.dropFirst(Self.maxRows - 1)
        let otherBytes = overflow.reduce(Int64(0)) { partial, component in
            let bytes = max(component.totalBytes, 0)
            let (sum, overflowed) = partial.addingReportingOverflow(bytes)
            return overflowed ? .max : sum
        }
        return visible.enumerated().map { segment($1, $0) } + [
            Segment(
                id: "__other__",
                name: String(format: L("Other (%d items)"), overflow.count),
                bytes: otherBytes,
                color: Self.otherColor,
                path: nil),
        ]
    }

    private var segmentTotalBytes: Double {
        self.segments.reduce(0) { $0 + Double($1.bytes) }
    }

    /// The components folded into the trailing "Other" segment, revealed when it is expanded.
    private var overflowComponents: [ProviderStorageFootprint.Component] {
        let components = self.footprint.components
        guard components.count > Self.maxRows else { return [] }
        return Array(components.dropFirst(Self.maxRows - 1))
    }

    private var overflowExpansionHeight: CGFloat {
        let count = CGFloat(self.overflowComponents.count)
        guard count > 0 else { return 0 }
        return Self.overflowTopSpacing
            + count * Self.overflowRowHeight
            + (count - 1) * Self.overflowRowSpacing
    }

    var body: some View {
        ScrollView(.vertical) {
            self.content
        }
        .scrollIndicators(.visible)
        .frame(
            minWidth: self.width,
            idealWidth: self.width,
            maxWidth: self.width,
            maxHeight: self.maxHeight,
            alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Storage"))
                    .font(.body)
                    .fontWeight(.medium)
                Text(String(format: L("Total: %@"), UsageFormatter.byteCountStringLong(self.footprint.totalBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if self.segments.isEmpty {
                Text(L("No local data found"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                self.segmentedBar
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.segments) { segment in
                        self.legendRow(segment)
                    }
                }
            }

            if !self.cleanupRecommendations.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Cleanup ideas"))
                        .font(.body)
                        .fontWeight(.medium)
                    ForEach(self.cleanupRecommendations) { recommendation in
                        self.recommendationRow(recommendation)
                    }
                }
            }
            if !self.footprint.unreadablePaths.isEmpty {
                Text(String(format: L("%d unreadable item(s) skipped"), self.footprint.unreadablePaths.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
    }

    private var segmentedBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                HStack(spacing: 0) {
                    ForEach(self.segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: self.segmentWidth(segment, barWidth: proxy.size.width))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }

    /// Each segment gets at least `minWidth` so tiny components stay visible, with the remaining width
    /// shared by byte proportion. Reserving the minimums (rather than flooring each width with `max`)
    /// keeps the segments summing to exactly `barWidth`, so none get clipped off the capsule's end.
    private func segmentWidth(_ segment: Segment, barWidth: CGFloat) -> CGFloat {
        let minWidth: CGFloat = 2
        let count = CGFloat(self.segments.count)
        guard self.segmentTotalBytes > 0 else { return barWidth / max(count, 1) }
        let reserved = minWidth * count
        guard barWidth > reserved else { return barWidth / max(count, 1) }
        let remainder = barWidth - reserved
        let proportion = CGFloat(Double(segment.bytes) / self.segmentTotalBytes)
        return minWidth + remainder * proportion
    }

    private func legendRow(_ segment: Segment) -> some View {
        let isOther = segment.path == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(segment.color)
                    .frame(width: 9, height: 9)
                Text(segment.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(segment.path ?? segment.name)
                    .layoutPriority(1)
                Spacer()
                if let path = segment.path {
                    StoragePathCopyButton(path: path)
                } else {
                    self.otherExpandButton
                }
                Text(UsageFormatter.byteCountString(segment.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isOther, self.otherExpanded {
                self.overflowList
            }
        }
    }

    private var otherExpandButton: some View {
        Button {
            self.otherExpanded.toggle()
            self.onExpansionHeightChange?(self.otherExpanded ? self.overflowExpansionHeight : 0)
        } label: {
            Image(systemName: self.otherExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.otherExpanded ? L("Collapse") : L("Expand"))
        .accessibilityLabel(self.otherExpanded ? L("Collapse") : L("Expand"))
    }

    /// Plain name + size rows for the items folded into "Other" — no colors, indented under its name.
    private var overflowList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(self.overflowComponents) { component in
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(component.path)
                    Spacer()
                    StoragePathCopyButton(path: component.path)
                    Text(UsageFormatter.byteCountString(component.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 17)
    }

    private func recommendationRow(_ recommendation: ProviderStorageRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(recommendation.title))
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(UsageFormatter.byteCountString(recommendation.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(recommendation.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(recommendation.path)
                    .layoutPriority(1)
                Spacer()
                StoragePathCopyButton(path: recommendation.path)
            }
            Text(L(recommendation.consequence))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
extension StorageBreakdownMenuView {
    var _segmentNamesForTesting: [String] {
        self.segments.map(\.name)
    }

    var _segmentBytesForTesting: [Int64] {
        self.segments.map(\.bytes)
    }

    var _overflowNamesForTesting: [String] {
        self.overflowComponents.map(\.name)
    }

    var _overflowExpansionHeightForTesting: CGFloat {
        self.overflowExpansionHeight
    }

    func _segmentWidthsForTesting(barWidth: CGFloat) -> [CGFloat] {
        self.segments.map { self.segmentWidth($0, barWidth: barWidth) }
    }
}
#endif

struct StoragePathCopyButton: View {
    let path: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            self.resetTask?.cancel()
            MenuPasteboardCopy.perform(self.path, completion: {
                self.didCopy = true
                self.resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.9))
                    self.didCopy = false
                }
            })
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.didCopy ? L("Copied") : L("Copy path"))
        .accessibilityLabel(self.didCopy ? L("Copied") : L("Copy path"))
    }
}
