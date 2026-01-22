import CodexBarCore
import Testing

@Suite
struct JetBrainsIDEDetectorTests {
    @Test
    func parsesIDEDirectoryCaseInsensitive() {
        let info = JetBrainsIDEDetector._parseIDEDirectoryForTesting(
            dirname: "Webstorm2024.1",
            basePath: "/test")

        #expect(info?.name == "WebStorm")
        #expect(info?.version == "2024.1")
        #expect(info?.basePath == "/test/Webstorm2024.1")
    }
}
