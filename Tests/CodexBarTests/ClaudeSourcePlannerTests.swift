import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ClaudeSourcePlannerTests {
    @Test
    func appAutoPlanPreservesOrderedStepsAndReasons() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true))

        #expect(plan.orderedSteps.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.orderedSteps.map(\.inclusionReason) == [
            .appAutoPreferredOAuth,
            .appAutoFallbackCLI,
            .appAutoFallbackWeb,
        ])
        #expect(plan.availableSteps.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.preferredStep?.dataSource == .oauth)
    }

    @Test
    func cliAutoPlanPreservesOrderedStepsAndReasons() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .cli,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: false))

        #expect(plan.orderedSteps.map(\.dataSource) == [.web, .cli])
        #expect(plan.orderedSteps.map(\.inclusionReason) == [
            .cliAutoPreferredWeb,
            .cliAutoFallbackCLI,
        ])
        #expect(plan.preferredStep?.dataSource == .web)
    }

    @Test
    func explicitModePlanIsSingleStep() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .cli,
            webExtrasEnabled: true,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false))

        #expect(plan.orderedSteps.count == 1)
        #expect(plan.orderedSteps.first?.dataSource == .cli)
        #expect(plan.orderedSteps.first?.inclusionReason == .explicitSourceSelection)
        #expect(plan.compatibilityStrategy == ClaudeUsageStrategy(dataSource: .cli, useWebExtras: true))
    }

    @Test
    func appAutoCLIFallbackReportsWebExtrasLikeRuntime() {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .auto,
            webExtrasEnabled: true,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false))

        #expect(plan.preferredStep?.dataSource == .cli)
        #expect(plan.compatibilityStrategy == ClaudeUsageStrategy(dataSource: .cli, useWebExtras: true))
    }

    @Test
    func noSourcePlannerOutputIsDeterministic() {
        let input = ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: false,
            hasCLI: false,
            hasOAuthCredentials: false)
        let plan = ClaudeSourcePlanner.resolve(input: input)

        #expect(plan.orderedSteps.map(\.dataSource) == [.oauth, .cli, .web])
        #expect(plan.availableSteps.isEmpty)
        #expect(plan.isNoSourceAvailable)
        #expect(plan.preferredStep == nil)
        #expect(plan.executionSteps.isEmpty)
        #expect(plan.debugLines() == [
            "planner_order=oauth→cli→web",
            "planner_selected=none",
            "planner_no_source=true",
            "planner_step.oauth=unavailable reason=app-auto-preferred-oauth",
            "planner_step.cli=unavailable reason=app-auto-fallback-cli",
            "planner_step.web=unavailable reason=app-auto-fallback-web",
        ])
    }
}
