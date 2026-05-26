import ServiceManagement
import Testing
@testable import CodexBar

@MainActor
struct LaunchAtLoginManagerTests {
    @Test
    func `set enabled skips registration when service is already enabled`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            true,
            status: { .enabled },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set enabled registers when service is not enabled`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            true,
            status: { .notRegistered },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 1)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set disabled unregisters when service is enabled`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .enabled },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 1)
    }

    @Test
    func `set disabled unregisters when service requires approval`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .requiresApproval },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 1)
    }

    @Test
    func `set disabled skips unregister when service is not registered`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .notRegistered },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 0)
    }
}
