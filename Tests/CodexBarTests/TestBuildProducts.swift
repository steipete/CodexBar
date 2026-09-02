import Foundation

enum TestBuildProducts {
    static func executableURL(named name: String) -> URL {
        // Scratch and release builds must launch their own products, not stale checkout helpers.
        Bundle(for: TestBundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
    }
}

private final class TestBundleMarker: NSObject {}
