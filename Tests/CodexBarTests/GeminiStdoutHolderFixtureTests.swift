import Foundation
import Testing
@testable import CodexBarCore

struct GeminiStdoutHolderFixtureTests {
    typealias Holder = GeminiStdoutHolderFixture

    @Test
    func `capture completion between observations never pairs new EOF with stale bytes`() {
        var bytes = Data()
        var ended = false
        let observation = Holder.captureObservation(
            snapshot: {
                let prior = bytes
                bytes = Data("rea".utf8)
                ended = true
                return prior
            },
            reachedEOF: { ended },
            observedExit: { ended })
        #expect(!observation.eof || observation.bytes == Data("rea".utf8))
        #expect(Holder.observeReadiness(observation.bytes, ended: observation.eof, elapsed: 0) !=
            .failed(.exitedBeforeReady))
        let completed = Holder.captureObservation(
            snapshot: { bytes }, reachedEOF: { ended }, observedExit: { ended })
        #expect(Holder.observeReadiness(completed.bytes, ended: completed.eof, elapsed: 0) ==
            .failed(.incompleteReadiness))
    }

    @Test
    func `readiness policy has an independent bounded setup deadline`() {
        #expect(Holder.observeReadiness(Data(), ended: false, elapsed: 2.25) == .pending)
        #expect(Holder.observeReadiness(Data("ready\n".utf8), ended: false, elapsed: 2.25) == .ready)
        #expect(Holder.observeReadiness(Data(), ended: false, elapsed: Holder.setupBudget) == .failed(.timedOut))
        #expect(Holder.observeReadiness(
            Data("ready\n".utf8), ended: false, elapsed: Holder.setupBudget) == .failed(.timedOut))
        #expect(Holder.observeReadiness(Data("rea".utf8), ended: true, elapsed: 1) == .failed(.incompleteReadiness))
    }

    @Test
    func `failed preparation closes pipes without launching a child`() throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        do {
            _ = try Holder(root: env.homeURL.appendingPathComponent("missing-parent"))
            Issue.record("Expected preparation failure")
        } catch let error as Holder.SetupError {
            #expect(error.cause == .preparationFailed)
            #expect(error.underlyingError is CocoaError)
            #expect(!error.cleanup.launched)
            #expect(error.cleanup.terminationStatus == nil)
            #expect(error.cleanup.phases == [.controlClosed, .capturesStopped])
        }
    }

    @Test
    func `readiness beyond two seconds uses a separate setup budget`() throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        let holder = try GeminiStdoutHolderFixture(root: env.homeURL, readinessDelay: 2.25)
        defer { #expect(holder.cleanup().succeeded) }
        #expect(holder.process.executableURL?.path == "/usr/bin/python3")
        #expect(holder.process.arguments?.first == "-I")
        #expect(!FileManager.default.fileExists(atPath: holder.pidFile.path))
        #expect(holder.runProducer() == "/tmp/gemini-package")
        #expect(holder.process.isRunning)
    }

    @Test(arguments: [Holder.Fault.lateReady, .neverReady])
    func `setup deadline retains stdout through control close and normal reap`(fault: Holder.Fault) throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        do {
            _ = try Holder(root: env.homeURL, fault: fault, readinessElapsed: { elapsed, stderr in
                // Advance only once the owned child is waiting for control EOF, independent of interpreter startup.
                stderr == Data("armed\n".utf8) ? Holder.setupBudget : elapsed
            })
            Issue.record("Expected setup timeout")
        } catch let error as Holder.SetupError {
            #expect(error.cause == .timedOut)
            #expect(error.underlyingError == nil)
            #expect(error.readinessBytes.isEmpty)
            #expect(!error.reachedEOF)
            #expect(!error.observedExit)
            #expect(error.cleanup.succeeded)
            #expect(error.cleanup.terminationReason == .exit)
            #expect(error.cleanup.stdout == (fault == .lateReady ? Data("ready\n".utf8) : Data()))
            #expect(error.cleanup.stderr == Data("armed\n".utf8))
            #expect(!FileManager.default.fileExists(atPath: env.homeURL.appendingPathComponent("holder.pid").path))
        }
    }

    @Test(arguments: [Holder.Fault.earlyExit, .partialReady, .malformedReady, .launchFailure])
    func `setup failures keep their cause and clean the owned process`(fault: Holder.Fault) throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        do {
            _ = try Holder(root: env.homeURL, fault: fault)
            Issue.record("Expected setup failure")
        } catch let error as Holder.SetupError {
            switch fault {
            case .earlyExit:
                #expect(error.cause == .exitedBeforeReady)
                #expect(error.cleanup.terminationStatus == 23)
                #expect(error.cleanup.phases == [.controlClosed, .reaped, .capturesStopped])
            case .partialReady:
                #expect(error.cause == .incompleteReadiness)
                #expect(error.readinessBytes == Data("rea".utf8))
                #expect(error.cleanup.succeeded)
            case .malformedReady:
                #expect(error.cause == .malformedReadiness)
                #expect(error.readinessBytes == Data("wrong\n".utf8))
                #expect(error.cleanup.succeeded)
            case .launchFailure:
                #expect(error.cause == .launchFailed)
                #expect(error.underlyingError is CocoaError)
                #expect(!error.cleanup.launched)
                #expect(error.cleanup.terminationStatus == nil)
                #expect(error.cleanup.phases == [.controlClosed, .capturesStopped])
            default: Issue.record("Unexpected fault")
            }
            #expect(!error.cleanup.forcedTermination)
            #expect(!FileManager.default.fileExists(atPath: env.homeURL.appendingPathComponent("holder.pid").path))
        }
    }

    @Test
    func `cleanup escalates only the owned child and is idempotent`() throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        let holder = try Holder(root: env.homeURL, fault: .ignoreControl)
        defer { holder.cleanup() }
        let outcome = holder.cleanup()
        #expect(outcome.forcedTermination)
        #expect(outcome.terminationReason == .uncaughtSignal)
        #expect(outcome.phases == [.controlClosed, .reaped, .capturesStopped])
        #expect(!holder.process.isRunning)
        #expect(holder.cleanup() == outcome)
    }

    @Test
    func `producer still times out after two seconds while its acknowledged holder stays owned`() throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        let holder = try Holder(root: env.homeURL)
        defer { #expect(holder.cleanup().succeeded) }
        let started = ProcessInfo.processInfo.systemUptime
        #expect(holder.runProducer(blockAfterAcknowledgment: true) == nil)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed >= 2 && elapsed < 5)
        let publishedPID = try String(contentsOf: holder.pidFile, encoding: .utf8)
        #expect(pid_t(publishedPID) == holder.process.processIdentifier)
        #expect(holder.process.isRunning)
    }

    @Test
    func `first line capture completes while the test still owns the writer`() throws {
        let pipe = Pipe()
        let received = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockIsolated<Data?>(nil)
        let capture = ProcessPipeCapture(pipe: pipe, onData: { received.signal() })
        capture.start()
        defer { capture.stop() }
        defer { pipe.fileHandleForWriting.closeFile() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        try #require(received.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            result.setValue(capture.finishFirstLineSynchronously(timeout: 10))
            finished.signal()
        }
        // Output is already captured; this watchdog does not include interpreter startup or require EOF.
        let completedWithWriterOpen = finished.wait(timeout: .now() + 2)
        #expect(completedWithWriterOpen == .success)
        pipe.fileHandleForWriting.closeFile()
        if completedWithWriterOpen != .success {
            #expect(finished.wait(timeout: .now() + 10) == .success)
        }
        #expect(result.value == Data("ready\n".utf8))
    }
}
