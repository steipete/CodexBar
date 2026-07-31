#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Glibc)
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func glibc_posix_spawn_file_actions_addchdir_np(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
    _ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("posix_spawn_file_actions_addclosefrom_np")
private func glibc_posix_spawn_file_actions_addclosefrom_np(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
    _ fileDescriptor: Int32) -> Int32
#endif

enum PosixSpawnFileActionsCompatibility {
    static func addChangeDirectory(
        _ fileActions: inout posix_spawn_file_actions_t,
        path: UnsafePointer<CChar>) -> Int32
    {
        #if canImport(Glibc)
        glibc_posix_spawn_file_actions_addchdir_np(&fileActions, path)
        #else
        posix_spawn_file_actions_addchdir_np(&fileActions, path)
        #endif
    }

    #if canImport(Glibc)
    static func addCloseFrom(
        _ fileActions: inout posix_spawn_file_actions_t,
        startingAt minimumFileDescriptor: Int32) -> Int32
    {
        glibc_posix_spawn_file_actions_addclosefrom_np(&fileActions, minimumFileDescriptor)
    }
    #endif
}
