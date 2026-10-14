import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuCardErrorSubtitleProofTests {
    @Test
    func `renders synthetic Claude error headers`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_ERROR_SUBTITLE_PROOF"] else { return }
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let now = Date()
            let capturedAt = now.addingTimeInterval(-7 * 24 * 3600)
            let error = ClaudeUIErrorMapper.userFacingMessage(
                ClaudeOAuthCredentialsError.missingAccessToken.localizedDescription,
                staleSnapshotUpdatedAt: nil,
                keychainAccessDisabled: false)
            let stale = try Self.model(
                now: now, capturedAt: capturedAt, error: error, lastKnownUsageCapturedAt: capturedAt)
            try Self.render(stale, name: "after-stale", directory: directory)
            let missing = try Self.model(now: now, capturedAt: nil, error: error)
            try Self.render(missing, name: "after-error-only", directory: directory)
            let normal = try Self.model(now: now, capturedAt: now.addingTimeInterval(-180), error: nil)
            try Self.render(normal, name: "after-updated", directory: directory)
        }
    }

    @Test
    func `live error and recovery preserve the initially measured header height`() throws {
        let now = Date()
        let info = try Self.model(now: now, capturedAt: now, error: nil, usesLiveSubtitle: true)
        let error = try Self.model(
            now: now,
            capturedAt: now,
            error: String(repeating: "Synthetic `claude` error with a long explanation. ", count: 12),
            usesLiveSubtitle: true)
        var live = info
        let monitor = MenuCardRefreshMonitor(resolveModel: { _ in live }, isProviderRefreshActive: { _ in false })
        for layout in [info, error] {
            live = layout
            let initial = try Self.headerSize(layout, monitor: monitor)
            live = error
            #expect(try Self.headerSize(layout, monitor: monitor) == initial)
            live = info
            #expect(try Self.headerSize(layout, monitor: monitor) == initial)
        }
    }

    @Test
    func `live refreshes keep the stale usage notice in sync`() throws {
        let now = Date()
        let capturedAt = now.addingTimeInterval(-7 * 24 * 3600)
        let healthy = try Self.model(now: now, capturedAt: now, error: nil, usesLiveSubtitle: true)
        let failed = try Self.model(
            now: now,
            capturedAt: capturedAt,
            error: "Synthetic `claude` error.",
            lastKnownUsageCapturedAt: capturedAt,
            usesLiveSubtitle: true)
        let stale = try #require(failed.lastKnownUsageText)
        var live = healthy
        let monitor = MenuCardRefreshMonitor(resolveModel: { _ in live }, isProviderRefreshActive: { _ in false })

        // Healthy when hosted, failed while open: no reserved row, so the notice joins the error text.
        live = failed
        let opened = monitor.subtitle(for: .claude, fallback: .init(text: "", style: .info))
        #expect(opened.lastKnownUsageText == stale)
        let joined = opened.displayed(reservesStaleRow: healthy.lastKnownUsageText != nil)
        #expect(joined.subtitle == "Synthetic `claude` error. \(stale)")
        #expect(joined.staleRow == nil)

        // Failed when hosted, recovered while open: the reserved row empties instead of showing old text.
        live = healthy
        let recovered = monitor.subtitle(for: .claude, fallback: .init(text: "", style: .info))
            .displayed(reservesStaleRow: failed.lastKnownUsageText != nil)
        #expect(recovered.staleRow == nil)
        #expect(recovered.subtitle == healthy.subtitleText)

        // Failed when hosted and still failed: the reserved row keeps the live notice; the error stays separate.
        live = failed
        let still = monitor.subtitle(for: .claude, fallback: .init(text: "", style: .info))
            .displayed(reservesStaleRow: true)
        #expect(still.staleRow == stale)
        #expect(still.subtitle == "Synthetic `claude` error.")
    }

    @Test
    func `manual refresh keeps the hosted stale notice while refreshing`() {
        let monitor = MenuCardRefreshMonitor(resolveModel: { _ in nil }, isProviderRefreshActive: { _ in false })
        monitor.beginManualRefresh(frozenModels: [:], provider: .claude)
        let refreshing = monitor.subtitle(
            for: .claude,
            fallback: .init(text: "Error", style: .error, lastKnownUsageText: "Showing last-known usage."))
        #expect(refreshing.style == .loading)
        #expect(refreshing.lastKnownUsageText == "Showing last-known usage.")
        monitor.endManualRefresh(for: .claude)
    }

    private static func headerSize(
        _ model: UsageMenuCardView.Model,
        monitor: MenuCardRefreshMonitor) throws -> CGSize
    {
        let renderer = ImageRenderer(content:
            UsageMenuCardHeaderSectionView(model: model, showDivider: false, width: 310)
                .environment(\.menuCardRefreshMonitor, monitor))
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    static func model(
        now: Date,
        capturedAt: Date?,
        error: String?,
        lastKnownUsageCapturedAt: Date? = nil,
        usesLiveSubtitle: Bool = false) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: capturedAt.map { UsageSnapshot(primary: nil, secondary: nil, updatedAt: $0) },
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "user@example.com", plan: nil),
            lastKnownUsageCapturedAt: lastKnownUsageCapturedAt,
            isRefreshing: false,
            lastError: error,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            usesLiveSubtitle: usesLiveSubtitle,
            now: now))
    }

    static func render(_ model: UsageMenuCardView.Model, name: String, directory: String) throws {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = UsageMenuCardHeaderSectionView(model: model, showDivider: false, width: 310)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .background(Color(white: 0.16))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }
}
