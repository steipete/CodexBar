import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct StorageBreakdownSegmentTests {
    @Test @MainActor
    func `folds overflow into eighth segment without losing paths`() {
        let components = (1...10).map { index in
            ProviderStorageFootprint.Component(path: "/tmp/item-\(index)", totalBytes: Int64(index))
        }
        let view = StorageBreakdownMenuView(
            footprint: Self.footprint(components: components),
            width: 310)

        #expect(view._segmentNamesForTesting == [
            "item-1", "item-2", "item-3", "item-4", "item-5", "item-6", "item-7", "Other (3 items)",
        ])
        #expect(view._segmentBytesForTesting == [1, 2, 3, 4, 5, 6, 7, 27])
        #expect(view._overflowNamesForTesting == ["item-8", "item-9", "item-10"])
        #expect(view._overflowExpansionHeightForTesting == 68)
        #expect(view.copyablePaths == components.map(\.path))
    }

    @Test @MainActor
    func `segment widths fill bar and keep tiny values visible`() {
        let components = [
            ProviderStorageFootprint.Component(path: "/tmp/large", totalBytes: 1_000_000),
            ProviderStorageFootprint.Component(path: "/tmp/tiny", totalBytes: 1),
            ProviderStorageFootprint.Component(path: "/tmp/zero", totalBytes: 0),
        ]
        let view = StorageBreakdownMenuView(
            footprint: Self.footprint(components: components),
            width: 310)
        let widths = view._segmentWidthsForTesting(barWidth: 100)

        #expect(widths.count == 3)
        #expect(abs(widths.reduce(0, +) - 100) < 0.001)
        #expect(widths.allSatisfy { $0 >= 2 })
    }

    @Test @MainActor
    func `narrow bar divides width without overflow`() {
        let components = (1...8).map { index in
            ProviderStorageFootprint.Component(path: "/tmp/item-\(index)", totalBytes: 1)
        }
        let view = StorageBreakdownMenuView(
            footprint: Self.footprint(components: components),
            width: 310)
        let widths = view._segmentWidthsForTesting(barWidth: 8)

        #expect(widths == Array(repeating: 1, count: 8))
        #expect(widths.reduce(0, +) == 8)
    }

    @Test @MainActor
    func `zero byte components evenly fill bar`() {
        let components = (1...4).map { index in
            ProviderStorageFootprint.Component(path: "/tmp/item-\(index)", totalBytes: 0)
        }
        let view = StorageBreakdownMenuView(
            footprint: Self.footprint(components: components),
            width: 310)

        #expect(view._segmentWidthsForTesting(barWidth: 100) == [25, 25, 25, 25])
    }

    @Test @MainActor
    func `negative component sizes clamp to zero`() {
        let components = [
            ProviderStorageFootprint.Component(path: "/tmp/negative", totalBytes: -10),
            ProviderStorageFootprint.Component(path: "/tmp/positive", totalBytes: 10),
        ]
        let view = StorageBreakdownMenuView(
            footprint: Self.footprint(components: components),
            width: 310)

        #expect(view._segmentBytesForTesting == [0, 10])
        #expect(view._segmentWidthsForTesting(barWidth: 100).allSatisfy { $0 >= 2 })
    }

    @Test @MainActor
    func `extreme component sizes still fill exactly one bar`() {
        let components = [
            ProviderStorageFootprint.Component(path: "/tmp/first", totalBytes: .max),
            ProviderStorageFootprint.Component(path: "/tmp/second", totalBytes: .max),
        ]
        let view = StorageBreakdownMenuView(
            footprint: Self.footprint(components: components),
            width: 310)
        let widths = view._segmentWidthsForTesting(barWidth: 100)

        #expect(abs(widths.reduce(0, +) - 100) < 0.001)
        #expect(widths == [50, 50])
    }

    private static func footprint(
        components: [ProviderStorageFootprint.Component]) -> ProviderStorageFootprint
    {
        ProviderStorageFootprint(
            provider: .claude,
            totalBytes: components.reduce(Int64(0)) { partial, component in
                let (sum, overflowed) = partial.addingReportingOverflow(max(component.totalBytes, 0))
                return overflowed ? .max : sum
            },
            paths: components.map(\.path),
            missingPaths: [],
            unreadablePaths: [],
            components: components,
            updatedAt: Date(timeIntervalSince1970: 0))
    }
}
