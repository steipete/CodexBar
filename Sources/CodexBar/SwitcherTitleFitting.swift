import CoreGraphics
import Foundation

/// Width-bounded title shortening shared by account switchers. Measurement is injected so callers use the
/// switcher's own font and tests can use a deterministic measurer.
enum SwitcherTitleFitting {
    static func truncateTail(_ text: String, toFit width: CGFloat, measure: (String) -> CGFloat) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if measure(trimmed) <= width {
            return trimmed
        }

        let ellipsis = "…"
        guard measure(ellipsis) < width else { return ellipsis }

        var candidate = ""
        for character in trimmed {
            let next = candidate + String(character)
            if measure(next + ellipsis) > width {
                break
            }
            candidate = next
        }
        return candidate.isEmpty ? ellipsis : candidate + ellipsis
    }

    static func truncateMiddle(_ text: String, toFit width: CGFloat, measure: (String) -> CGFloat) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if measure(trimmed) <= width {
            return trimmed
        }

        let ellipsis = "…"
        guard measure(ellipsis) < width else { return ellipsis }

        var prefix = ""
        var suffix = ""
        var prefixIndex = trimmed.startIndex
        var suffixIndex = trimmed.endIndex
        var best = ellipsis
        var takeSuffixNext = true

        while prefixIndex < suffixIndex {
            let nextPrefix: String
            let nextSuffix: String
            if takeSuffixNext {
                let previousIndex = trimmed.index(before: suffixIndex)
                nextPrefix = prefix
                nextSuffix = String(trimmed[previousIndex]) + suffix
                suffixIndex = previousIndex
            } else {
                nextPrefix = prefix + String(trimmed[prefixIndex])
                nextSuffix = suffix
                prefixIndex = trimmed.index(after: prefixIndex)
            }

            let candidate = nextPrefix + ellipsis + nextSuffix
            if measure(candidate) > width {
                break
            }

            prefix = nextPrefix
            suffix = nextSuffix
            best = candidate
            takeSuffixNext.toggle()
        }

        return best
    }
}
