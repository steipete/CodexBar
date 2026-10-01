import Testing
@testable import CodexBar

@MainActor
struct CloudSyncPushRegistrationTests {
    @Test(arguments: ["development", "production"])
    func `CloudKit builds with a valid push environment register for notifications`(_ environment: String) {
        var registrations = 0
        let canActivate = CloudSyncEntitlementGate.prepareForSync(
            enabled: true,
            entitlementValue: { name in
                name == CloudSyncEntitlementGate.entitlement ? ["CloudKit"] : environment
            },
            register: { registrations += 1 })
        #expect(canActivate)
        #expect(registrations == 1)
    }

    @Test(arguments: [nil, "", "Production", "sandbox"] as [String?])
    func `missing or invalid push entitlement never registers`(_ environment: String?) {
        var registrations = 0
        let canActivate = CloudSyncEntitlementGate.prepareForSync(
            enabled: true,
            entitlementValue: { name in
                name == CloudSyncEntitlementGate.entitlement ? ["CloudKit"] : environment
            },
            register: { registrations += 1 })
        #expect(canActivate)
        #expect(registrations == 0)
    }

    @Test
    func `push entitlement alone does not bypass the CloudKit capability gate`() {
        var registrations = 0
        let canActivate = CloudSyncEntitlementGate.prepareForSync(
            enabled: true,
            entitlementValue: { name in
                name == CloudSyncEntitlementGate.entitlement ? ["CloudDocuments"] : "production"
            },
            register: { registrations += 1 })
        #expect(!canActivate)
        #expect(registrations == 0)
    }

    @Test
    func `opting out before queued activation prevents registration and engine creation`() {
        var enabled = true
        var registrations = 0
        let activate = {
            CloudSyncEntitlementGate.prepareForSync(
                enabled: enabled,
                entitlementValue: { name in
                    name == CloudSyncEntitlementGate.entitlement ? ["CloudKit"] : "production"
                },
                register: { registrations += 1 })
        }
        enabled = false

        #expect(!activate())
        #expect(registrations == 0)
    }
}
