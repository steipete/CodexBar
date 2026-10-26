import AppKit
import SwiftUI

/// Keeps the annual calendar continuous without shrinking days below a readable size.
struct SpendActivityScrollableGrid<Content: View>: View {
    var headerHeight: CGFloat = 0
    var scrollToIndex: Int?
    @ViewBuilder let content: (CGSize, CGRect) -> Content

    @State private var viewportWidth: CGFloat = 0
    @State private var contentOffset: CGFloat = 0

    var body: some View {
        let frame = SpendActivityGridGeometry.gridFrame(containerWidth: self.viewportWidth)
        let navigation = SpendActivityScrollNavigation(
            contentWidth: frame.width, viewportWidth: self.viewportWidth, offset: self.contentOffset)
        let indicatorHeight: CGFloat = navigation.isScrollable ? 18 : 0
        ScrollViewReader { reader in
            VStack(spacing: 6) {
                self.scrollView(frame: frame, indicatorHeight: indicatorHeight, reader: reader)
                if navigation.isScrollable {
                    HStack {
                        Button {
                            reader.scrollTo(navigation.targetColumn(toward: .earlier), anchor: .leading)
                        } label: {
                            Label(L("Earlier activity"), systemImage: "chevron.left")
                        }
                        .disabled(!navigation.canScrollEarlier)
                        .accessibilityIdentifier("spend-activity-earlier")
                        Spacer()
                        Button {
                            reader.scrollTo(navigation.targetColumn(toward: .later), anchor: .leading)
                        } label: {
                            HStack(spacing: 4) {
                                Text(L("More recent activity"))
                                Image(systemName: "chevron.right")
                            }
                        }
                        .disabled(!navigation.canScrollLater)
                        .accessibilityIdentifier("spend-activity-later")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.callout)
                    .frame(height: 24)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { self.viewportWidth = $0 }
    }

    private func scrollView(frame: CGRect, indicatorHeight: CGFloat, reader: ScrollViewProxy) -> some View {
        GeometryReader { container in
            let grid = SpendActivityGridGeometry.gridFrame(containerWidth: container.size.width)
            let visibleRect = CGRect(
                x: max(self.contentOffset, 0),
                y: 0,
                width: container.size.width,
                height: grid.height)
            ScrollView(.horizontal) {
                self.content(grid.size, visibleRect)
                    .frame(width: grid.width, height: self.headerHeight + grid.height)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(0..<SpendActivitySeries.weekCount, id: \.self) { column in
                                Color.clear
                                    .frame(width: grid.width / CGFloat(SpendActivitySeries.weekCount), height: 1)
                                    .id(column)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .padding(.bottom, indicatorHeight)
                    .background {
                        SpendActivityScrollOffsetReader { offset in
                            if self.contentOffset != offset { self.contentOffset = offset }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
            }
            .defaultScrollAnchor(.trailing)
            // Canvas columns and scroll targets share left-origin calendar coordinates.
            .environment(\.layoutDirection, .leftToRight)
            .onChange(of: self.scrollToIndex) { _, index in
                if let index { reader.scrollTo(index / SpendActivitySeries.dayCount) }
            }
        }
        .frame(height: self.headerHeight + frame.height + indicatorHeight)
    }
}

struct SpendActivityScrollNavigation {
    enum Direction {
        case earlier
        case later
    }

    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let offset: CGFloat

    private var maximumOffset: CGFloat {
        max(self.contentWidth - self.viewportWidth, 0)
    }

    private var boundedOffset: CGFloat {
        min(max(self.offset, 0), self.maximumOffset)
    }

    var isScrollable: Bool {
        self.viewportWidth > 0 && self.maximumOffset > 0.5
    }

    var canScrollEarlier: Bool {
        self.isScrollable && self.boundedOffset > 0.5
    }

    var canScrollLater: Bool {
        self.isScrollable && self.boundedOffset < self.maximumOffset - 0.5
    }

    /// Keep one week visible across page moves, and align the destination to a week boundary.
    func targetColumn(toward direction: Direction) -> Int {
        let pitch = self.contentWidth / CGFloat(SpendActivitySeries.weekCount)
        guard pitch > 0 else { return 0 }
        let step = max(self.viewportWidth - 2 * pitch, pitch)
        let destination = direction == .earlier
            ? max(self.boundedOffset - step, 0)
            : min(self.boundedOffset + step, self.maximumOffset)
        let column = (destination / pitch).rounded(direction == .earlier ? .down : .up)
        return min(max(Int(column), 0), SpendActivitySeries.weekCount - 1)
    }
}

private struct SpendActivityScrollOffsetReader: NSViewRepresentable {
    let offsetChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> OffsetView {
        let view = OffsetView()
        view.offsetChanged = self.offsetChanged
        return view
    }

    func updateNSView(_ view: OffsetView, context: Context) {
        view.offsetChanged = self.offsetChanged
        view.connect()
    }

    static func dismantleNSView(_ view: OffsetView, coordinator: ()) {
        view.disconnect()
    }

    final class OffsetView: NSView {
        var offsetChanged: ((CGFloat) -> Void)?
        private weak var clipView: NSClipView?
        private var originalPostsBoundsChangedNotifications = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            self.connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.connect()
        }

        func connect() {
            guard let clip = self.enclosingScrollView?.contentView else { return }
            if self.clipView !== clip {
                self.disconnect()
                self.clipView = clip
                self.originalPostsBoundsChangedNotifications = clip.postsBoundsChangedNotifications
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(self.boundsChanged(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clip)
            }
            self.publishOffset()
        }

        func disconnect() {
            if let clip = self.clipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: clip)
                clip.postsBoundsChangedNotifications = self.originalPostsBoundsChangedNotifications
            }
            self.clipView = nil
        }

        @objc private func boundsChanged(_ notification: Notification) {
            self.publishOffset()
        }

        private func publishOffset() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.clipView else { return }
                self.offsetChanged?(clip.bounds.minX)
            }
        }
    }
}
