#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

enum PosixSpawnFileActionsCloseFrom {
    enum CloseFromError: LocalizedError {
        case descriptorEnumerationFailed(String)
        case actionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case let .descriptorEnumerationFailed(details):
                "Could not enumerate /proc/self/fd: \(details)"
            case let .actionFailed(code):
                "Could not configure descriptor cleanup: \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    static func descriptorsToClose(
        startingAt minimumFileDescriptor: Int32,
        contentsOfDirectory: (String) throws -> [String] = FileManager.default.contentsOfDirectory(atPath:)) throws
        -> [Int32]
    {
        let entries: [String]
        do {
            entries = try contentsOfDirectory("/proc/self/fd")
        } catch {
            throw CloseFromError.descriptorEnumerationFailed(error.localizedDescription)
        }
        return entries.compactMap(Int32.init)
            .filter { $0 >= minimumFileDescriptor }
            .sorted()
    }

    #if canImport(Glibc) || canImport(Musl)
    static func addCloseFrom(
        _ fileActions: inout posix_spawn_file_actions_t,
        startingAt minimumFileDescriptor: Int32) throws
    {
        #if canImport(Glibc)
        try self.check(posix_spawn_file_actions_addclosefrom_np(&fileActions, minimumFileDescriptor))
        #else
        for descriptor in try self.descriptorsToClose(startingAt: minimumFileDescriptor) {
            try self.check(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }
        #endif
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw CloseFromError.actionFailed(result)
        }
    }
    #endif
}
