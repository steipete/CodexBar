import CodexBarCore
import Testing

struct JetBrainsIDEDetectorTests {
    @Test
    func `parses IDE directory case insensitive`() {
        let info = JetBrainsIDEDetector._parseIDEDirectoryForTesting(
            dirname: "Webstorm2024.1",
            basePath: "/test")

        #expect(info?.name == "WebStorm")
        #expect(info?.version == "2024.1")
        #expect(info?.basePath == "/test/Webstorm2024.1")
    }
}
