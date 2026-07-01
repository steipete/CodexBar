import CodexBarCore
import Darwin
import Foundation

struct ClaudeLoginRunner {
    static let loginArguments = ["auth", "login", "--claudeai"]
    private static let successMarkers = ["Successfully logged in", "Login successful", "Logged in successfully"]

    enum Phase {
        case requesting
        case waitingBrowser
    }

    struct Result {
        enum Outcome {
            case success
            case timedOut
            case failed(status: Int32)
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
        let output: String
        let authLink: String?
    }

    static func run(
        timeout: TimeInterval = 120,
        binary: String = "claude",
        environment: [String: String]? = nil,
        onPhaseChange: @escaping @Sendable (Phase) -> Void) async -> Result
    {
        await Task(priority: .userInitiated) {
            onPhaseChange(.requesting)
            do {
                let runResult = try self.runPTY(
                    timeout: timeout,
                    binary: binary,
                    environment: environment,
                    onPhaseChange: onPhaseChange)
                let link = self.firstLink(in: runResult.output)
                switch runResult.completion {
                case .processExited(status: 0):
                    return Result(outcome: .success, output: runResult.output, authLink: link)
                case let .processExited(status):
                    return Result(outcome: .failed(status: status), output: runResult.output, authLink: link)
                case .outputCondition where self.successMarkers.contains(where: runResult.output.contains):
                    return Result(outcome: .success, output: runResult.output, authLink: link)
                case .outputCondition, .idleTimeout, .deadlineExceeded:
                    return Result(outcome: .timedOut, output: runResult.output, authLink: link)
                }
            } catch LoginError.binaryNotFound {
                return Result(outcome: .missingBinary, output: "", authLink: nil)
            } catch let LoginError.timedOut(text) {
                return Result(outcome: .timedOut, output: text, authLink: self.firstLink(in: text))
            } catch {
                return Result(outcome: .launchFailed(error.localizedDescription), output: "", authLink: nil)
            }
        }.value
    }

    // MARK: - PTY runner

    private enum LoginError: Error {
        case binaryNotFound
        case timedOut(text: String)
        case launchFailed(String)
    }

    private struct PTYRunResult {
        let output: String
        let completion: TTYCommandRunner.Result.Completion
    }

    private static func runPTY(
        timeout: TimeInterval,
        binary: String,
        environment: [String: String]?,
        onPhaseChange: @escaping @Sendable (Phase) -> Void) throws -> PTYRunResult
    {
        let runner = TTYCommandRunner()
        var options = TTYCommandRunner.Options(rows: 50, cols: 160, timeout: timeout)
        options.extraArgs = self.loginArguments
        options.baseEnvironment = environment
        options.stopOnURL = false // keep running until CLI confirms
        options.stopOnSubstrings = self.successMarkers
        options.sendOnSubstrings = ["press ENTER to open in browser": "\r"]
        options.settleAfterStop = 0.35
        options.returnOnEmptyProcessExit = true
        do {
            let result = try runner.run(
                binary: binary,
                send: "",
                options: options,
                onURLDetected: { onPhaseChange(.waitingBrowser) })
            return PTYRunResult(output: result.text, completion: result.completion)
        } catch TTYCommandRunner.Error.binaryNotFound {
            throw LoginError.binaryNotFound
        } catch TTYCommandRunner.Error.timedOut {
            throw LoginError.timedOut(text: "")
        } catch let TTYCommandRunner.Error.launchFailed(msg) {
            throw LoginError.launchFailed(msg)
        } catch {
            throw LoginError.launchFailed(error.localizedDescription)
        }
    }

    private static func firstLink(in text: String) -> String? {
        let pattern = #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else { return nil }
        var url = String(text[range])
        while let last = url.unicodeScalars.last,
              CharacterSet(charactersIn: ".,;:)]}>\"'").contains(last)
        {
            url.unicodeScalars.removeLast()
        }
        return url
    }
}
