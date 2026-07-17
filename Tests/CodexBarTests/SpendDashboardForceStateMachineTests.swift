import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardForceStateMachineTests {
    @Test
    func `A forced failures dominate stale capture and retain only trusted old rows`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let latest = Self.configuration(owner: "owner", revision: "L")
        let oldInputs = [
            Self.input(id: "claude", provider: .claude, cost: 3),
            Self.input(id: "codex:a", provider: .codex, cost: 5),
        ]
        let failedIDs: Set = ["claude", "codex:a"]
        let builder = SpendDashboardBuildScript([
            .init(mode: .refreshMissing, request: Self.request(initial, mode: .refreshMissing)),
            .init(
                mode: .forceRefresh,
                request: Self.request(
                    initial,
                    mode: .forceRefresh,
                    codexAccount: true)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    latest,
                    mode: .captureOnly,
                    inputs: [
                        Self.input(id: "claude", provider: .claude, cost: 90),
                        Self.input(id: "codex:a", provider: .codex, cost: 90),
                    ])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: oldInputs, failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForLoader(loader)
        controller.update(configuration: latest)
        await loader.resume(SpendDashboardLoadResult(inputs: [], failedSourceIDs: failedIDs))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly])
        #expect(await loader.forces == [false, true])
        #expect(controller.failedSourceCount == 2)
        #expect(controller.model.groups.first?.totalCost == 8)
    }

    @Test
    func `B capture drift wins for providers while forced Codex success carries`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let latest = Self.configuration(owner: "owner", revision: "L")
        let builder = SpendDashboardBuildScript([
            .init(
                mode: .forceRefresh,
                request: Self.request(
                    initial,
                    mode: .forceRefresh,
                    confirmedEmptySourceIDs: ["claude"],
                    codexAccount: true)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    latest,
                    mode: .captureOnly,
                    inputs: [Self.input(id: "claude", provider: .claude, cost: 7)])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial, force: true)
        await Self.waitForLoader(loader)
        controller.update(configuration: latest)
        await loader.resume(SpendDashboardLoadResult(
            inputs: [Self.input(id: "codex:a", provider: .codex, cost: 5)],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [.forceRefresh, .captureOnly])
        #expect(await loader.forces == [true])
        #expect(controller.configuration == latest)
        #expect(controller.model.groups.first?.totalCost == 12)
    }

    @Test
    func `C same owner barrier churn repeats capture only and preserves failures`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let first = Self.configuration(owner: "owner", revision: "L")
        let second = Self.configuration(owner: "owner", revision: "M")
        let third = Self.configuration(owner: "owner", revision: "N")
        let latest = Self.configuration(owner: "owner", revision: "O")
        let firstCaptureGate = SpendDashboardStateBuildGate()
        let secondCaptureGate = SpendDashboardStateBuildGate()
        let thirdCaptureGate = SpendDashboardStateBuildGate()
        let builder = SpendDashboardBuildScript([
            .init(mode: .forceRefresh, request: Self.request(initial, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    first,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"]),
                gate: firstCaptureGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    second,
                    mode: .captureOnly,
                    unavailableSourceIDs: ["claude"]),
                gate: secondCaptureGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    third,
                    mode: .captureOnly,
                    inputs: [Self.input(id: "claude", provider: .claude, cost: 3)]),
                gate: thirdCaptureGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    latest,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial, force: true)
        await Self.waitForLoader(loader)
        controller.update(configuration: first)
        await loader.resume(SpendDashboardLoadResult(inputs: [], failedSourceIDs: ["openai"]))
        await Self.waitForBuildGate(firstCaptureGate)
        controller.update(configuration: second)
        await firstCaptureGate.resume()
        await Self.waitForBuildGate(secondCaptureGate)
        controller.update(configuration: third)
        await secondCaptureGate.resume()
        await Self.waitForBuildGate(thirdCaptureGate)
        controller.update(configuration: latest)
        await thirdCaptureGate.resume()
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [
            .forceRefresh,
            .captureOnly,
            .captureOnly,
            .captureOnly,
            .captureOnly,
        ])
        #expect(await loader.forces == [true])
        #expect(controller.configuration == latest)
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.isEmpty)
    }

    @Test
    func `D mandatory barrier catches delayed observation without later reload`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let latest = Self.configuration(owner: "owner", revision: "L")
        let builder = SpendDashboardBuildScript([
            .init(mode: .forceRefresh, request: Self.request(initial, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    latest,
                    mode: .captureOnly,
                    inputs: [Self.input(id: "claude", provider: .claude, cost: 7)])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial, force: true)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(
            inputs: [Self.input(id: "claude", provider: .claude, cost: 1)],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        let settledGeneration = controller.generation
        controller.update(configuration: latest)
        await Task.yield()

        #expect(builder.modes == [.forceRefresh, .captureOnly])
        #expect(await loader.forces == [true])
        #expect(controller.configuration == latest)
        #expect(controller.generation == settledGeneration)
        #expect(controller.model.groups.first?.totalCost == 7)
    }

    @Test
    func `E owner change during barrier discards carry and forces new owner`() async {
        let firstOwner = Self.configuration(owner: "owner-one", revision: "R")
        let firstOwnerLatest = Self.configuration(owner: "owner-one", revision: "S")
        let secondOwner = Self.configuration(owner: "owner-two", revision: "L")
        let learnedEmptyGate = SpendDashboardStateBuildGate()
        let oldBarrierGate = SpendDashboardStateBuildGate()
        let builder = SpendDashboardBuildScript([
            .init(
                mode: .forceRefresh,
                request: Self.request(firstOwner, mode: .forceRefresh, codexAccount: true)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    firstOwner,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"]),
                gate: learnedEmptyGate),
            .init(
                mode: .captureOnly,
                request: Self.request(firstOwnerLatest, mode: .captureOnly),
                gate: oldBarrierGate),
            .init(mode: .forceRefresh, request: Self.request(secondOwner, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    secondOwner,
                    mode: .captureOnly,
                    inputs: [Self.input(id: "claude", provider: .claude, cost: 8)])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: firstOwner, force: true)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(
            inputs: [Self.input(id: "codex:a", provider: .codex, cost: 5)],
            failedSourceIDs: []))
        await Self.waitForBuildGate(learnedEmptyGate)
        controller.update(configuration: firstOwnerLatest)
        await learnedEmptyGate.resume()
        await Self.waitForBuildGate(oldBarrierGate)

        controller.update(configuration: secondOwner)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(
            inputs: [Self.input(id: "claude", provider: .claude, cost: 7)],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }
        await oldBarrierGate.resume()
        await Task.yield()

        #expect(builder.modes == [.forceRefresh, .captureOnly, .captureOnly, .forceRefresh, .captureOnly])
        #expect(await loader.forces == [true, true])
        #expect(controller.configuration == secondOwner)
        #expect(controller.model.groups.first?.totalCost == 8)
        #expect(controller.model.groups.flatMap(\.providers).allSatisfy { $0.id != "codex:a" })
    }

    @Test
    func `F confirmed empty capture wins over forced provider success`() async {
        let configuration = Self.configuration(owner: "owner", revision: "R")
        let oldInput = Self.input(id: "claude", provider: .claude, cost: 4)
        let builder = SpendDashboardBuildScript([
            .init(mode: .refreshMissing, request: Self.request(configuration, mode: .refreshMissing)),
            .init(mode: .forceRefresh, request: Self.request(configuration, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    configuration,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: configuration)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [oldInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(
            inputs: [Self.input(id: "claude", provider: .claude, cost: 6)],
            failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly])
        #expect(await loader.forces == [false, true])
        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 0)
    }

    @Test
    func `G forced Codex invalidation suppresses stale capture and retained row`() async {
        let configuration = Self.configuration(owner: "owner", revision: "R")
        let codexInput = Self.input(id: "codex:a", provider: .codex, cost: 4)
        let builder = SpendDashboardBuildScript([
            .init(mode: .refreshMissing, request: Self.request(configuration, mode: .refreshMissing)),
            .init(
                mode: .forceRefresh,
                request: Self.request(configuration, mode: .forceRefresh, codexAccount: true)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    configuration,
                    mode: .captureOnly,
                    inputs: [Self.input(id: "codex:a", provider: .codex, cost: 99)])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: configuration)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [codexInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(
            inputs: [],
            failedSourceIDs: ["codex:a"],
            invalidatedSourceIDs: ["codex:a"]))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly])
        #expect(await loader.forces == [false, true])
        #expect(controller.model.groups.isEmpty)
        #expect(controller.failedSourceCount == 1)
    }

    @Test
    func `H ordinary update uses refresh missing and one loader without barrier`() async {
        let configuration = Self.configuration(owner: "owner", revision: "R")
        let input = Self.input(id: "claude", provider: .claude, cost: 3)
        let builder = SpendDashboardBuildScript([
            .init(
                mode: .refreshMissing,
                request: Self.request(configuration, mode: .refreshMissing, inputs: [input])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: configuration)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [input], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [.refreshMissing])
        #expect(await loader.forces == [false])
        #expect(controller.generation == 1)
        #expect(controller.model.groups.first?.totalCost == 3)
    }

    @Test
    func `I empty provider published during Codex scan clears retained spend without later reload`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let confirmedEmpty = Self.configuration(owner: "owner", revision: "E")
        let oldProviderInput = Self.input(id: "claude", provider: .claude, cost: 4)
        let codexInput = Self.input(id: "codex:a", provider: .codex, cost: 2)
        let builder = SpendDashboardBuildScript([
            .init(
                mode: .refreshMissing,
                request: Self.request(initial, mode: .refreshMissing, inputs: [oldProviderInput])),
            .init(
                mode: .forceRefresh,
                request: Self.request(
                    initial,
                    mode: .forceRefresh,
                    unavailableSourceIDs: ["claude"],
                    codexAccount: true)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    confirmedEmpty,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"])),
        ])
        let codexGate = SpendDashboardStateCodexGate()
        let loaderRecorder = SpendDashboardStateLoadRecorder()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in
                await loaderRecorder.record(request)
                return await SpendDashboardSource.load(request, codexSnapshotLoader: { _ in
                    await codexGate.load()
                })
            })

        controller.update(configuration: initial)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 4)

        controller.refresh()
        await Self.waitForCodexGate(codexGate)
        controller.update(configuration: confirmedEmpty)
        await codexGate.resume(codexInput.snapshot)
        await Self.waitUntil { !controller.isRefreshing }

        let settledGeneration = controller.generation
        let settledLoadCount = await loaderRecorder.count
        controller.update(configuration: confirmedEmpty)
        await Task.yield()

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly])
        #expect(settledLoadCount == 2)
        #expect(await loaderRecorder.count == settledLoadCount)
        #expect(controller.generation == settledGeneration)
        #expect(controller.configuration == confirmedEmpty)
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(controller.model.groups.flatMap(\.providers).map(\.id) == ["codex:a"])
    }

    @Test
    func `J forced empty survives unavailable capture churn without restoring old spend`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let unavailable = Self.configuration(owner: "owner", revision: "U")
        let latest = Self.configuration(owner: "owner", revision: "M")
        let oldProviderInput = Self.input(id: "claude", provider: .claude, cost: 4)
        let codexInput = Self.input(id: "codex:a", provider: .codex, cost: 2)
        let captureGate = SpendDashboardStateBuildGate()
        let builder = SpendDashboardBuildScript([
            .init(
                mode: .refreshMissing,
                request: Self.request(initial, mode: .refreshMissing, inputs: [oldProviderInput])),
            .init(
                mode: .forceRefresh,
                request: Self.request(
                    initial,
                    mode: .forceRefresh,
                    confirmedEmptySourceIDs: ["claude"],
                    codexAccount: true)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    unavailable,
                    mode: .captureOnly,
                    unavailableSourceIDs: ["claude"]),
                gate: captureGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    latest,
                    mode: .captureOnly,
                    unavailableSourceIDs: ["claude"])),
        ])
        let codexGate = SpendDashboardStateCodexGate()
        let loaderRecorder = SpendDashboardStateLoadRecorder()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in
                await loaderRecorder.record(request)
                return await SpendDashboardSource.load(request, codexSnapshotLoader: { _ in
                    await codexGate.load()
                })
            })

        controller.update(configuration: initial)
        await Self.waitUntil { !controller.isRefreshing }
        #expect(controller.model.groups.first?.totalCost == 4)

        controller.refresh()
        await Self.waitForCodexGate(codexGate)
        controller.update(configuration: unavailable)
        await codexGate.resume(codexInput.snapshot)
        await Self.waitForBuildGate(captureGate)
        controller.update(configuration: latest)
        await captureGate.resume()
        await Self.waitUntil { !controller.isRefreshing }

        let settledGeneration = controller.generation
        controller.update(configuration: latest)
        await Task.yield()

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly, .captureOnly])
        #expect(await loaderRecorder.forces == [false, true])
        #expect(controller.generation == settledGeneration)
        #expect(controller.configuration == latest)
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.first?.totalCost == 2)
        #expect(controller.model.groups.flatMap(\.providers).map(\.id) == ["codex:a"])
    }

    @Test
    func `K learned empty survives superseded capture then unavailable barrier`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let confirmedEmpty = Self.configuration(owner: "owner", revision: "E")
        let unavailable = Self.configuration(owner: "owner", revision: "U")
        let oldProviderInput = Self.input(id: "claude", provider: .claude, cost: 4)
        let forcedProviderInput = Self.input(id: "claude", provider: .claude, cost: 6)
        let learnedEmptyGate = SpendDashboardStateBuildGate()
        let builder = SpendDashboardBuildScript([
            .init(mode: .refreshMissing, request: Self.request(initial, mode: .refreshMissing)),
            .init(mode: .forceRefresh, request: Self.request(initial, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    confirmedEmpty,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"]),
                gate: learnedEmptyGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    unavailable,
                    mode: .captureOnly,
                    unavailableSourceIDs: ["claude"])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [oldProviderInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForLoader(loader)
        controller.update(configuration: confirmedEmpty)
        await loader.resume(SpendDashboardLoadResult(inputs: [forcedProviderInput], failedSourceIDs: []))
        await Self.waitForBuildGate(learnedEmptyGate)
        controller.update(configuration: unavailable)
        await learnedEmptyGate.resume()
        await Self.waitUntil { !controller.isRefreshing }

        let settledGeneration = controller.generation
        controller.update(configuration: unavailable)
        await Task.yield()

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly, .captureOnly])
        #expect(await loader.forces == [false, true])
        #expect(controller.generation == settledGeneration)
        #expect(controller.configuration == unavailable)
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.isEmpty)
    }

    @Test
    func `L fresh nonempty after empty survives later unavailable despite forced failure`() async {
        let initial = Self.configuration(owner: "owner", revision: "R")
        let confirmedEmpty = Self.configuration(owner: "owner", revision: "E")
        let fresh = Self.configuration(owner: "owner", revision: "N")
        let unavailable = Self.configuration(owner: "owner", revision: "U")
        let oldProviderInput = Self.input(id: "claude", provider: .claude, cost: 4)
        let freshProviderInput = Self.input(id: "claude", provider: .claude, cost: 7)
        let emptyGate = SpendDashboardStateBuildGate()
        let freshGate = SpendDashboardStateBuildGate()
        let builder = SpendDashboardBuildScript([
            .init(mode: .refreshMissing, request: Self.request(initial, mode: .refreshMissing)),
            .init(mode: .forceRefresh, request: Self.request(initial, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    confirmedEmpty,
                    mode: .captureOnly,
                    confirmedEmptySourceIDs: ["claude"]),
                gate: emptyGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    fresh,
                    mode: .captureOnly,
                    inputs: [freshProviderInput]),
                gate: freshGate),
            .init(
                mode: .captureOnly,
                request: Self.request(
                    unavailable,
                    mode: .captureOnly,
                    unavailableSourceIDs: ["claude"])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [oldProviderInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForLoader(loader)
        controller.update(configuration: confirmedEmpty)
        await loader.resume(SpendDashboardLoadResult(inputs: [], failedSourceIDs: ["claude"]))
        await Self.waitForBuildGate(emptyGate)
        controller.update(configuration: fresh)
        await emptyGate.resume()
        await Self.waitForBuildGate(freshGate)
        controller.update(configuration: unavailable)
        await freshGate.resume()
        await Self.waitUntil { !controller.isRefreshing }

        let settledGeneration = controller.generation
        controller.update(configuration: unavailable)
        await Task.yield()

        #expect(builder.modes == [
            .refreshMissing,
            .forceRefresh,
            .captureOnly,
            .captureOnly,
            .captureOnly,
        ])
        #expect(await loader.forces == [false, true])
        #expect(controller.generation == settledGeneration)
        #expect(controller.configuration == unavailable)
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.first?.totalCost == 7)
        #expect(controller.model.groups.flatMap(\.providers).map(\.id) == ["claude"])
    }

    @Test
    func `M newer source publication supersedes failed force stale row`() async {
        let initial = Self.configuration(owner: "owner", revision: "claude:snapshot:1:old")
        let latest = Self.configuration(owner: "owner", revision: "claude:snapshot:2:fresh")
        let oldProviderInput = Self.input(id: "claude", provider: .claude, cost: 4)
        let freshProviderInput = Self.input(id: "claude", provider: .claude, cost: 7)
        let builder = SpendDashboardBuildScript([
            .init(
                mode: .refreshMissing,
                request: Self.request(initial, mode: .refreshMissing, inputs: [oldProviderInput])),
            .init(mode: .forceRefresh, request: Self.request(initial, mode: .forceRefresh)),
            .init(
                mode: .captureOnly,
                request: Self.request(latest, mode: .captureOnly, inputs: [freshProviderInput])),
        ])
        let loader = SpendDashboardStateLoaderGate()
        let controller = SpendDashboardController(
            requestBuilder: { mode in await builder.next(mode) },
            loader: { request in await loader.load(request) })

        controller.update(configuration: initial)
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [oldProviderInput], failedSourceIDs: []))
        await Self.waitUntil { !controller.isRefreshing }

        controller.refresh()
        await Self.waitForLoader(loader)
        await loader.resume(SpendDashboardLoadResult(inputs: [], failedSourceIDs: ["claude"]))
        await Self.waitUntil { !controller.isRefreshing }

        #expect(builder.modes == [.refreshMissing, .forceRefresh, .captureOnly])
        #expect(await loader.forces == [false, true])
        #expect(controller.configuration == latest)
        #expect(controller.failedSourceCount == 1)
        #expect(controller.model.groups.first?.totalCost == 7)
        #expect(controller.model.groups.flatMap(\.providers).map(\.id) == ["claude"])
    }

    private static func configuration(owner: String, revision: String) -> SpendDashboardConfiguration {
        SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue, UsageProvider.claude.rawValue],
            codexAccountIdentities: ["a|\(owner)"],
            sourceOwnershipFingerprints: ["claude:\(owner)"],
            sourceRevisions: [revision])
    }

    private static func request(
        _ configuration: SpendDashboardConfiguration,
        mode: SpendDashboardRequestBuildMode,
        inputs: [SpendDashboardModel.ProviderInput] = [],
        unavailableSourceIDs: Set<String> = [],
        confirmedEmptySourceIDs: Set<String> = [],
        codexAccount: Bool = false) -> SpendDashboardLoadRequest
    {
        SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: inputs,
            unavailableSourceIDs: unavailableSourceIDs,
            confirmedEmptySourceIDs: confirmedEmptySourceIDs,
            codexRequests: codexAccount ? [self.codexRequest()] : [],
            now: Date(timeIntervalSince1970: 1_784_179_200),
            force: mode.forcesLoader)
    }

    private static func codexRequest() -> CodexSpendScanRequest {
        CodexSpendScanRequest(
            id: "a",
            displayName: "Codex",
            source: .profileHome(path: "/synthetic/codex-a"),
            homePath: "/synthetic/codex-a",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "synthetic-a")
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [entry],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
        return SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            modelProviderName: provider == .codex ? "Codex" : nil,
            snapshot: snapshot)
    }

    private static func waitForLoader(_ loader: SpendDashboardStateLoaderGate) async {
        for _ in 0..<1000 {
            if await loader.pendingCount == 1 {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for dashboard loader")
    }

    private static func waitForBuildGate(_ gate: SpendDashboardStateBuildGate) async {
        for _ in 0..<1000 {
            if await gate.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for dashboard build gate")
    }

    private static func waitForCodexGate(_ gate: SpendDashboardStateCodexGate) async {
        for _ in 0..<1000 {
            if await gate.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for dashboard Codex gate")
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for dashboard controller")
    }
}

@MainActor
private final class SpendDashboardBuildScript {
    struct Step {
        let mode: SpendDashboardRequestBuildMode
        let request: SpendDashboardLoadRequest
        let gate: SpendDashboardStateBuildGate?

        init(
            mode: SpendDashboardRequestBuildMode,
            request: SpendDashboardLoadRequest,
            gate: SpendDashboardStateBuildGate? = nil)
        {
            self.mode = mode
            self.request = request
            self.gate = gate
        }
    }

    private var steps: [Step]
    private(set) var modes: [SpendDashboardRequestBuildMode] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func next(_ mode: SpendDashboardRequestBuildMode) async -> SpendDashboardLoadRequest {
        guard !self.steps.isEmpty else {
            Issue.record("Unexpected dashboard build mode: \(mode)")
            return SpendDashboardLoadRequest(
                configuration: SpendDashboardConfiguration(
                    costUsageEnabled: false,
                    providerIDs: [],
                    codexAccountIdentities: []),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: Date(timeIntervalSince1970: 1_784_179_200),
                force: mode.forcesLoader)
        }
        let step = self.steps.removeFirst()
        self.modes.append(mode)
        #expect(mode == step.mode)
        if let gate = step.gate {
            await gate.suspend()
        }
        return step.request
    }
}

private actor SpendDashboardStateBuildGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool {
        self.continuation != nil
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

private actor SpendDashboardStateLoaderGate {
    private var continuations: [CheckedContinuation<SpendDashboardLoadResult, Never>] = []
    private(set) var forces: [Bool] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        self.forces.append(request.force)
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func resume(_ result: SpendDashboardLoadResult) {
        self.continuations.removeFirst().resume(returning: result)
    }
}

private actor SpendDashboardStateCodexGate {
    private var continuation: CheckedContinuation<CostUsageTokenSnapshot, Never>?

    var isSuspended: Bool {
        self.continuation != nil
    }

    func load() async -> CostUsageTokenSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(_ snapshot: CostUsageTokenSnapshot) {
        self.continuation?.resume(returning: snapshot)
        self.continuation = nil
    }
}

private actor SpendDashboardStateLoadRecorder {
    private(set) var count = 0
    private(set) var forces: [Bool] = []

    func record(_ request: SpendDashboardLoadRequest) {
        self.count += 1
        self.forces.append(request.force)
    }
}
