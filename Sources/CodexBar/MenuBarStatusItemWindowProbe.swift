import AppKit
import CoreGraphics
import Foundation

struct MenuBarStatusItemWindowSnapshot: Equatable, CustomStringConvertible {
    let name: String
    let ownerName: String
    let bounds: CGRect
    let isOnscreen: Bool
    let displayBounds: CGRect?

    var isWithinDisplayBounds: Bool {
        guard let displayBounds else { return false }
        return displayBounds.contains(self.bounds)
    }

    var isTahoeBlockedProxy: Bool {
        self.ownerName == "Control Center"
            && self.isOnscreen
            && abs(self.bounds.minX) <= 1
            && self.bounds.maxY <= 0
            && self.bounds.width > 0
            && self.bounds.height > 0
            && !self.isWithinDisplayBounds
    }

    var description: String {
        let display = self.displayBounds.map {
            "display=\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))"
        } ?? "display=nil"
        return "name=\(self.name),owner=\(self.ownerName),x=\(Int(self.bounds.minX)),"
            + "w=\(Int(self.bounds.width)),onscreen=\(self.isOnscreen),"
            + "withinDisplay=\(self.isWithinDisplayBounds),\(display)"
    }
}

enum MenuBarStatusItemWindowProbe {
    static func snapshots(matching names: Set<String>) -> [MenuBarStatusItemWindowSnapshot] {
        self.snapshots(
            matching: names,
            windowInfo: self.windowInfo(),
            displayBounds: NSScreen.screens.map(\.frame))
    }

    static func snapshots(
        matching names: Set<String>,
        windowInfo: [[String: Any]],
        displayBounds: [CGRect])
        -> [MenuBarStatusItemWindowSnapshot]
    {
        guard !names.isEmpty else { return [] }
        return windowInfo.compactMap { record in
            self.snapshot(record: record, matching: names, displayBounds: displayBounds)
        }
    }

    private static func windowInfo() -> [[String: Any]] {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windows
    }

    private static func snapshot(
        record: [String: Any],
        matching names: Set<String>,
        displayBounds: [CGRect])
        -> MenuBarStatusItemWindowSnapshot?
    {
        guard let name = record[kCGWindowName as String] as? String,
              names.contains(name),
              let bounds = self.bounds(record[kCGWindowBounds as String])
        else { return nil }
        let ownerName = record[kCGWindowOwnerName as String] as? String ?? "unknown"
        let isOnscreen = (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
            ?? record[kCGWindowIsOnscreen as String] as? Bool
            ?? false
        return MenuBarStatusItemWindowSnapshot(
            name: name,
            ownerName: ownerName,
            bounds: bounds,
            isOnscreen: isOnscreen,
            displayBounds: displayBounds.first { $0.intersects(bounds) })
    }

    private static func bounds(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any],
              let x = self.double(dictionary["X"]),
              let y = self.double(dictionary["Y"]),
              let width = self.double(dictionary["Width"]),
              let height = self.double(dictionary["Height"])
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let double as Double:
            double
        case let int as Int:
            Double(int)
        case let cgFloat as CGFloat:
            Double(cgFloat)
        default:
            nil
        }
    }
}
