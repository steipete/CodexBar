import CodexBarCore
import XCTest
@testable import CodexBarCLI

final class DeepSeekCLISourceModeTests: XCTestCase {
    func test_manualWebSessionDoesNotRequireBrowserSupportOnLinuxCLI() {
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .deepseek,
            settings: ProviderSettingsSnapshot.make(
                deepseek: .init(cookieSource: .manual, manualCookieHeader: "session=manual"))))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .deepseek,
            environment: ["DEEPSEEK_PLATFORM_SESSION": "Bearer eyJ.test"]))
        XCTAssertFalse(CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .deepseek,
            environment: ["DEEPSEEK_API_KEY": "sk-test"]))
        XCTAssertTrue(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .deepseek,
            settings: ProviderSettingsSnapshot.make(
                deepseek: .init(cookieSource: .off, manualCookieHeader: nil))))
    }
}
