import CodexBarCore
import Foundation

// Subprocess driver for the store tests that need a real process. CostUsageStoreCrashSafetyTests
// SIGKILLs this process mid-save to prove the save cycle is all-or-nothing;
// CostUsageStoreExecutorIsolationTests runs it with the legacy executor-check mode forced,
// which only the main executable can select.
//
// Usage: CodexBarCostStoreCrashProbe <seed|save|load|crash-save> <cacheRoot> [killAfterFiles]

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: <seed|save|load|crash-save> <cacheRoot> [killAfterFiles]\n".utf8))
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
case "load":
    let fileCount = CostUsageStoreCrashHarness.load(cacheRoot: cacheRoot)
    FileHandle.standardOutput.write(Data("\(fileCount)\n".utf8))
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
