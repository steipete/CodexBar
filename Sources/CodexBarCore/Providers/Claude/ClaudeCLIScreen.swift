import Foundation

/// Replays the cursor and erase operations used by Claude's usage/status panels, without terminal history.
struct ClaudeCLIScreen {
    static let columns = 160
    // Claude's /usage panel (2.1.270 to 2.1.294 at least) puts session stats above the quota rows and an insights
    // list below them, about 100 rows for a heavy user. In the default inline renderer, rows that scroll past the top
    // are out of reach of the diff redraws and missing from the replayed screen, "Current session" first, so keep
    // the PTY well taller than the panel.
    static let rows = 200
    private static let maxParameter = max(Self.columns, Self.rows)
    private static let blank = Array(repeating: Character(" "), count: Self.columns)
    private var lines = Array(repeating: Self.blank, count: Self.rows)
    private var row = 0
    private var column = 0

    static func render(_ text: String, preservePlainReports: Bool = false) -> String {
        var screen = Self()
        var replay = !preservePlainReports
        var plain = ""
        // Consume complete OSC strings before interpreting text, including BEL and ST terminators.
        let pattern = #"\u001B(?:\[[0-?]*[ -/]*[@-~]?|\][\s\S]*?(?:\u0007|\u001B\\|$)|.)|[^\u001B]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let token = text[range]
            if token.hasPrefix("\u{1b}[") {
                if screen.applyCSI(token.dropFirst(2)) { replay = true }
            } else if !token.hasPrefix("\u{1b}") {
                if !replay {
                    plain.append(contentsOf: token)
                    replay = token.contains("\u{8}")
                }
                for character in token {
                    screen.write(character)
                }
            }
        }
        if !replay { return plain }
        var result = screen.lines.map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed().filter { $0 != "\u{0}" })
        }
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    private mutating func newline() {
        self.column = 0
        self.row += 1
        if self.row == Self.rows {
            self.lines.removeFirst()
            self.lines.append(Self.blank)
            self.row -= 1
        }
    }

    private mutating func write(_ character: Character) {
        switch character {
        case "\r": self.column = 0
        case "\n", "\r\n": self.newline()
        case "\u{8}": self.column = max(0, min(self.column, Self.columns - 1) - 1)
        case "\t": self.column = min(Self.columns - 1, (self.column / 8 + 1) * 8)
        default:
            guard character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return }
            let width = Self.cellWidth(character)
            if width == 0 {
                var previous = min(self.column, Self.columns) - 1
                if previous >= 0, self.lines[self.row][previous] == "\u{0}" { previous -= 1 }
                guard previous >= 0 else { return }
                let joined = String(self.lines[self.row][previous]) + String(character)
                if joined.count == 1, let glyph = joined.first { self.lines[self.row][previous] = glyph }
                return
            }
            if self.column + width > Self.columns { self.newline() }
            for cell in self.column..<(self.column + width) {
                self.clearCell(row: self.row, column: cell)
            }
            self.lines[self.row][self.column] = character
            if width == 2 { self.lines[self.row][self.column + 1] = "\u{0}" }
            self.column += width
        }
    }

    private mutating func applyCSI(_ sequence: Substring) -> Bool {
        guard let command = sequence.last, "ABCDGHfKJ".contains(command) else { return false }
        let parameters = sequence.dropLast()
        guard parameters.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) else { return false }
        // Limit parameter count and magnitude before arithmetic or indexing, even for overflowing decimal input.
        let values = parameters.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).prefix(2)
            .map { $0.isEmpty ? 0 : min(Int($0) ?? Self.maxParameter, Self.maxParameter) }
        let mode = values.first ?? 0
        let amount = max(1, mode)
        guard !"KJ".contains(command) || (0...2).contains(mode) else { return false }
        self.column = min(self.column, Self.columns - 1)
        switch command {
        case "A": self.row = max(0, self.row - amount)
        case "B": self.row = min(Self.rows - 1, self.row + amount)
        case "C": self.column = min(Self.columns - 1, self.column + amount)
        case "D": self.column = max(0, self.column - amount)
        case "G": self.column = min(Self.columns - 1, amount - 1)
        case "H", "f":
            self.row = min(Self.rows - 1, amount - 1)
            self.column = min(Self.columns - 1, max(1, values.dropFirst().first ?? 0) - 1)
        case "K", "J":
            let cursor = self.row * Self.columns + self.column
            let start = command == "K" ? self.row * Self.columns : 0
            let end = command == "K" ? (self.row + 1) * Self.columns : Self.rows * Self.columns
            let range = (mode == 0 ? cursor : start)..<(mode == 1 ? cursor + 1 : end)
            for cell in range {
                self.clearCell(row: cell / Self.columns, column: cell % Self.columns)
            }
        default: return false
        }
        return true
    }

    private mutating func clearCell(row: Int, column: Int) {
        if column > 0, self.lines[row][column] == "\u{0}" { self.lines[row][column - 1] = " " }
        if column + 1 < Self.columns, self.lines[row][column + 1] == "\u{0}" { self.lines[row][column + 1] = " " }
        self.lines[row][column] = " "
    }

    private static func cellWidth(_ character: Character) -> Int {
        if character.isASCII { return 1 }
        let scalars = character.unicodeScalars
        guard let base = scalars.first(where: {
            ![.nonspacingMark, .enclosingMark, .format].contains($0.properties.generalCategory)
        }) else { return 0 }
        if scalars.contains(where: \.properties.isEmojiPresentation)
            || (base.properties.isEmoji && scalars.contains(where: { $0.value == 0xFE0F })) { return 2 }
        return self.wideRanges.contains { $0.contains(base.value) } ? 2 : 1
    }

    /// Wide/fullwidth glyphs occupy two cells; usage-bar block characters remain one cell.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,
        0x2E80...0x303E,
        0x3041...0x33FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xA000...0xA4CF,
        0xA960...0xA97F,
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE10...0xFE19,
        0xFE30...0xFE6F,
        0xFF00...0xFF60,
        0xFFE0...0xFFE6,
        0x16FE0...0x16FE4,
        0x17000...0x18AFF,
        0x1B000...0x1B2FF,
        0x1F200...0x1F251,
        0x20000...0x2FFFD,
        0x30000...0x3FFFD,
    ]
}
