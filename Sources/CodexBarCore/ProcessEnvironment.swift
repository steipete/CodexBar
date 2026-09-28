/// Retains environment values for execution while keeping automatic diagnostics count-only.
@propertyWrapper
public struct ProcessEnvironment: Sendable, CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
    public var wrappedValue: [String: String]

    public init(wrappedValue: [String: String]) {
        self.wrappedValue = wrappedValue
    }

    public var description: String {
        "ProcessEnvironment(\(self.wrappedValue.count) entries; redacted)"
    }

    public var debugDescription: String {
        self.description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["entryCount": self.wrappedValue.count], displayStyle: .struct)
    }
}
