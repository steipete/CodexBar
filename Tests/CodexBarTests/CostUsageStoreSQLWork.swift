import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBarCore

/// Connection-local SQLite work, independent of executor scheduling and disk latency.
struct CostUsageStoreSQLWork: Sendable {
    var statements = 0
    var virtualMachineSteps = 0
}

private final class SQLWorkCounter {
    var work = CostUsageStoreSQLWork()
}

extension CostUsageStore {
    func measureSQLWork<T: Sendable>(
        _ operation: @Sendable (isolated CostUsageStore) throws -> T) throws -> (value: T, work: CostUsageStoreSQLWork)
    {
        try self.withDatabase(default: Result<(T, CostUsageStoreSQLWork), Error>.failure(
            CocoaError(.fileReadUnknown)))
        { database in
            let counter = SQLWorkCounter()
            sqlite3_trace_v2(
                database,
                UInt32(SQLITE_TRACE_PROFILE),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let counter = Unmanaged<SQLWorkCounter>.fromOpaque(context).takeUnretainedValue()
                    counter.work.statements += 1
                    counter.work.virtualMachineSteps += Int(sqlite3_stmt_status(
                        OpaquePointer(statement), SQLITE_STMTSTATUS_VM_STEP, 1))
                    return 0
                },
                Unmanaged.passUnretained(counter).toOpaque())
            defer {
                withExtendedLifetime(counter) { _ = sqlite3_trace_v2(database, 0, nil, nil) }
            }
            let value = try operation(self)
            return .success((value, counter.work))
        }.get()
    }
}
