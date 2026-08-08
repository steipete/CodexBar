import CodexBarCore
import Foundation

// Subprocess driver for CostUsageStoreCrashSafetyTests: the test SIGKILLs this process
// mid-save to prove the store's save cycle is all-or-nothing.
//
// Usage: CodexBarCostStoreCrashProbe <seed|save|crash-save> <cacheRoot> [killAfterFiles]

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: <seed|save|crash-save> <cacheRoot> [killAfterFiles]\n".utf8))
    exit(64)
}

let cacheRoot = URL(fileURLWithPath: arguments[2], isDirectory: true)
switch arguments[1] {
case "seed":
    CostUsageStoreCrashHarness.seed(cacheRoot: cacheRoot)
    exit(0)
case "save":
    CostUsageStoreCrashHarness.saveUpdate(cacheRoot: cacheRoot, killAfterFiles: nil)
    exit(0)
case "crash-save":
    let killAfterFiles = arguments.count > 3 ? Int(arguments[3]) : 1
    CostUsageStoreCrashHarness.saveUpdate(cacheRoot: cacheRoot, killAfterFiles: killAfterFiles)
    // The checkpoint hook must have killed the process during the save.
    FileHandle.standardError.write(Data("crash-save survived the save cycle\n".utf8))
    exit(70)
default:
    exit(64)
}
