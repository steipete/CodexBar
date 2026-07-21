import Foundation
import Testing
@testable import CodexBarCore

extension AntigravityStatusProbeTests {
    @Test
    func `remote source collapses recognized family models and hides unconsumed junk`() throws {
        // Fixture B: verified 13 remote models; recognized text models collapse into Gemini,
        // and unconsumed junk stays hidden.
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                // junk: image
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Image",
                    modelId: "gemini-2-5-flash-image",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: tab autocomplete
                AntigravityModelQuota(
                    label: "Tab Flash Lite Vertex",
                    modelId: "tab_flash_lite_vertex",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelId: "gemini-2-5-pro",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "gemini-3-pro-high",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: lite
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Lite",
                    modelId: "gemini-2-5-flash-lite",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: image
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: lite
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "gemini-3-1-pro-low",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "gemini-3-1-pro-high",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: tab autocomplete
                AntigravityModelQuota(
                    label: "Tab Jump Flash Lite Vertex",
                    modelId: "tab_jump_flash_lite_vertex",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash",
                    modelId: "gemini-2-5-flash",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 100)
        #expect(usage.secondary == nil)
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `remote source shows consumed junk models despite filter`() throws {
        // Fixture C: junk models with remainingFraction < 0.999 must be shown
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                // consumed tab - should be shown
                AntigravityModelQuota(
                    label: "Tab Flash Lite Vertex",
                    modelId: "tab_flash_lite_vertex",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
                // consumed image - should be shown
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
                // unconsumed sibling tab (0.9995 >= 0.999) - should be hidden
                AntigravityModelQuota(
                    label: "Tab Jump Flash Lite Vertex",
                    modelId: "tab_jump_flash_lite_vertex",
                    remainingFraction: 0.9995,
                    resetTime: nil,
                    resetDescription: nil),
                // a clean survivor for non-empty guard
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extraWindows = try #require(usage.extraRateWindows)
        let ids = extraWindows.map(\.id)

        // Consumed junk models shown despite being junk type
        #expect(ids.contains("tab_flash_lite_vertex"))
        #expect(ids.contains("gemini-3-pro-image"))

        // Unconsumed sibling stays hidden
        #expect(!ids.contains("tab_jump_flash_lite_vertex"))
    }

    @Test
    func `remote source image models do not drive family summary bars`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 0.2,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "gemini-3-pro-high",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash Image",
                    modelId: "gemini-3-flash-image",
                    remainingFraction: 0.1,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.secondary == nil)
        #expect(usage.extraRateWindows?.map(\.id).contains("gemini-3-pro-image") == true)
        #expect(usage.extraRateWindows?.map(\.id).contains("gemini-3-flash-image") == true)
    }

    @Test
    func `remote source yields nil extra windows when all models are unconsumed junk`() throws {
        // Fixture D: all-junk-unconsumed -> extraRateWindows nil
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Tab Flash Lite Vertex",
                    modelId: "tab_flash_lite_vertex",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Lite",
                    modelId: "gemini-2-5-flash-lite",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Unknown Model X",
                    modelId: "unknown-model-x",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `ordering edge cases collapse to most constrained usage pool`() throws {
        // Fixture F: local source; known Gemini Pro rows collapse into the Gemini pool
        // using the most constrained remaining fraction.
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M70",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M71",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini Pro Experimental",
                    modelId: "MODEL_PLACEHOLDER_M72",
                    remainingFraction: 0.3,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4",
                    modelId: "MODEL_PLACEHOLDER_M73",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 30)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let claudeWindow = try #require(extra.first(where: { $0.id == "MODEL_PLACEHOLDER_M73" }))
        #expect(claudeWindow.window.remainingPercent.rounded() == 90)
    }

    @Test
    func `nil version unknown family models sort deterministically by label`() throws {
        // Strict-weak-ordering guard: two .unknown models with unparseable versions
        // should sort by label without trapping
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Zebra Unknown Model",
                    modelId: "MODEL_PLACEHOLDER_MA",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Alpha Unknown Model",
                    modelId: "MODEL_PLACEHOLDER_MB",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        let extraWindows = try #require(usage.extraRateWindows)
        let titles = extraWindows.map(\.title)

        // Deterministic: label tiebreaker -> Alpha before Zebra
        #expect(titles == ["Alpha Unknown Model", "Zebra Unknown Model"])
    }

    @Test
    func `hyphenated raw model ids without display name still map to gemini group`() throws {
        // When the remote catalog omits displayName/label, the raw hyphenated model id
        // becomes the label and still participates in the Gemini group.
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "gemini-3-pro-preview",
                    modelId: "gemini-3-pro-preview",
                    remainingFraction: 1,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "gemini-2.5-pro",
                    modelId: "gemini-2.5-pro",
                    remainingFraction: 1,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 100)
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `http probe errors still count as reachable`() {
        #expect(
            AntigravityStatusProbe.isReachableProbeError(
                AntigravityStatusProbeError.apiError("HTTP 403: Forbidden")))
        #expect(
            AntigravityStatusProbe.isReachableProbeError(
                AntigravityStatusProbeError.apiError("HTTP 404: Not Found")))
        #expect(
            !AntigravityStatusProbe.isReachableProbeError(
                AntigravityStatusProbeError.apiError("Invalid response")))
        #expect(!AntigravityStatusProbe.isReachableProbeError(AntigravityStatusProbeError.notRunning))
    }

    @Test
    func `fallback probe port prefers non extension candidate`() {
        #expect(
            AntigravityStatusProbe.fallbackProbePort(
                ports: [51170, 61775],
                extensionPort: 61775) == 51170)
        #expect(
            AntigravityStatusProbe.fallbackProbePort(
                ports: [61775],
                extensionPort: 61775) == 61775)
        #expect(
            AntigravityStatusProbe.fallbackProbePort(
                ports: [51170, 61775],
                extensionPort: nil) == 51170)
    }
}
