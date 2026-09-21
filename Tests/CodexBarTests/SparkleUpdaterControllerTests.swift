import Foundation
import Sparkle
import Testing
@testable import CodexBar

@MainActor
struct SparkleUpdaterControllerTests {
    @Test
    func `staged background updates leave Sparkle free to present a manual check`() async throws {
        let fixture = self.makeFixture()
        var immediateInstallWasCalled = false

        let handlesInstallation = fixture.subject.updater(
            fixture.updater,
            willInstallUpdateOnQuit: .empty(),
            immediateInstallationBlock: { immediateInstallWasCalled = true })

        #expect(!handlesInstallation)
        try await self.expectUpdateReady(true, in: fixture.subject)
        #expect(!immediateInstallWasCalled)
    }

    @Test(arguments: [SPUUserUpdateStage.downloaded, .installing])
    func `dismissing a staged update preserves the menu reminder`(stage: SPUUserUpdateStage) async throws {
        let fixture = self.makeFixture()
        let state = try self.makeState(stage: stage)

        fixture.subject.updater(fixture.updater, userDidMake: .dismiss, forUpdate: .empty(), state: state)

        try await self.expectUpdateReady(true, in: fixture.subject)
    }

    @Test
    func `dismissing an undownloaded update clears a stale menu reminder`() async throws {
        let fixture = self.makeFixture(isUpdateReady: true)
        let state = try self.makeState(stage: .notDownloaded)

        fixture.subject.updater(fixture.updater, userDidMake: .dismiss, forUpdate: .empty(), state: state)

        try await self.expectUpdateReady(false, in: fixture.subject)
    }

    @Test(arguments: [SPUUserUpdateChoice.install, .skip], [SPUUserUpdateStage.downloaded, .installing])
    func `installing or skipping a staged update clears its menu reminder`(
        choice: SPUUserUpdateChoice,
        stage: SPUUserUpdateStage) async throws
    {
        let fixture = self.makeFixture(isUpdateReady: true)
        let state = try self.makeState(stage: stage)

        fixture.subject.updater(fixture.updater, userDidMake: choice, forUpdate: .empty(), state: state)

        try await self.expectUpdateReady(false, in: fixture.subject)
    }

    @Test
    func `an aborted update clears its menu reminder`() async throws {
        let fixture = self.makeFixture(isUpdateReady: true)

        fixture.subject.updater(
            fixture.updater,
            didAbortWithError: NSError(domain: "SparkleUpdaterControllerTests", code: 1))

        try await self.expectUpdateReady(false, in: fixture.subject)
    }

    @Test
    func `a failed download clears its menu reminder`() async throws {
        let fixture = self.makeFixture(isUpdateReady: true)

        fixture.subject.updater(
            fixture.updater,
            failedToDownloadUpdate: .empty(),
            error: NSError(domain: "SparkleUpdaterControllerTests", code: 1))

        try await self.expectUpdateReady(false, in: fixture.subject)
    }

    @Test
    func `a cancelled download clears its menu reminder`() async throws {
        let fixture = self.makeFixture(isUpdateReady: true)

        fixture.subject.userDidCancelDownload(fixture.updater)

        try await self.expectUpdateReady(false, in: fixture.subject)
    }

    private func makeFixture(isUpdateReady: Bool = false)
        -> (subject: SparkleUpdaterController, updater: SPUUpdater)
    {
        let subject = SparkleUpdaterController(savedAutoUpdate: false, startingUpdater: false)
        subject.updateStatus.isUpdateReady = isUpdateReady
        let sparkle = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        return (subject, sparkle.updater)
    }

    private func makeState(stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        // Sparkle exposes state construction through NSSecureCoding; these are its archive keys.
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        #expect(state.stage == stage)
        #expect(state.userInitiated)
        return state
    }

    private func expectUpdateReady(_ expected: Bool, in subject: SparkleUpdaterController) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while subject.updateStatus.isUpdateReady != expected, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(subject.updateStatus.isUpdateReady == expected)
    }
}
