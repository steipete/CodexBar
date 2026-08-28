import Foundation

/// Encodes `Encodable` CLI payloads as TOON (Token-Oriented Object Notation).
///
/// This is a presentation-only formatter: it mirrors the same data already emitted by
/// `--format json`, just serialized more compactly for uniform arrays of objects. See
/// https://github.com/toon-format/spec for the format definition this targets (v4.1).
enum ToonFormatter {
    static func encode(_ value: some Encodable) -> String {
        let root = ToonNode()
        do {
            try Self.encodeValue(value, into: root)
        } catch {
            return ""
        }
        return ToonSerializer.render(root)
    }

    fileprivate static func encodeValue(_ value: some Encodable, into node: ToonNode) throws {
        if let date = value as? Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            node.kind = .string(formatter.string(from: date))
            return
        }
        let encoder = ToonTreeEncoder(node: node, codingPath: [])
        try value.encode(to: encoder)
    }

    /// TOON has no representation for NaN/Infinity. `JSONEncoder` rejects them by default
    /// (`EncodingError.invalidValue`) rather than substituting a placeholder number, so this encoder
    /// must fail the same way instead of silently mapping a non-finite provider value to `0` — which
    /// would misrepresent invalid usage/cost data as a valid zero reading.
    fileprivate static func requireFinite(_ value: Double, codingPath: [CodingKey]) throws -> Double {
        guard value.isFinite else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unable to encode \(value) in TOON: only finite numbers are representable."))
        }
        return value
    }
}

// MARK: - Node tree

/// A reference-typed JSON-model node. Reference semantics let nested containers mutate a
/// node in place after it has already been appended to a parent object/array.
final class ToonNode {
    indirect enum Kind {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([ToonNode])
        case object([(key: String, node: ToonNode)])
    }

    var kind: Kind = .null
}

// MARK: - Encoder

private struct ToonTreeEncoder: Encoder {
    let node: ToonNode
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
        self.node.kind = .object([])
        return KeyedEncodingContainer(ToonKeyedContainer<Key>(node: self.node, codingPath: self.codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        self.node.kind = .array([])
        return ToonUnkeyedContainer(node: self.node, codingPath: self.codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ToonSingleValueContainer(node: self.node, codingPath: self.codingPath)
    }
}

private struct ToonKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: ToonNode
    var codingPath: [CodingKey]

    private func child(for key: Key) -> ToonNode {
        let child = ToonNode()
        if case var .object(entries) = self.node.kind {
            entries.append((key.stringValue, child))
            self.node.kind = .object(entries)
        } else {
            self.node.kind = .object([(key.stringValue, child)])
        }
        return child
    }

    mutating func encodeNil(forKey key: Key) throws {
        _ = self.child(for: key)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        self.child(for: key).kind = .bool(value)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        self.child(for: key).kind = .string(value)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        self.child(for: key).kind = try .double(ToonFormatter.requireFinite(value, codingPath: self.codingPath))
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        self.child(for: key).kind = try .double(
            ToonFormatter.requireFinite(Double(value), codingPath: self.codingPath))
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        self.child(for: key).kind = .int(value)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        self.child(for: key).kind = ToonNode.intKind(value)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        self.child(for: key).kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        self.child(for: key).kind = ToonNode.intKind(value)
    }

    mutating func encode(_ value: some Encodable, forKey key: Key) throws {
        try ToonFormatter.encodeValue(value, into: self.child(for: key))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key) -> KeyedEncodingContainer<NestedKey>
    {
        let child = self.child(for: key)
        child.kind = .object([])
        return KeyedEncodingContainer(ToonKeyedContainer<NestedKey>(node: child, codingPath: self.codingPath))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = self.child(for: key)
        child.kind = .array([])
        return ToonUnkeyedContainer(node: child, codingPath: self.codingPath)
    }

    mutating func superEncoder() -> Encoder {
        ToonTreeEncoder(node: self.child(for: Key(stringValue: "super")!), codingPath: self.codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        ToonTreeEncoder(node: self.child(for: key), codingPath: self.codingPath)
    }
}

private struct ToonUnkeyedContainer: UnkeyedEncodingContainer {
    let node: ToonNode
    var codingPath: [CodingKey]
    var count: Int = 0

    private mutating func appendChild() -> ToonNode {
        let child = ToonNode()
        if case var .array(items) = self.node.kind {
            items.append(child)
            self.node.kind = .array(items)
        } else {
            self.node.kind = .array([child])
        }
        self.count += 1
        return child
    }

    mutating func encodeNil() throws {
        _ = self.appendChild()
    }

    mutating func encode(_ value: Bool) throws {
        self.appendChild().kind = .bool(value)
    }

    mutating func encode(_ value: String) throws {
        self.appendChild().kind = .string(value)
    }

    mutating func encode(_ value: Double) throws {
        self.appendChild().kind = try .double(ToonFormatter.requireFinite(value, codingPath: self.codingPath))
    }

    mutating func encode(_ value: Float) throws {
        self.appendChild().kind = try .double(
            ToonFormatter.requireFinite(Double(value), codingPath: self.codingPath))
    }

    mutating func encode(_ value: Int) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        self.appendChild().kind = .int(value)
    }

    mutating func encode(_ value: UInt) throws {
        self.appendChild().kind = ToonNode.intKind(value)
    }

    mutating func encode(_ value: UInt8) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        self.appendChild().kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        self.appendChild().kind = ToonNode.intKind(value)
    }

    mutating func encode(_ value: some Encodable) throws {
        try ToonFormatter.encodeValue(value, into: self.appendChild())
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type) -> KeyedEncodingContainer<NestedKey>
    {
        let child = self.appendChild()
        child.kind = .object([])
        return KeyedEncodingContainer(ToonKeyedContainer<NestedKey>(node: child, codingPath: self.codingPath))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = self.appendChild()
        child.kind = .array([])
        return ToonUnkeyedContainer(node: child, codingPath: self.codingPath)
    }

    mutating func superEncoder() -> Encoder {
        ToonTreeEncoder(node: self.appendChild(), codingPath: self.codingPath)
    }
}

private struct ToonSingleValueContainer: SingleValueEncodingContainer {
    let node: ToonNode
    var codingPath: [CodingKey]

    mutating func encodeNil() throws {
        self.node.kind = .null
    }

    mutating func encode(_ value: Bool) throws {
        self.node.kind = .bool(value)
    }

    mutating func encode(_ value: String) throws {
        self.node.kind = .string(value)
    }

    mutating func encode(_ value: Double) throws {
        self.node.kind = try .double(ToonFormatter.requireFinite(value, codingPath: self.codingPath))
    }

    mutating func encode(_ value: Float) throws {
        self.node.kind = try .double(ToonFormatter.requireFinite(Double(value), codingPath: self.codingPath))
    }

    mutating func encode(_ value: Int) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        self.node.kind = .int(value)
    }

    mutating func encode(_ value: UInt) throws {
        self.node.kind = ToonNode.intKind(value)
    }

    mutating func encode(_ value: UInt8) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        self.node.kind = .int(Int64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        self.node.kind = ToonNode.intKind(value)
    }

    mutating func encode(_ value: some Encodable) throws {
        try ToonFormatter.encodeValue(value, into: self.node)
    }
}

extension ToonNode {
    fileprivate static func intKind(_ value: some BinaryInteger) -> Kind {
        if let exact = Int64(exactly: value) {
            .int(exact)
        } else {
            .double(Double(value))
        }
    }
}

// MARK: - Serializer

enum ToonSerializer {
    static func render(_ root: ToonNode) -> String {
        self.renderValue(key: nil, node: root, indent: 0).joined(separator: "\n")
    }

    private static func pad(_ indent: Int) -> String {
        String(repeating: "  ", count: indent)
    }

    private static func renderValue(key: String?, node: ToonNode, indent: Int) -> [String] {
        switch node.kind {
        case .null: [self.scalarLine(key, "null", indent)]
        case let .bool(value): [self.scalarLine(key, value ? "true" : "false", indent)]
        case let .int(value): [self.scalarLine(key, String(value), indent)]
        case let .double(value): [self.scalarLine(key, self.formatNumber(value), indent)]
        case let .string(value): [self.scalarLine(key, self.quoteIfNeeded(value), indent)]
        case let .array(items): self.renderArray(key: key, items: items, indent: indent)
        case let .object(entries): self.renderObject(key: key, entries: entries, indent: indent)
        }
    }

    private static func scalarLine(_ key: String?, _ literal: String, _ indent: Int) -> String {
        let prefix = self.pad(indent)
        guard let key else { return "\(prefix)\(literal)" }
        return "\(prefix)\(self.quoteKeyIfNeeded(key)): \(literal)"
    }

    private static func renderObject(key: String?, entries: [(key: String, node: ToonNode)], indent: Int) -> [String] {
        guard !entries.isEmpty else {
            let prefix = self.pad(indent)
            guard let key else { return ["\(prefix){}"] }
            return ["\(prefix)\(self.quoteKeyIfNeeded(key)):"]
        }
        var lines: [String] = []
        var childIndent = indent
        if let key {
            lines.append("\(self.pad(indent))\(self.quoteKeyIfNeeded(key)):")
            childIndent = indent + 1
        }
        for entry in entries {
            lines.append(contentsOf: self.renderValue(key: entry.key, node: entry.node, indent: childIndent))
        }
        return lines
    }

    private enum ArrayForm {
        case empty
        case inlinePrimitives
        case tabular(fields: [String])
        case list
    }

    /// Tabular form requires every row to carry the *exact* same field set in the same order. A
    /// JSON encoder that uses `encodeIfPresent` for optional fields (as CodexBar's payloads do) omits
    /// the key entirely when the value is nil — it never emits `null`. Collapsing rows with different
    /// field sets into one table would require fabricating `null` for the columns a given row never
    /// had, which fails to round-trip back to the source JSON (an absent key is not the same as a
    /// present key with a null value). Rows with differing field sets fall back to list form instead,
    /// where each row only ever prints the fields it actually has.
    private static func classify(_ items: [ToonNode]) -> ArrayForm {
        guard !items.isEmpty else { return .empty }

        if items.allSatisfy(self.isScalar) {
            return .inlinePrimitives
        }

        guard case let .object(firstEntries) = items[0].kind else { return .list }
        let fields = firstEntries.map(\.key)
        guard !fields.isEmpty else { return .list }

        for item in items {
            guard case let .object(entries) = item.kind else { return .list }
            guard entries.map(\.key) == fields else { return .list }
            guard entries.allSatisfy({ self.isScalar($0.node) }) else { return .list }
        }
        return .tabular(fields: fields)
    }

    private static func isScalar(_ node: ToonNode) -> Bool {
        switch node.kind {
        case .null, .bool, .int, .double, .string: true
        case .array, .object: false
        }
    }

    private static func scalarLiteral(_ node: ToonNode) -> String {
        switch node.kind {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .double(value): self.formatNumber(value)
        case let .string(value): self.quoteIfNeeded(value)
        case .array, .object: "null"
        }
    }

    private static func renderArray(key: String?, items: [ToonNode], indent: Int) -> [String] {
        let prefix = self.pad(indent)
        let headerKey = key.map(self.quoteKeyIfNeeded) ?? ""

        guard !items.isEmpty else {
            if key != nil { return ["\(prefix)\(headerKey): []"] }
            return ["\(prefix)[]"]
        }

        switch self.classify(items) {
        case .empty:
            return ["\(prefix)\(headerKey): []"]

        case .inlinePrimitives:
            let values = items.map(self.scalarLiteral).joined(separator: ",")
            return ["\(prefix)\(headerKey)[\(items.count)]: \(values)"]

        case let .tabular(fields):
            let fieldList = fields.map(self.quoteKeyIfNeeded).joined(separator: ",")
            var lines = ["\(prefix)\(headerKey)[\(items.count)]{\(fieldList)}:"]
            let rowIndent = self.pad(indent + 1)
            for item in items {
                guard case let .object(entries) = item.kind else { continue }
                let cells = entries.map { self.scalarLiteral($0.node) }
                lines.append(rowIndent + cells.joined(separator: ","))
            }
            return lines

        case .list:
            var lines = ["\(prefix)\(headerKey)[\(items.count)]:"]
            for item in items {
                lines.append(contentsOf: self.renderListItem(item, indent: indent + 1))
            }
            return lines
        }
    }

    private static func renderListItem(_ node: ToonNode, indent: Int) -> [String] {
        switch node.kind {
        case let .object(entries):
            guard !entries.isEmpty else { return ["\(self.pad(indent))-"] }
            let first = entries[0]
            let firstLines = self.renderValue(key: first.key, node: first.node, indent: indent + 1)
            var lines = self.mergeHyphen(firstLines, indent: indent)
            for entry in entries.dropFirst() {
                lines.append(contentsOf: self.renderValue(key: entry.key, node: entry.node, indent: indent + 1))
            }
            return lines

        case let .array(items):
            let arrayLines = self.renderArray(key: nil, items: items, indent: indent + 1)
            return self.mergeHyphen(arrayLines, indent: indent)

        default:
            return ["\(self.pad(indent))- \(self.scalarLiteral(node))"]
        }
    }

    /// Collapses a rendered value's first line onto a `- ` marker, matching TOON's convention
    /// for list items whose value spans multiple lines (e.g. `- id: 1` then `  name: First`).
    private static func mergeHyphen(_ lines: [String], indent: Int) -> [String] {
        guard let first = lines.first else { return ["\(self.pad(indent))-"] }
        let indentWidth = (indent + 1) * 2
        let content = first.count > indentWidth ? String(first.dropFirst(indentWidth)) : first
        var merged = ["\(self.pad(indent))- \(content)"]
        merged.append(contentsOf: lines.dropFirst())
        return merged
    }

    // MARK: Literal formatting

    private static func formatNumber(_ value: Double) -> String {
        // Non-finite doubles never reach here: every encode site rejects them via
        // `ToonFormatter.requireFinite` before a `.double` node can be constructed.
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(value)
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text
    }

    /// Matches TOON's numeric-like quoting rule: `^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`.
    private static func looksNumeric(_ value: String) -> Bool {
        var scalars = Substring(value).unicodeScalars[...]
        if let first = scalars.first, first == "+" || first == "-" {
            scalars.removeFirst()
        }
        func consumeDigits() -> Bool {
            var consumed = false
            while let first = scalars.first, ("0"..."9").contains(first) {
                scalars.removeFirst()
                consumed = true
            }
            return consumed
        }
        guard consumeDigits() else { return false }
        if scalars.first == "." {
            scalars.removeFirst()
            guard consumeDigits() else { return false }
        }
        if let exponentMarker = scalars.first, exponentMarker == "e" || exponentMarker == "E" {
            scalars.removeFirst()
            if let sign = scalars.first, sign == "+" || sign == "-" {
                scalars.removeFirst()
            }
            guard consumeDigits() else { return false }
        }
        return scalars.isEmpty
    }

    private static func needsQuoting(_ value: String) -> Bool {
        if value.isEmpty { return true }
        if value.first == " " || value.last == " " { return true }
        if value == "true" || value == "false" || value == "null" { return true }
        if self.looksNumeric(value) { return true }
        if value.hasPrefix("-") || value.hasPrefix("#") { return true }
        for scalar in value.unicodeScalars {
            switch scalar {
            case ":", "\"", "\\", "[", "]", "{", "}", ",":
                return true
            default:
                if scalar.value < 0x20 { return true }
            }
        }
        return false
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        guard self.needsQuoting(value) else { return value }
        return "\"\(self.escape(value))\""
    }

    private static func quoteKeyIfNeeded(_ key: String) -> String {
        let isBareKey = key.range(of: "^[A-Za-z_][A-Za-z0-9_.]*$", options: .regularExpression) != nil
        guard !isBareKey else { return key }
        return "\"\(self.escape(key))\""
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
