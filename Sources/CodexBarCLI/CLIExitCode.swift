enum ExitCode: Int32, Sendable {
    case success = 0
    case failure = 1
    case binaryNotFound = 2
    case parseError = 3
    case timeout = 4

    init(_ rawValue: Int) {
        self = ExitCode(rawValue: Int32(rawValue)) ?? .failure
    }
}
