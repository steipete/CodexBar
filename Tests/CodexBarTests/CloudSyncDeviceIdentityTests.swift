import Foundation
import Testing
@testable import CodexBar

struct CloudSyncDeviceIdentityTests {
    @Test
    func `a persisted identifier is kept so existing fleets stay addressable`() {
        let resolved = CloudSyncDeviceIdentity.resolve(
            persisted: "kept",
            hardwareUUID: Self.hardwareUUID)

        #expect(resolved == "kept")
    }

    @Test
    func `a fresh install derives the same identifier from the same hardware`() {
        let first = CloudSyncDeviceIdentity.resolve(persisted: nil, hardwareUUID: Self.hardwareUUID)
        let second = CloudSyncDeviceIdentity.resolve(persisted: "", hardwareUUID: Self.hardwareUUID)

        #expect(first == second)
        #expect(first != CloudSyncDeviceIdentity.resolve(persisted: nil, hardwareUUID: "OTHER-HARDWARE"))
        #expect(first != Self.hardwareUUID.lowercased())
        #expect(UUID(uuidString: first) != nil)
    }

    @Test
    func `a missing hardware UUID falls back to a random identifier`() {
        let first = CloudSyncDeviceIdentity.resolve(persisted: nil, hardwareUUID: nil)
        let second = CloudSyncDeviceIdentity.resolve(persisted: nil, hardwareUUID: nil)

        #expect(first != second)
        #expect(UUID(uuidString: first) != nil)
    }

    private static let hardwareUUID = "3F7964F9-C5A6-39D4-942D-02750C0980E0"
}
