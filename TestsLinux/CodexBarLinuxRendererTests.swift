import Foundation
import Testing
@testable import CodexBarLinux

struct CodexBarLinuxRendererTests {
    @Test
    func renderer_buildsDashboardCardsAndWaybarSummary() throws {
        let json = """
        [
          {
            "provider": "codex",
            "account": "user@example.com",
            "version": "1.2.3",
            "source": "codex-cli",
            "status": null,
            "usage": {
              "primary": {
                "usedPercent": 25,
                "windowMinutes": 300,
                "resetsAt": "2026-03-25T12:00:00Z",
                "resetDescription": null
              },
              "secondary": {
                "usedPercent": 40,
                "windowMinutes": 10080,
                "resetsAt": "2026-03-30T12:00:00Z",
                "resetDescription": null
              },
              "tertiary": null,
              "updatedAt": "2026-03-25T10:00:00Z",
              "identity": {
                "providerID": "codex",
                "accountEmail": "user@example.com",
                "accountOrganization": null,
                "loginMethod": "plus"
              },
              "accountEmail": "user@example.com",
              "accountOrganization": null,
              "loginMethod": "plus"
            },
            "credits": {
              "remaining": 112.4,
              "events": [],
              "updatedAt": "2026-03-25T10:00:00Z"
            },
            "antigravityPlanInfo": null,
            "openaiDashboard": null,
            "error": null
          },
          {
            "provider": "claude",
            "account": null,
            "version": null,
            "source": "web",
            "status": null,
            "usage": null,
            "credits": null,
            "antigravityPlanInfo": null,
            "openaiDashboard": null,
            "error": {
              "code": 1,
              "message": "Missing cookies",
              "kind": "runtime"
            }
          }
        ]
        """

        let payloads = try LinuxDashboardPayloadCodec.decodePayloads(json)
        let snapshot = LinuxDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_774_445_200),
            providers: payloads)

        let html = LinuxDashboardRenderer.renderHTML(
            snapshot: snapshot,
            refreshSeconds: 60,
            outputDirectory: URL(fileURLWithPath: "/tmp/codexbar-linux", isDirectory: true))

        #expect(html.contains("CodexBar Linux"))
        #expect(html.contains("Codex"))
        #expect(html.contains("75% left"))
        #expect(html.contains("112.4 left"))
        #expect(html.contains("Missing cookies"))
        #expect(snapshot.waybarText == "CB !1")
        #expect(snapshot.waybarTooltip.contains("Codex: 75% restante"))
    }

    @Test
    func backend_decodesCliErrorPayload() throws {
        let raw = LinuxDashboardPayloadCodec.errorPayload(
            from: .nonZeroExit(code: 3, stderr: "selected source requires web support"))
        let payloads = try LinuxDashboardPayloadCodec.decodePayloads(raw)

        #expect(payloads.count == 1)
        #expect(payloads[0].provider == "cli")
        #expect(payloads[0].error?.message.contains("selected source requires web support") == true)
    }
}
