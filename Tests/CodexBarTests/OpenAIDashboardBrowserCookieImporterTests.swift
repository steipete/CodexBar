import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIDashboardBrowserCookieImporterTests {
    @Test
    func `shared deadline clamps each local timeout to remaining budget`() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = start.addingTimeInterval(30)

        let remaining = try OpenAIDashboardBrowserCookieImporter.remainingTimeout(
            until: deadline,
            cappedAt: 10,
            now: start.addingTimeInterval(27))

        #expect(remaining == 3)
    }

    @Test
    func `shared deadline preserves smaller local timeout`() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = start.addingTimeInterval(30)

        let remaining = try OpenAIDashboardBrowserCookieImporter.remainingTimeout(
            until: deadline,
            cappedAt: 10,
            now: start.addingTimeInterval(5))

        #expect(remaining == 10)
    }

    @Test
    func `expired shared deadline throws structured timeout`() {
        let deadline = Date(timeIntervalSinceReferenceDate: 1000)

        do {
            _ = try OpenAIDashboardBrowserCookieImporter.remainingTimeout(
                until: deadline,
                now: deadline)
            Issue.record("Expected deadline timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `mismatch error mentions source label`() {
        let err = OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
            found: [
                .init(sourceLabel: "Safari", email: "a@example.com"),
                .init(sourceLabel: "Chrome", email: "b@example.com"),
            ])
        let msg = err.localizedDescription
        #expect(msg.contains("Safari=a@example.com"))
        #expect(msg.contains("Chrome=b@example.com"))
    }

    @Test
    func `timed out persistent validation keeps verified session`() {
        #expect(OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: URLError(.timedOut)))
    }

    @Test
    func `non-timeout persistent validation failures are not trusted`() {
        #expect(!OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: OpenAIDashboardBrowserCookieImporter.ImportError.dashboardStillRequiresLogin))
    }
}
