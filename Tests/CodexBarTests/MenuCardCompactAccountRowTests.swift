import AppKit
import CodexBarCore
import SwiftUI
import Testing
import XCTest
@testable import CodexBar

@MainActor
private enum CompactAccountResetFixtures {
    static let now = Date(timeIntervalSince1970: 1_782_000_000)

    static func window(
        _ used: Double,
        after seconds: TimeInterval? = nil,
        description: String? = nil,
        synthetic: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: 300,
            resetsAt: seconds.map { self.now.addingTimeInterval($0) },
            resetDescription: description,
            isSyntheticPlaceholder: synthetic)
    }

    static func row(
        provider: UsageProvider = .codex,
        primary: RateWindow? = nil,
        weekly: RateWindow? = nil,
        monthly: RateWindow? = nil,
        extras: [NamedRateWindow] = [],
        error: String? = nil) throws -> AccountMenuLayoutPlanner.CompactRow
    {
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: weekly,
            tertiary: monthly,
            extraRateWindows: extras,
            updatedAt: self.now)
        let siblingSnapshot = UsageSnapshot(
            primary: self.window(0, after: 600),
            secondary: nil,
            updatedAt: self.now)
        var accounts: [ProviderAccountUsageSnapshot] = []
        for index in 0..<4 {
            let identity = ProviderAccountIdentity(source: "codex-account", opaqueID: String(index))
            let accountSnapshot: UsageSnapshot = index == 1 ? snapshot : siblingSnapshot
            let accountError: String? = index == 1 ? error : nil
            let account = ProviderAccountUsageSnapshot(
                id: identity,
                provider: provider,
                displayLabel: "account-\(index)@example.com",
                isActive: index == 0,
                canActivate: index != 0,
                snapshot: accountSnapshot,
                error: accountError,
                sourceLabel: "fixture")
            accounts.append(account)
        }
        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts, healthyTailExpanded: true)
        return try #require(plan.rows.compactMap { row in
            if case let .compact(compact) = row, compact.accountID.opaqueID == "1" { return compact }
            return nil
        }.first)
    }

    static func model(
        _ row: AccountMenuLayoutPlanner.CompactRow,
        style: ResetTimeDisplayStyle = .countdown,
        now: Date = Self.now,
        hidePersonalInfo: Bool = false) -> MenuCardCompactAccountRowView.Model
    {
        MenuCardCompactAccountRowView.Model(
            row: row,
            resetTimeDisplayStyle: style,
            hidePersonalInfo: hidePersonalInfo,
            now: now)
    }
}

@MainActor
struct MenuCardCompactAccountRowTests {
    private typealias Fixture = CompactAccountResetFixtures

    @Test(arguments: [UsageProvider.deepseek, .kilo, .mimo, .neuralwatt, .mistral, .warp, .abacus])
    func `balance descriptions never become reset claims`(provider: UsageProvider) throws {
        let balance = Fixture.window(80, description: "$5.00 (Paid: $3.00 / Granted: $2.00)")
        let row = try Fixture.row(provider: provider, primary: balance)
        let model = Fixture.model(row)
        #expect(row.windowDetails.first?.resetPresentation == .hidden)
        #expect(model.detailLines.count == 1)
        #expect(!model.detailLines[0].contains(" · "))
        #expect(!model.accessibilityText.contains("$5.00"))
    }

    @Test
    func `provider reset suppression remains scoped to the primary window`() throws {
        let session = Fixture.window(70, after: 3600, description: "$5.00")
        let weekly = Fixture.window(89, after: 187_200)
        let row = try Fixture.row(provider: .manus, primary: session, weekly: weekly)
        let model = Fixture.model(row)
        #expect(row.windowDetails.map(\.resetPresentation) == [.standard, .hidden])
        #expect(try model.detailLines[0].hasSuffix(
            #require(UsageFormatter.resetLine(for: weekly, style: .countdown, now: Fixture.now))))
        #expect(!model.detailLines[1].contains(" · "))
    }

    @Test
    func `date backed balance quotas retain their authoritative reset`() throws {
        let window = Fixture.window(80, after: 3600, description: "$5.00")
        let row = try Fixture.row(provider: .kilo, primary: window)
        let model = Fixture.model(row)
        #expect(row.windowDetails.first?.resetPresentation == .standard)
        #expect(try model.detailLines[0].hasSuffix(
            #require(UsageFormatter.resetLine(for: window, style: .countdown, now: Fixture.now))))
        #expect(!model.detailLines[0].contains("$5.00"))
    }

    @Test
    func `reset visibility follows the provider secondary window requirement`() throws {
        let primary = Fixture.window(80, after: 3600)
        let withoutSecondary = try Fixture.row(provider: .crof, primary: primary)
        let withSecondary = try Fixture.row(provider: .crof, primary: primary, weekly: Fixture.window(0))
        #expect(withoutSecondary.windowDetails.first?.resetPresentation == .hidden)
        #expect(withSecondary.windowDetails.first?.resetPresentation == .standard)
    }

    @Test(arguments: [UsageProvider.openrouter, .sub2api])
    func `provider owned description is displayed without adding a reset prefix`(provider: UsageProvider) throws {
        let row = try Fixture.row(provider: provider, primary: Fixture.window(80, description: "  Quota detail  "))
        let model = Fixture.model(row)
        #expect(row.windowDetails.first?.resetPresentation == .providerDescription)
        #expect(model.detailLines[0].hasSuffix(" · Quota detail"))
        #expect(!model.detailLines[0].contains("Resets"))
        let blank = try Fixture.model(Fixture.row(provider: provider, primary: Fixture.window(80, description: "  ")))
        #expect(!blank.detailLines[0].contains(" · "))
    }

    @Test(arguments: [nil, "  "] as [String?])
    func `optional provider description preserves a dated reset when empty`(description: String?) throws {
        let window = Fixture.window(80, after: 3600, description: description)
        let row = try Fixture.row(provider: .openrouter, primary: window)
        #expect(row.windowDetails.first?.resetPresentation == .standard)
        #expect(try Fixture.model(row).detailLines[0].hasSuffix(
            #require(UsageFormatter.resetLine(for: window, style: .countdown, now: Fixture.now))))
    }

    @Test
    func `weekly constraint retains its own reset despite earlier session and other account resets`() throws {
        let weekly = Fixture.window(89, after: 187_200)
        let row = try Fixture.row(primary: Fixture.window(2, after: 3600), weekly: weekly)
        #expect(row.headroomPercent == 11)
        #expect(row.windowDetails.map(\.label) == ["Weekly"])
        #expect(row.windowDetails.map(\.window) == [weekly])
        let model = Fixture.model(row)
        #expect(model.detailLines.count == 1)
        #expect(model.detailLines[0].contains("11%"))
        let reset = try #require(UsageFormatter.resetLine(for: weekly, style: .countdown, now: Fixture.now))
        #expect(model.detailLines[0].hasSuffix(reset))
        #expect(model.accessibilityText.contains(reset))
    }

    @Test
    func `multiple constrained windows keep distinct reset lines in headroom order`() throws {
        let session = Fixture.window(60, after: 3600)
        let weekly = Fixture.window(99, after: 172_800)
        let row = try Fixture.row(primary: session, weekly: weekly)
        #expect(row.windowDetails.map(\.window) == [weekly, session])
        let model = Fixture.model(row)
        #expect(model.detailLines.count == 2)
        for (line, window) in zip(model.detailLines, [weekly, session]) {
            let reset = try #require(UsageFormatter.resetLine(for: window, style: .countdown, now: Fixture.now))
            #expect(line.hasSuffix(reset))
        }
    }

    @Test
    func `healthy accounts show their least remaining window and reset`() throws {
        let weekly = Fixture.window(1, after: 172_800)
        let row = try Fixture.row(primary: Fixture.window(0, after: 3600), weekly: weekly)
        #expect(row.severity == .healthy)
        #expect(row.windowDetails.map(\.window) == [weekly])
        #expect(Fixture.model(row).detailLines.count == 1)
    }

    @Test
    func `unknown reset does not borrow another window or account time`() throws {
        let row = try Fixture.row(primary: Fixture.window(0, after: 3600), weekly: Fixture.window(99))
        let model = Fixture.model(row)
        #expect(model.detailLines.count == 1)
        #expect(!model.detailLines[0].contains(" · "))
        #expect(row.windowDetails.first?.window.resetsAt == nil)
    }

    @Test
    func `provider text fallback and absolute style match full card formatting`() throws {
        let window = Fixture.window(89, after: 9000, description: "in 9h")
        let row = try Fixture.row(weekly: window)
        let countdown = Fixture.model(row)
        let absolute = Fixture.model(row, style: .absolute)
        #expect(countdown.detailLines != absolute.detailLines)
        let reset = try #require(UsageMenuCardView.Model.resetText(for: window, style: .absolute, now: Fixture.now))
        #expect(absolute.detailLines[0].hasSuffix(reset))
        #expect(countdown.heightFingerprint != absolute.heightFingerprint)

        let fallback = Fixture.window(89, description: "Resets in 4h")
        let fallbackModel = try Fixture.model(Fixture.row(weekly: fallback))
        let fallbackText = try #require(UsageFormatter.resetLine(for: fallback, style: .countdown, now: Fixture.now))
        #expect(fallbackModel.detailLines[0].hasSuffix(fallbackText))
    }

    @Test
    func `elapsed reset renders now without projecting another period`() throws {
        let window = Fixture.window(100, after: 60)
        let row = try Fixture.row(weekly: window)
        let before = Fixture.model(row)
        let now = Fixture.now.addingTimeInterval(61)
        let after = Fixture.model(row, now: now)
        #expect(before.detailLines != after.detailLines)
        #expect(before.heightFingerprint != after.heightFingerprint)
        let reset = try #require(UsageFormatter.resetLine(for: window, style: .countdown, now: now))
        #expect(after.detailLines[0].hasSuffix(reset))
        #expect(row.windowDetails.first?.window.resetsAt == window.resetsAt)
    }

    @Test
    func `synthetic session and unknown extra quota do not replace a reported window`() throws {
        let weekly = Fixture.window(10, after: 172_800)
        let row = try Fixture.row(
            primary: Fixture.window(100, after: 60, synthetic: true),
            weekly: weekly,
            extras: [NamedRateWindow(
                id: "unknown",
                title: "Unknown model",
                window: Fixture.window(100, after: 30),
                usageKnown: false)])
        #expect(row.headroomPercent == 90)
        #expect(row.windowDetails.map(\.window) == [weekly])
    }

    @Test
    func `monthly and scoped quotas retain labels and authoritative resets`() throws {
        let monthly = Fixture.window(90, after: 2_592_000)
        let scoped = Fixture.window(99, after: 604_800)
        let row = try Fixture.row(monthly: monthly, extras: [NamedRateWindow(
            id: "scoped", title: "Example model only", window: scoped)])
        #expect(row.windowDetails.map(\.label) == ["Example model", "Monthly"])
        #expect(row.windowDetails.map(\.window) == [scoped, monthly])
    }

    @Test
    func `unavailable account retains error presentation without a fabricated reset`() throws {
        let model = try Fixture.model(Fixture.row(error: "Unavailable"))
        #expect(model.hasError)
        #expect(model.detailLines.isEmpty)
        #expect(model.headroomLabel == nil)
        #expect(model.accessibilityText.contains(L("Account unavailable")))
    }

    @Test
    func `quota labels are localized and privacy mode also redacts reset prose`() throws {
        let row = try Fixture.row(weekly: Fixture.window(89, description: "tomorrow for owner@example.com"))
        try CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            let model = Fixture.model(row, hidePersonalInfo: true)
            let line = try #require(model.detailLines.first)
            #expect(line.hasPrefix("Wöchentlich "))
            #expect(!model.accessibilityText.contains("@example.com"))
            #expect(model.label.isEmpty)
        }
    }
}

@MainActor
final class CompactAccountResetRenderTests: XCTestCase {
    func test_renderResetRows() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACCOUNT_RESET_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ACCOUNT_RESET_SCREENSHOT_DIR to render compact reset rows.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        typealias Fixture = CompactAccountResetFixtures
        let rows = try [
            Fixture.row(weekly: Fixture.window(99, after: 604_800)),
            Fixture.row(primary: Fixture.window(64, after: 9000), weekly: Fixture.window(89, after: 187_200)),
            Fixture.row(weekly: Fixture.window(1, after: 172_800)),
            Fixture.row(weekly: Fixture.window(99)),
        ]
        for language in ["en", "de"] {
            try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                UsageFormatter.setLocalizationProvider { L($0, language: language) }
                UsageFormatter.setLocaleProvider { Locale(identifier: language == "de" ? "de_DE" : "en_US") }
                defer {
                    UsageFormatter.clearLocalizationProvider()
                    UsageFormatter.clearLocaleProvider()
                }
                for style in [ResetTimeDisplayStyle.countdown, .absolute] {
                    for width in [CGFloat(280), CGFloat(360)] {
                        let view = VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                MenuCardCompactAccountRowView(
                                    model: Fixture.model(row, style: style),
                                    progressColor: .cyan,
                                    width: width)
                            }
                        }.background(Color(nsColor: .windowBackgroundColor))
                        let hosting = NSHostingView(rootView: view)
                        hosting.appearance = NSAppearance(named: .darkAqua)
                        let size = hosting.fittingSize
                        XCTAssertEqual(size.width, width, accuracy: 1)
                        XCTAssertGreaterThan(size.height, 100)
                        hosting.frame = CGRect(origin: .zero, size: size)
                        hosting.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        let file = directory
                            .appendingPathComponent("compact-resets-\(language)-\(style)-\(Int(width)).png")
                        try data.write(to: file)
                        print("Rendered \(file.path), \(size)")
                    }
                }
            }
        }
    }
}
