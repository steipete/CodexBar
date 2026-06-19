import Foundation

extension CostUsageScanner {
    static func extractCodexTurnContextModel(from bytes: Data) -> String? {
        guard let text = truncatedUTF8String(from: bytes) else { return nil }
        let object = text[...]
        guard Self.extractJSONStringField("type", from: object, atDepth: 1) == "turn_context",
              let payloadText = Self.extractJSONObjectField("payload", from: object, atDepth: 1)
        else { return nil }

        let payloadModel = Self.extractJSONStringField("model", from: payloadText, atDepth: 1)
            ?? Self.extractJSONStringField("model_name", from: payloadText, atDepth: 1)
        if let payloadModel { return payloadModel }

        guard let infoText = Self.extractJSONObjectField("info", from: payloadText, atDepth: 1) else { return nil }
        return Self.extractJSONStringField("model", from: infoText, atDepth: 1)
            ?? Self.extractJSONStringField("model_name", from: infoText, atDepth: 1)
    }

    static func truncatedUTF8String(from bytes: Data) -> String? {
        for dropCount in 0...min(4, bytes.count) {
            let end = bytes.count - dropCount
            if let text = String(bytes: bytes.prefix(end), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    static func extractJSONStringField(
        _ field: String,
        from text: Substring,
        atDepth targetDepth: Int) -> String?
    {
        self.extractJSONField(field, from: text, atDepth: targetDepth) { text, index in
            guard index < text.endIndex, text[index] == "\"" else { return nil }
            let value = Self.parseJSONString(in: text, index: &index)
            return value?.isEmpty == true ? nil : value
        }
    }

    static func extractJSONObjectField(
        _ field: String,
        from text: Substring,
        atDepth targetDepth: Int) -> Substring?
    {
        self.extractJSONField(field, from: text, atDepth: targetDepth) { text, index in
            guard index < text.endIndex, text[index] == "{" else { return nil }
            return text[index...]
        }
    }

    static func extractJSONIntField(
        _ field: String,
        from text: Substring,
        atDepth targetDepth: Int) -> Int?
    {
        self.extractJSONField(field, from: text, atDepth: targetDepth) { text, index in
            Self.parseJSONInt(in: text, index: &index)
        }
    }

    static func extractJSONField<T>(
        _ field: String,
        from text: Substring,
        atDepth targetDepth: Int,
        parseValue: (Substring, inout String.Index) -> T?) -> T?
    {
        var index = text.startIndex
        var depth = 0

        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
                text.formIndex(after: &index)
            } else if character == "}" {
                depth -= 1
                text.formIndex(after: &index)
            } else if character == "\"" {
                var valueIndex = index
                guard let key = Self.parseJSONString(in: text, index: &valueIndex) else { return nil }
                defer { index = valueIndex }
                guard depth == targetDepth, key == field else { continue }

                Self.skipJSONWhitespace(in: text, index: &valueIndex)
                guard valueIndex < text.endIndex, text[valueIndex] == ":" else { continue }

                text.formIndex(after: &valueIndex)
                Self.skipJSONWhitespace(in: text, index: &valueIndex)
                if let value = parseValue(text, &valueIndex) {
                    return value
                }
            } else {
                text.formIndex(after: &index)
            }
        }

        return nil
    }

    static func parseJSONString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        text.formIndex(after: &index)
        var value = ""
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                text.formIndex(after: &index)
                return value
            } else {
                value.append(character)
            }
            text.formIndex(after: &index)
        }

        return nil
    }

    static func parseJSONInt(in text: Substring, index: inout String.Index) -> Int? {
        var sign = 1
        if index < text.endIndex, text[index] == "-" {
            sign = -1
            text.formIndex(after: &index)
        }

        var value = 0
        var sawDigit = false
        while index < text.endIndex, let digit = text[index].wholeNumberValue {
            sawDigit = true
            value = (value * 10) + digit
            text.formIndex(after: &index)
        }
        return sawDigit ? value * sign : nil
    }

    static func skipJSONWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            text.formIndex(after: &index)
        }
    }
}
