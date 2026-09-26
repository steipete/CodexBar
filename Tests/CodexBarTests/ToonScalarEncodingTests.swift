import Foundation
import Testing
@testable import CodexBarCLI

struct ToonScalarEncodingTests {
    private struct Scalars: Encodable {
        let signed = Int.min
        let signed8 = Int8.min
        let signed16 = Int16.min
        let signed32 = Int32.min
        let signed64 = Int64.min
        let unsigned = UInt.max
        let unsigned8 = UInt8.max
        let unsigned16 = UInt16.max
        let unsigned32 = UInt32.max
        let unsigned64 = UInt64.max
        let float = Float(1.25)
        let double = Double(1.25)
        let boolean = true
        let string = "literal, quoted"
    }

    private struct ScalarArray: Encodable {
        func encode(to encoder: Encoder) throws {
            let value = Scalars()
            var container = encoder.unkeyedContainer()
            try container.encode(value.signed)
            try container.encode(value.signed8)
            try container.encode(value.signed16)
            try container.encode(value.signed32)
            try container.encode(value.signed64)
            try container.encode(value.unsigned)
            try container.encode(value.unsigned8)
            try container.encode(value.unsigned16)
            try container.encode(value.unsigned32)
            try container.encode(value.unsigned64)
            try container.encode(value.float)
            try container.encode(value.double)
            try container.encode(value.boolean)
            try container.encode(value.string)
            try container.encodeNil()
        }
    }

    private static let expectedScalars = [
        "-9223372036854775808", "-128", "-32768", "-2147483648", "-9223372036854775808",
        "1.8446744073709552e+19", "255", "65535", "4294967295", "1.8446744073709552e+19",
        "1.25", "1.25", "true", #""literal, quoted""#,
    ]

    @Test
    func `keyed scalar overloads preserve numeric bounds and field order`() {
        let keys = [
            "signed", "signed8", "signed16", "signed32", "signed64",
            "unsigned", "unsigned8", "unsigned16", "unsigned32", "unsigned64",
            "float", "double", "boolean", "string",
        ]
        let expected = zip(keys, Self.expectedScalars).map { "\($0): \($1)" }.joined(separator: "\n")
        #expect(ToonFormatter.encode(Scalars()) == expected)
    }

    @Test
    func `unkeyed scalar overloads preserve numeric bounds and explicit null`() {
        let expected = "[15]: " + (Self.expectedScalars + ["null"]).joined(separator: ",")
        #expect(ToonFormatter.encode(ScalarArray()) == expected)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func `nonfinite floats fail closed in every container`(value: Float) {
        struct Keyed: Encodable { let value: Float }
        #expect(ToonFormatter.encode(value).isEmpty)
        #expect(ToonFormatter.encode([value]).isEmpty)
        #expect(ToonFormatter.encode(Keyed(value: value)).isEmpty)
    }
}
