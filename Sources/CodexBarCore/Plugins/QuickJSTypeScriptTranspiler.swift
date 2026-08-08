import CQuickJS
import Foundation

enum QuickJSTypeScriptTranspiler {
    static func transpile(source: String, sucraseSource: String) throws -> String {
        let box = QuickJSBlockingResult<String>()
        let thread = Thread {
            box.finish(Result {
                try self.transpileOnCurrentThread(source: source, sucraseSource: sucraseSource)
            })
        }
        // Dispatch/Swift cooperative workers can have less native stack than QuickJS's 2 MiB limit.
        thread.stackSize = QuickJSRuntimeLimits.nativeStackSizeBytes
        thread.name = "CodexBar QuickJS TypeScript transpiler"
        thread.start()

        let deadline = Date().addingTimeInterval(ProviderPluginRuntime.defaultTimeout + 1)
        while Date() < deadline {
            if let result = box.wait(until: deadline) {
                return try result.get()
            }
        }
        throw ProviderPluginError.timedOut
    }

    private static func transpileOnCurrentThread(source: String, sucraseSource: String) throws -> String {
        guard let runtime = JS_NewRuntime() else {
            throw ProviderPluginError.load("QuickJS could not create a TypeScript transpiler runtime")
        }
        JS_SetMemoryLimit(runtime, QuickJSProviderPluginEngine.memoryLimitBytes)
        JS_SetMaxStackSize(runtime, QuickJSProviderPluginEngine.stackLimitBytes)
        guard let context = JS_NewContext(runtime) else {
            JS_FreeRuntime(runtime)
            throw ProviderPluginError.load("QuickJS could not create a TypeScript transpiler context")
        }
        JS_UpdateStackTop(runtime)
        guard let watchdog = cqjs_watchdog_create(nil, nil) else {
            JS_FreeContext(context)
            JS_FreeRuntime(runtime)
            throw ProviderPluginError.load("QuickJS could not create its TypeScript transpiler watchdog")
        }
        cqjs_watchdog_install(watchdog, runtime, context)
        cqjs_watchdog_arm(watchdog, UInt64(ProviderPluginRuntime.defaultTimeout * 1000))
        defer {
            cqjs_watchdog_disarm(watchdog)
            // The runtime retains the interrupt-handler opaque pointer until it is freed.
            JS_FreeContext(context)
            JS_FreeRuntime(runtime)
            cqjs_watchdog_destroy(watchdog)
        }

        func exceptionMessage() -> String {
            let exception = JS_GetException(context)
            defer { cqjs_free_value(context, exception) }
            var length = 0
            guard let pointer = JS_ToCStringLen2(context, &length, exception, false) else { return "unknown error" }
            defer { JS_FreeCString(context, pointer) }
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            return String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) ?? "unknown error"
        }

        func evaluate(_ script: String, filename: String) throws -> JSValue {
            let value = script.utf8CString.withUnsafeBufferPointer { scriptBuffer in
                filename.withCString { filenamePointer in
                    JS_Eval(
                        context,
                        scriptBuffer.baseAddress,
                        scriptBuffer.count - 1,
                        filenamePointer,
                        JS_EVAL_TYPE_GLOBAL)
                }
            }
            guard !cqjs_is_exception(value) else {
                throw ProviderPluginError.load("TypeScript transpilation failed: \(exceptionMessage())")
            }
            return value
        }

        let sucrase = try evaluate(sucraseSource, filename: "sucrase.js")
        cqjs_free_value(context, sucrase)
        let global = JS_GetGlobalObject(context)
        defer { cqjs_free_value(context, global) }
        let sourceValue = source.utf8CString.withUnsafeBufferPointer { buffer in
            JS_NewStringLen(context, buffer.baseAddress, buffer.count - 1)
        }
        _ = JS_SetPropertyStr(context, global, "__codexbarTypeScriptSource", sourceValue)
        let result = try evaluate(
            "sucrase.transform(__codexbarTypeScriptSource, {transforms:['typescript']}).code",
            filename: "<sucrase-transform>")
        defer { cqjs_free_value(context, result) }
        var length = 0
        guard let pointer = JS_ToCStringLen2(context, &length, result, false) else {
            throw ProviderPluginError.load("TypeScript transpilation returned no output")
        }
        defer { JS_FreeCString(context, pointer) }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        guard let output = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8),
              !output.isEmpty
        else { throw ProviderPluginError.load("TypeScript transpilation returned no output") }
        return output
    }
}
