import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MetricTextUpdateLayoutTests {
    enum TextKind: String, CaseIterable {
        case pace
        case detail

        var initialText: String {
            switch self {
            case .pace: "On pace · Lasts until reset"
            case .detail: "100 credits remaining"
            }
        }

        var updatedText: String {
            switch self {
            case .pace: "32% in deficit · Runs out in 1d 11m"
            case .detail: "1234 credits remaining this week"
            }
        }
    }

    private struct RenderedSection {
        let size: CGSize
        let pixels: Data
        let png: Data
    }

    @Test(arguments: TextKind.allCases)
    func `longer live metric text renders like a reopened card without changing height`(_ kind: TextKind) throws {
        let initial = Self.model(kind: kind, text: kind.initialText)
        let updated = Self.model(kind: kind, text: kind.updatedText)
        #expect(initial.hasCompatibleTrackedLayout(with: updated))

        let before = try Self.render(model: initial, layoutModel: initial)
        let live = try Self.render(model: updated, layoutModel: initial)
        let reopened = try Self.render(model: updated, layoutModel: updated)

        // Optional, synthetic-only artifacts use the same production view and fixture as the regression.
        try Self.export(before, name: "\(kind.rawValue)-initial")
        try Self.export(live, name: "\(kind.rawValue)-live")
        try Self.export(reopened, name: "\(kind.rawValue)-reopened")

        #expect(live.size == before.size)
        #expect(live.size == reopened.size)
        #expect(before.pixels != reopened.pixels, "The fixture must visibly update its text.")
        #expect(live.pixels == reopened.pixels, "Frozen layout must not clip text that fits the card width.")
    }

    @Test
    func `live forecast that exceeds the reserved lines keeps the open card height`() throws {
        let initial = Self.model(kind: .pace, text: TextKind.pace.initialText)
        let updated = Self.model(
            kind: .pace,
            text: "32% in deficit · Runs out in 1 day and 11 minutes at the current usage rate")
        let before = try Self.render(model: initial, layoutModel: initial)
        let live = try Self.render(model: updated, layoutModel: initial)
        let reopened = try Self.render(model: updated, layoutModel: updated)

        #expect(reopened.size.height > before.size.height, "The fixture must require an extra line.")
        #expect(live.size == before.size)
        try Self.export(live, name: "pace-overflow-live")
        try Self.export(reopened, name: "pace-overflow-reopened")
    }

    private static func model(kind: TextKind, text: String) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model(
            provider: .kimi,
            providerName: "Kimi Code",
            email: "synthetic@example.test",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: nil,
            metrics: [.init(
                id: "primary",
                title: "7-day usage",
                percent: 68,
                percentStyle: .left,
                resetText: "Resets in 3d 2h",
                detailText: kind == .detail ? text : nil,
                detailLeftText: kind == .pace ? text : nil,
                detailRightText: nil,
                pacePercent: 36,
                detailIsPaceDerived: kind == .pace,
                paceOnTop: false)],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }

    private static func render(
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model) throws -> RenderedSection
    {
        let view = UsageMenuCardUsageSectionView(
            model: model,
            layoutModel: layoutModel,
            showBottomDivider: false,
            bottomPadding: 6,
            width: 320)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, 2)
            .background(Color.white)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        #expect(size.width == 320)
        #expect(size.height > 0)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelWidth * 4,
            bitsPerPixel: 32))
        representation.size = size
        let pixels = try #require(representation.bitmapData)
        let byteCount = representation.bytesPerRow * pixelHeight
        pixels.initialize(repeating: 0, count: byteCount)
        let context = try #require(NSGraphicsContext(bitmapImageRep: representation))
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        return try RenderedSection(
            size: size,
            pixels: Data(bytes: pixels, count: byteCount),
            png: #require(representation.representation(using: .png, properties: [:])))
    }

    private static func export(_ rendered: RenderedSection, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_FORECAST_LAYOUT_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rendered.png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
