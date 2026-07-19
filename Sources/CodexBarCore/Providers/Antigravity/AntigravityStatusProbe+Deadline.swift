import Foundation

extension AntigravityStatusProbe {
    private static let processProbeLog = CodexBarLog.logger(LogCategories.antigravity)

    private enum ProcessSnapshotFetchFailure {
        case antigravity(AntigravityStatusProbeError)
        case url(URLError)
        case cancellation
        case other(String)

        init(_ error: Error) {
            if let error = error as? AntigravityStatusProbeError {
                self = .antigravity(error)
            } else if let error = error as? URLError, error.code == .cancelled {
                self = .cancellation
            } else if let error = error as? URLError {
                self = .url(error)
            } else if error is CancellationError {
                self = .cancellation
            } else {
                self = .other(error.localizedDescription)
            }
        }

        var error: Error {
            switch self {
            case let .antigravity(error):
                error
            case let .url(error):
                error
            case .cancellation:
                CancellationError()
            case let .other(message):
                AntigravityStatusProbeError.apiError(message)
            }
        }
    }

    private enum ProcessSnapshotFetchOutcome {
        case success(index: Int, snapshot: AntigravityStatusSnapshot)
        case failure(index: Int, pid: Int, failure: ProcessSnapshotFetchFailure)
    }

    static func fetchProcessSnapshots(
        processInfos: [ProcessInfoResult],
        fetch: @escaping @Sendable (ProcessInfoResult) async throws -> AntigravityStatusSnapshot)
        async throws -> (snapshots: [AntigravityStatusSnapshot], lastError: Error?)
    {
        let outcomes = await withTaskGroup(of: ProcessSnapshotFetchOutcome.self) { group in
            for (index, processInfo) in processInfos.enumerated() {
                group.addTask {
                    do {
                        return try await .success(index: index, snapshot: fetch(processInfo))
                    } catch {
                        return .failure(index: index, pid: processInfo.pid, failure: .init(error))
                    }
                }
            }

            var ordered = [ProcessSnapshotFetchOutcome?](repeating: nil, count: processInfos.count)
            for await outcome in group {
                switch outcome {
                case let .success(index, _), let .failure(index, _, _):
                    ordered[index] = outcome
                }
            }
            return ordered.compactMap(\.self)
        }

        var snapshots: [AntigravityStatusSnapshot] = []
        var lastError: Error?
        for outcome in outcomes {
            switch outcome {
            case let .success(_, snapshot):
                snapshots.append(snapshot)
            case let .failure(_, pid, failure):
                if case .cancellation = failure {
                    throw CancellationError()
                }
                let error = failure.error
                lastError = error
                Self.processProbeLog.debug("Antigravity local process probe failed", metadata: [
                    "pid": "\(pid)",
                    "error": error.localizedDescription,
                ])
            }
        }
        return (snapshots, lastError)
    }

    static func fetch(
        processInfo: ProcessInfoResult,
        timeout: TimeInterval,
        deadline: Date) async throws -> AntigravityStatusSnapshot
    {
        guard let portTimeout = timeoutForNextAttempt(timeout: timeout, deadline: deadline) else {
            throw AntigravityStatusProbeError.timedOut
        }
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: portTimeout)
        let endpoint = try await Self.resolveWorkingEndpoint(
            candidateEndpoints: Self.connectionCandidates(
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: timeout,
            deadline: deadline)
        let context = RequestContext(
            endpoints: Self.requestEndpoints(
                resolvedEndpoint: endpoint,
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: timeout,
            deadline: deadline)

        return try await Self.fetchSnapshot(context: context)
    }

    static func timeoutForNextAttempt(timeout: TimeInterval, deadline: Date?) -> TimeInterval? {
        guard let deadline else { return timeout }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return min(timeout, remaining)
    }
}
