import Foundation

/// Streaming JSON projection. Large outputs and arguments are skipped structurally, including when
/// timing/status fields follow them. Neither a complete record nor an unbounded string is retained.
struct SessionToolJSONProjection {
    private static let keys: Set<String> = [
        "type", "timestamp", "payload", "item", "id", "thread_id", "turn_id", "started_at_ms",
        "completed_at_ms", "status", "exit_code", "duration", "secs", "nanos", "server", "tool",
        "namespace", "command", "result", "isError", "error", "success", "kind", "durationMs",
    ]
    private struct Container {
        let isObject: Bool
        var expectsKey: Bool
    }

    private var containers: [Container] = []
    private var token: [UInt8] = []
    private var output: [UInt8] = []
    private var inString = false
    private var escaped = false
    private var primitive = false
    private var tokenOverflow = false
    private var skipNextValue = false
    private var skippedDepth = 0
    private(set) var overflowed = false
    private(set) var hasBytes = false
    private(set) var invalid = false

    mutating func consume(_ byte: UInt8) {
        self.hasBytes = true
        guard !self.invalid, !self.overflowed else { return }
        if self.inString {
            self.appendToken(byte)
            if self.escaped {
                self.escaped = false
            } else if byte == 92 {
                self.escaped = true
            } else if byte == 34 {
                self.inString = false
                self.finishToken(isString: true)
            }
            return
        }
        if self.primitive {
            if byte == 44 || byte == 125 || byte == 93 || byte <= 32 {
                self.primitive = false
                self.finishToken(isString: false)
            } else {
                self.appendToken(byte)
                return
            }
        }
        switch byte {
        case 34:
            self.inString = true
            self.appendToken(byte)
        case 123, 91, 125, 93, 44, 58:
            self.punctuation(byte)
        case 0...32:
            break
        default:
            self.primitive = true
            self.appendToken(byte)
        }
    }

    mutating func finish() -> Data? {
        if self.primitive {
            self.primitive = false
            self.finishToken(isString: false)
        }
        guard !self.inString, self.containers.isEmpty, self.skippedDepth == 0,
              !self.overflowed, !self.invalid, self.hasBytes else { return nil }
        return Data(self.output)
    }

    private mutating func appendToken(_ byte: UInt8) {
        // Skipped strings may contain megabytes. Only their lexical boundary matters.
        guard self.skippedDepth == 0, !self.skipNextValue else { return }
        if self.token.count < 8192 {
            self.token.append(byte)
        } else {
            self.tokenOverflow = true
        }
    }

    private mutating func finishToken(isString: Bool) {
        defer {
            self.token.removeAll(keepingCapacity: true)
            self.tokenOverflow = false
        }
        guard self.skippedDepth == 0 else { return }
        if self.skipNextValue {
            self.emit(Array("null".utf8))
            self.skipNextValue = false
            return
        }
        if isString, self.containers.last?.expectsKey == true {
            guard !self.tokenOverflow,
                  let key = try? JSONDecoder().decode(String.self, from: Data(self.token))
            else {
                self.invalid = true
                return
            }
            self.containers[self.containers.count - 1].expectsKey = false
            self.emit(self.token)
            // Set only after ':'; the key/colon itself must remain in valid JSON.
            self.pendingSkip = !Self.keys.contains(key)
        } else {
            // Oversized strings still carry presence: null would erase a recorded tool error.
            self.emit(self.tokenOverflow ? Array((isString ? "\"\"" : "null").utf8) : self.token)
        }
    }

    private var pendingSkip = false

    private mutating func punctuation(_ byte: UInt8) {
        if self.skippedDepth > 0 {
            if byte == 123 || byte == 91 { self.skippedDepth += 1 }
            if byte == 125 || byte == 93 { self.skippedDepth -= 1 }
            return
        }
        if self.skipNextValue, byte == 123 || byte == 91 {
            self.emit(Array("null".utf8))
            self.skipNextValue = false
            self.skippedDepth = 1
            return
        }
        self.emit([byte])
        switch byte {
        case 123, 91:
            self.containers.append(Container(isObject: byte == 123, expectsKey: byte == 123))
            if self.containers.count > 64 { self.invalid = true }
        case 125, 93:
            guard let container = self.containers.popLast(), container.isObject == (byte == 125) else {
                self.invalid = true
                return
            }
        case 44:
            if self.containers.last?.isObject == true {
                self.containers[self.containers.count - 1].expectsKey = true
            }
        case 58:
            self.skipNextValue = self.pendingSkip
            self.pendingSkip = false
        default:
            break
        }
    }

    private mutating func emit(_ bytes: [UInt8]) {
        guard !self.overflowed else { return }
        if self.output.count + bytes.count <= 131_072 {
            self.output.append(contentsOf: bytes)
        } else {
            self.overflowed = true
        }
    }
}
