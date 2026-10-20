import Foundation
#if os(macOS) && canImport(FoundationXML)
import FoundationXML
#endif

/// Validates a plugin's monochrome SVG icon. Only plain vector shapes pass: no scripts, styles, links,
/// raster images, foreign objects, entities, or event handlers. Anything else is rejected so the host
/// falls back to the monogram.
public enum ProviderPluginIconSVG {
    public static let maximumBytes = 8 * 1024
    public static let maximumCanvasDimension = 4096.0

    static let allowedElements: Set<String> = [
        "svg", "g", "path", "circle", "ellipse", "rect", "line", "polyline", "polygon", "title", "desc",
    ]

    static let allowedAttributes: Set<String> = [
        "xmlns", "version", "id", "viewBox", "width", "height", "fill", "fill-rule", "clip-rule", "opacity",
        "fill-opacity", "transform", "d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2",
        "points", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
    ]

    /// Geometry, colours and transforms need only these characters. Excluding `\`, `/`, `:`, `;`, quotes and
    /// `*` leaves no CSS escape, comment, declaration or URL syntax, so a value cannot reference anything.
    static let allowedValueCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,#%+-()\t\n\r")

    /// Paint is the only place a function could load an image (`image-set()`, `paint()`, …), so it gets an exact
    /// grammar: a keyword or colour name, a hex colour, or numeric `rgb()`/`rgba()`.
    static let paintPattern = #"^(?:[A-Za-z]+|#[0-9A-Fa-f]{3,8}|rgba?\([0-9.%,\s]+\))$"#

    static func isAllowedValue(_ name: String, _ value: String) -> Bool {
        if name == "xmlns" { return value == "http://www.w3.org/2000/svg" }
        if name == "fill" || name == "stroke" {
            let paint = value.trimmingCharacters(in: .whitespaces)
            return paint.range(of: self.paintPattern, options: .regularExpression) != nil
                && paint.range(of: "url", options: .caseInsensitive) == nil
        }
        return value.unicodeScalars.allSatisfy { self.allowedValueCharacters.contains($0) }
            && value.range(of: "url", options: .caseInsensitive) == nil
    }

    private static func hasBoundedCanvas(_ attributes: [String: String]) -> Bool {
        // Paired dimensions prevent one length plus an extreme aspect ratio from implying a huge canvas.
        guard (attributes["width"] == nil) == (attributes["height"] == nil) else { return false }
        for key in ["width", "height"] {
            guard let value = attributes[key] else { continue }
            let number = value.lowercased().hasSuffix("px") ? String(value.dropLast(2)) : value
            guard let length = Double(number.trimmingCharacters(in: .whitespacesAndNewlines)),
                  length.isFinite, length > 0, length <= self.maximumCanvasDimension
            else { return false }
        }
        guard let viewBox = attributes["viewBox"] else { return attributes["width"] != nil }
        let fields = viewBox.split { $0.isWhitespace || $0 == "," }
        let numbers = fields.compactMap { Double($0) }
        return fields.count == 4 && numbers.count == 4 && numbers.allSatisfy(\.isFinite)
            && numbers[2] > 0 && numbers[2] <= self.maximumCanvasDimension
            && numbers[3] > 0 && numbers[3] <= self.maximumCanvasDimension
    }

    public static func isValid(_ svg: String) -> Bool {
        #if os(macOS)
        guard !svg.isEmpty, svg.utf8.count <= self.maximumBytes,
              svg.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              svg.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let data = svg.data(using: .utf8)
        else { return false }
        let delegate = AllowlistDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && delegate.sawRoot
        #else
        return false
        #endif
    }

    #if os(macOS)

    private final class AllowlistDelegate: NSObject, XMLParserDelegate {
        var sawRoot = false
        private var depth = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:])
        {
            if self.depth == 0 {
                if elementName == "svg", !self.sawRoot { self.sawRoot = true } else { parser.abortParsing() }
            }
            self.depth += 1
            guard ProviderPluginIconSVG.allowedElements.contains(elementName),
                  elementName != "svg" || ProviderPluginIconSVG.hasBoundedCanvas(attributeDict),
                  attributeDict.allSatisfy({ name, value in
                      ProviderPluginIconSVG.allowedAttributes.contains(name)
                          && ProviderPluginIconSVG.isAllowedValue(name, value)
                  })
            else {
                parser.abortParsing()
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?)
        {
            self.depth -= 1
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            parser.abortParsing()
        }
    }
    #endif
}
