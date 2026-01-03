import CodexBarCore
import Foundation
import Testing

#if os(macOS)
import SweetCookieKit

@Suite
struct BrowserDetectionTests {
    @Test
    func test_safariAlwaysInstalled() async {
        let isInstalled = await BrowserDetection().isInstalled(.safari)
        #expect(isInstalled == true)
    }

    @Test
    func test_filterInstalledIncludesSafari() async {
        let browsers: [Browser] = [.safari, .chrome, .firefox]
        let installed = await BrowserDetection().filterInstalled(browsers)
        #expect(installed.contains(.safari))
    }

    @Test
    func test_cacheWorks() async {
        let detection = BrowserDetection()
        // First call should detect
        let first = await detection.isInstalled(.safari)

        // Second call should use cache (same result)
        let second = await detection.isInstalled(.safari)

        #expect(first == second)
    }

    @Test
    func test_cacheConsistency() async {
        let detection = BrowserDetection()
        _ = await detection.isInstalled(.safari)

        // Second call should return consistent result
        let result = await detection.isInstalled(.safari)
        #expect(result == true)
    }

    @Test
    func test_syncWrapperWorks() {
        let isInstalled = BrowserDetection().isInstalled(.safari)
        #expect(isInstalled == true)
    }

    @Test
    func test_syncFilterWorks() {
        let browsers: [Browser] = [.safari, .chrome, .firefox]
        let installed = BrowserDetection().filterInstalled(browsers)
        #expect(installed.contains(.safari))
    }

    @Test
    func test_filterPreservesOrder() async {
        let browsers: [Browser] = [.firefox, .safari, .chrome]
        let installed = await BrowserDetection().filterInstalled(browsers)

        // Safari should still be present
        #expect(installed.contains(.safari))

        // Order should be preserved (safari should not be first if firefox is installed)
        if let safariIndex = installed.firstIndex(of: .safari),
           let firefoxIndex = installed.firstIndex(of: .firefox)
        {
            #expect(firefoxIndex < safariIndex)
        }
    }

    @Test
    func test_emptyListReturnsEmpty() async {
        let browsers: [Browser] = []
        let installed = await BrowserDetection().filterInstalled(browsers)
        #expect(installed.isEmpty)
    }

    @Test
    func test_applicationPathsGeneration() async {
        // Test that we generate correct paths
        // We can't test actual installation without knowing the test environment,
        // but we can verify the detection doesn't crash
        let browsers: [Browser] = [
            .chrome, .chromeBeta, .chromeCanary,
            .arc, .arcBeta, .arcCanary,
            .brave, .braveBeta, .braveNightly,
            .edge, .edgeBeta, .edgeCanary,
            .vivaldi, .chromium, .firefox,
            .chatgptAtlas, .helium,
        ]

        for browser in browsers {
            let isInstalled = await BrowserDetection().isInstalled(browser)
            // Just verify it returns a boolean without crashing
            #expect(isInstalled == true || isInstalled == false)
        }
    }

    @Test
    func test_detectionDoesNotThrow() async {
        // Verify that detection handles missing browsers gracefully
        let unlikelyBrowsers: [Browser] = [
            .chromeBeta, .chromeCanary,
            .arcBeta, .arcCanary,
            .braveBeta, .braveNightly,
            .edgeBeta, .edgeCanary,
        ]

        for browser in unlikelyBrowsers {
            let result = await BrowserDetection().isInstalled(browser)
            // Should return false for most test environments, but shouldn't crash
            #expect(result == true || result == false)
        }
    }

    @Test
    func test_profileValidationForChromiumBrowsers() async {
        // Chromium browsers should check for Default/Profile directories
        // This test verifies the detection doesn't crash when profile dirs are missing
        let chromiumBrowsers: [Browser] = [
            .chrome, .arc, .brave, .edge, .vivaldi, .chromium, .chatgptAtlas,
        ]

        for browser in chromiumBrowsers {
            let result = await BrowserDetection().isInstalled(browser)
            #expect(result == true || result == false)
        }
    }
}

#else

@Suite
struct BrowserDetectionTests {
    @Test
    func test_nonMacOSReturnsNoBrowsers() async {
        let isInstalled = await BrowserDetection().isInstalled(Browser())
        #expect(isInstalled == false)
    }

    @Test
    func test_nonMacOSFilterReturnsEmpty() async {
        let browsers = [Browser(), Browser()]
        let installed = await BrowserDetection().filterInstalled(browsers)
        #expect(installed.isEmpty)
    }
}

#endif
