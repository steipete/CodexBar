import Foundation

/// Replays a PTY byte stream onto an in-memory terminal screen and returns what the user would see.
///
/// Stripping CSI sequences and concatenating the leftovers cannot reconstruct a TUI: renderers such as
/// Ink diff each frame against the previous one and emit `ESC[<col>G` jumps over cells whose content did
/// not change. Those skipped cells are never transmitted, so a naive strip silently drops characters —
/// for example Claude's `/usage` panel emits `51%<ESC>[59Gus<ESC>[62Gd` because the previous frame
/// already had an `e` in the column between `us` and `d`. Replaying the cursor motions restores the
/// literal screen text (`51% used`) and with it the keywords the parsers rely on.
///
/// Only the subset of VT100/xterm needed for CLI panels is implemented; unknown sequences are skipped
/// rather than rendered.
public enum TerminalScreenRenderer {
    /// - Parameters:
    ///   - columns: the width the emitter believed it had. This must be the geometry the PTY was opened
    ///     with (`TIOCSWINSZ`), not a guess: absolute column addressing past `columns` is clamped and
    ///     autowrap would land in the wrong place, silently corrupting the text again.
    ///   - rows: the height the PTY was opened with. Lines scrolled off the top are kept as history.
    public static func render(_ text: String, columns: Int, rows: Int) -> String {
        guard text.contains("\u{1B}") else { return text }
        var screen = Screen(columns: max(1, columns), rows: max(1, rows))
        screen.feed(text)
        return screen.text()
    }

    // MARK: - Screen

    private struct Screen {
        private let columns: Int
        private let rows: Int
        private var grid: [[Character]]
        private var scrollback: [[Character]] = []
        private var row = 0
        private var column = 0
        private var pendingWrap = false
        private var scrollTop = 0
        private var scrollBottom: Int
        private var savedCursor: (row: Int, column: Int) = (0, 0)

        init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
            self.grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
            self.scrollBottom = rows - 1
        }

        mutating func feed(_ text: String) {
            let characters = Array(text)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                switch character {
                case "\u{1B}":
                    index = self.consumeEscape(characters, from: index + 1)
                case "\r\n":
                    self.carriageReturn()
                    self.lineFeed()
                    index += 1
                case "\r":
                    self.carriageReturn()
                    index += 1
                case "\n", "\u{0B}", "\u{0C}":
                    // PTYs run with ONLCR, and pipe-captured output has no CR at all, so a bare LF always
                    // starts a new line here rather than dropping straight down the current column.
                    self.carriageReturn()
                    self.lineFeed()
                    index += 1
                case "\u{08}":
                    self.pendingWrap = false
                    self.column = max(0, self.column - 1)
                    index += 1
                case "\t":
                    self.pendingWrap = false
                    self.column = min(self.columns - 1, (self.column / 8 + 1) * 8)
                    index += 1
                case "\u{07}", "\u{00}":
                    index += 1
                default:
                    self.put(character)
                    index += 1
                }
            }
        }

        /// Visible text: scrolled-off lines first, then the live screen, trailing blanks removed.
        func text() -> String {
            var lines = (self.scrollback + self.grid).map { row -> String in
                var characters = row
                while let last = characters.last, last == " " {
                    characters.removeLast()
                }
                return String(characters)
            }
            while let last = lines.last, last.isEmpty {
                lines.removeLast()
            }
            return lines.joined(separator: "\n")
        }

        // MARK: Cursor + text

        private mutating func put(_ character: Character) {
            if self.pendingWrap {
                self.carriageReturn()
                self.lineFeed()
                self.pendingWrap = false
            }
            guard self.row >= 0, self.row < self.rows, self.column >= 0, self.column < self.columns else { return }
            self.grid[self.row][self.column] = character
            if self.column == self.columns - 1 {
                self.pendingWrap = true
            } else {
                self.column += 1
            }
        }

        private mutating func carriageReturn() {
            self.column = 0
            self.pendingWrap = false
        }

        private mutating func lineFeed() {
            self.pendingWrap = false
            if self.row == self.scrollBottom {
                self.scrollUp(1)
            } else if self.row < self.rows - 1 {
                self.row += 1
            }
        }

        private mutating func moveTo(row: Int, column: Int) {
            self.row = min(max(0, row), self.rows - 1)
            self.column = min(max(0, column), self.columns - 1)
            self.pendingWrap = false
        }

        // MARK: Scrolling

        private mutating func scrollUp(_ count: Int) {
            let blank = Array(repeating: Character(" "), count: self.columns)
            for _ in 0..<max(0, count) {
                let evicted = self.grid[self.scrollTop]
                // Only a full-height region represents real history; a partial region is a live viewport.
                if self.scrollTop == 0, self.scrollBottom == self.rows - 1 {
                    self.scrollback.append(evicted)
                }
                self.grid.remove(at: self.scrollTop)
                self.grid.insert(blank, at: self.scrollBottom)
            }
        }

        private mutating func scrollDown(_ count: Int) {
            let blank = Array(repeating: Character(" "), count: self.columns)
            for _ in 0..<max(0, count) {
                self.grid.remove(at: self.scrollBottom)
                self.grid.insert(blank, at: self.scrollTop)
            }
        }

        private mutating func clearAll() {
            self.grid = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
            self.moveTo(row: 0, column: 0)
        }

        // MARK: Escape sequences

        /// Returns the index just past the consumed sequence.
        private mutating func consumeEscape(_ characters: [Character], from start: Int) -> Int {
            guard start < characters.count else { return start }
            switch characters[start] {
            case "[":
                return self.consumeCSI(characters, from: start + 1)
            case "]", "P", "X", "^", "_":
                return Self.consumeString(characters, from: start + 1)
            case "(", ")", "*", "+", "%", "#":
                return min(characters.count, start + 2)
            case "7":
                self.savedCursor = (self.row, self.column)
                return start + 1
            case "8":
                self.moveTo(row: self.savedCursor.row, column: self.savedCursor.column)
                return start + 1
            case "D":
                self.lineFeed()
                return start + 1
            case "E":
                self.carriageReturn()
                self.lineFeed()
                return start + 1
            case "M":
                if self.row == self.scrollTop { self.scrollDown(1) } else { self.row = max(0, self.row - 1) }
                return start + 1
            case "c":
                self.clearAll()
                self.scrollback.removeAll()
                return start + 1
            default:
                return start + 1
            }
        }

        /// Skips an OSC/DCS/SOS/PM/APC string, which ends at BEL or the ST (`ESC \`) terminator.
        private static func consumeString(_ characters: [Character], from start: Int) -> Int {
            var index = start
            while index < characters.count {
                if characters[index] == "\u{07}" { return index + 1 }
                if characters[index] == "\u{1B}" {
                    return index + 1 < characters.count && characters[index + 1] == "\\" ? index + 2 : index + 1
                }
                index += 1
            }
            return index
        }

        private mutating func consumeCSI(_ characters: [Character], from start: Int) -> Int {
            var index = start
            var parameters = ""
            while index < characters.count, Self.isByte(characters[index], in: 0x30...0x3F) {
                parameters.append(characters[index])
                index += 1
            }
            while index < characters.count, Self.isByte(characters[index], in: 0x20...0x2F) {
                index += 1
            }
            guard index < characters.count else { return index }
            let final = characters[index]
            index += 1

            let numbers = parameters
                .drop(while: { !$0.isNumber && $0 != ";" })
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { Int($0) }
            if parameters.hasPrefix("?") {
                // Switching to/from the alternate screen presents a cleared buffer.
                let mode = numbers.first.flatMap(\.self) ?? 0
                if final == "h" || final == "l", [47, 1047, 1049].contains(mode) { self.clearAll() }
                return index
            }
            if !self.applyCursorCSI(final, numbers) {
                self.applyEditingCSI(final, numbers)
            }
            return index
        }

        private static func isByte(_ character: Character, in range: ClosedRange<UInt32>) -> Bool {
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
                return false
            }
            return range.contains(scalar.value)
        }

        /// First parameter, treated as a count: absent, empty and `0` all mean `fallback`.
        private static func count(_ numbers: [Int?], _ position: Int, default fallback: Int) -> Int {
            guard position < numbers.count, let value = numbers[position], value > 0 else { return fallback }
            return value
        }

        /// Returns true when `final` was a cursor-motion sequence.
        private mutating func applyCursorCSI(_ final: Character, _ numbers: [Int?]) -> Bool {
            func count(_ position: Int, _ fallback: Int) -> Int {
                Self.count(numbers, position, default: fallback)
            }
            switch final {
            case "A": self.moveTo(row: self.row - count(0, 1), column: self.column)
            case "B": self.moveTo(row: self.row + count(0, 1), column: self.column)
            case "C": self.moveTo(row: self.row, column: self.column + count(0, 1))
            case "D": self.moveTo(row: self.row, column: self.column - count(0, 1))
            case "E": self.moveTo(row: self.row + count(0, 1), column: 0)
            case "F": self.moveTo(row: self.row - count(0, 1), column: 0)
            case "G", "`": self.moveTo(row: self.row, column: count(0, 1) - 1)
            case "d": self.moveTo(row: count(0, 1) - 1, column: self.column)
            case "H", "f": self.moveTo(row: count(0, 1) - 1, column: count(1, 1) - 1)
            case "s": self.savedCursor = (self.row, self.column)
            case "u": self.moveTo(row: self.savedCursor.row, column: self.savedCursor.column)
            default: return false
            }
            return true
        }

        private mutating func applyEditingCSI(_ final: Character, _ numbers: [Int?]) {
            func count(_ position: Int, _ fallback: Int) -> Int {
                Self.count(numbers, position, default: fallback)
            }
            let mode = numbers.first.flatMap(\.self) ?? 0
            switch final {
            case "J": self.eraseInDisplay(mode)
            case "K": self.eraseInLine(mode)
            case "L": self.insertLines(count(0, 1))
            case "M": self.deleteLines(count(0, 1))
            case "@": self.insertCharacters(count(0, 1))
            case "P": self.deleteCharacters(count(0, 1))
            case "X": self.eraseCharacters(count(0, 1))
            case "S": self.scrollUp(count(0, 1))
            case "T": self.scrollDown(count(0, 1))
            case "r": self.setScrollRegion(
                    top: count(0, 1) - 1,
                    bottom: numbers.count > 1 ? count(1, self.rows) - 1 : self.rows - 1)
            default: break // SGR and other presentation-only sequences do not move text.
            }
        }

        private mutating func setScrollRegion(top: Int, bottom: Int) {
            if top < bottom, top >= 0, bottom < self.rows {
                self.scrollTop = top
                self.scrollBottom = bottom
            }
            self.moveTo(row: 0, column: 0)
        }

        // MARK: Erase + edit

        private mutating func eraseInDisplay(_ mode: Int) {
            switch mode {
            case 0:
                self.eraseInLine(0)
                for row in (self.row + 1)..<self.rows {
                    self.grid[row] = Array(repeating: " ", count: self.columns)
                }
            case 1:
                self.eraseInLine(1)
                for row in 0..<self.row {
                    self.grid[row] = Array(repeating: " ", count: self.columns)
                }
            default:
                self.grid = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
            }
        }

        private mutating func eraseInLine(_ mode: Int) {
            guard self.row >= 0, self.row < self.rows else { return }
            switch mode {
            case 0: for column in self.column..<self.columns {
                    self.grid[self.row][column] = " "
                }
            case 1: for column in 0...min(self.column, self.columns - 1) {
                    self.grid[self.row][column] = " "
                }
            default: self.grid[self.row] = Array(repeating: " ", count: self.columns)
            }
        }

        private mutating func insertLines(_ count: Int) {
            guard self.row >= self.scrollTop, self.row <= self.scrollBottom else { return }
            let blank = Array(repeating: Character(" "), count: self.columns)
            for _ in 0..<count {
                self.grid.remove(at: self.scrollBottom)
                self.grid.insert(blank, at: self.row)
            }
        }

        private mutating func deleteLines(_ count: Int) {
            guard self.row >= self.scrollTop, self.row <= self.scrollBottom else { return }
            let blank = Array(repeating: Character(" "), count: self.columns)
            for _ in 0..<count {
                self.grid.remove(at: self.row)
                self.grid.insert(blank, at: self.scrollBottom)
            }
        }

        private mutating func insertCharacters(_ count: Int) {
            guard self.row >= 0, self.row < self.rows else { return }
            for _ in 0..<count {
                self.grid[self.row].removeLast()
                self.grid[self.row].insert(" ", at: min(self.column, self.columns - 1))
            }
        }

        private mutating func deleteCharacters(_ count: Int) {
            guard self.row >= 0, self.row < self.rows else { return }
            for _ in 0..<count {
                guard self.column < self.grid[self.row].count else { break }
                self.grid[self.row].remove(at: self.column)
                self.grid[self.row].append(" ")
            }
        }

        private mutating func eraseCharacters(_ count: Int) {
            guard self.row >= 0, self.row < self.rows else { return }
            let end = min(self.columns, self.column + max(1, count))
            guard self.column < end else { return }
            for column in self.column..<end {
                self.grid[self.row][column] = " "
            }
        }
    }
}
