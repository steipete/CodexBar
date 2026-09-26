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
        // A primary-origin proxy can overlap an upper display below that display's menu bar.
        let isPrimaryOriginProxy = self.bounds.maxY == 0 && self.displayBounds?.minY != self.bounds.minY
        return self.ownerName == "Control Center"
            && self.isOnscreen
            && abs(self.bounds.minX) <= 1
            && self.bounds.maxY <= 0
            && self.bounds.width > 0
            && self.bounds.height > 0
            && (!self.isWithinDisplayBounds || isPrimaryOriginProxy)
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
    @MainActor static let diagnosticsEnabled = ProcessInfo.processInfo
        .environment["CODEXBAR_STATUS_ITEM_DIAGNOSTICS"] == "1"
    @MainActor private static var diagnosticRecords = 0

    /// Opt-in, bounded stdout trace; never includes window titles, accounts, or provider content.
    @MainActor static func trace(_ stage: String, item: NSStatusItem? = nil, evidence: String = "") {
        guard self.diagnosticsEnabled, self.diagnosticRecords < 128 else { return }
        self.diagnosticRecords += 1
        let name = item?.autosaveName ?? ""
        let window = item?.button?.window
        let records = self.windowInfo()
        let receipt: [String: Any] = [
            "stage": stage, "sequence": self.diagnosticRecords,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "bundle": Bundle.main.bundleIdentifier ?? "unknown",
            "git": Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown",
            "mainThread": Thread.isMainThread, "running": NSApp?.isRunning ?? false,
            "activationPolicy": NSApp?.activationPolicy().rawValue ?? -1,
            "identity": name, "visible": item?.isVisible ?? false, "length": item?.length ?? 0, "evidence": evidence,
            "buttonWindow": window?.windowNumber ?? -1,
            "buttonFrame": NSStringFromRect(item?.button?.frame ?? .zero),
            "windowFrame": NSStringFromRect(window?.frame ?? .zero),
            "screens": NSScreen.screens.map { NSStringFromRect($0.frame) },
            "placeholderWindows": NSApp?.windows.filter {
                $0.identifier?.rawValue.contains(PlaceholderSettingsWindowDecision.swiftUISettingsNameFragment) == true
            }.map { ["number": $0.windowNumber, "frame": NSStringFromRect($0.frame), "visible": $0.isVisible] } ?? [],
            "windowQuerySucceeded": records != nil,
            "controlCenter": self.hostingDiagnostics(name: name, windowInfo: records ?? []),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    static func hostingDiagnostics(name: String, windowInfo: [[String: Any]]) -> [String: Any] {
        let windows = windowInfo.filter {
            ($0[kCGWindowLayer as String] as? Int) == 25
                && ["Control Center", "Control Centre"].contains($0[kCGWindowOwnerName as String] as? String ?? "")
        }
        let matches = windows.filter { !name.isEmpty && ($0[kCGWindowName as String] as? String) == name }
        return [
            "layer25Count": windows.count,
            "layer25Numbers": windows.compactMap { $0[kCGWindowNumber as String] as? Int }.sorted(),
            "unnamedCount": windows.filter { ($0[kCGWindowName as String] as? String ?? "").isEmpty }.count,
            "namedMatches": matches.map { record in
                [
                    "number": record[kCGWindowNumber as String] as? Int ?? -1,
                    "bounds": NSStringFromRect(self.bounds(record[kCGWindowBounds as String]) ?? .zero),
                    "onscreen": (record[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                ] as [String: Any]
            },
        ]
    }

    static func snapshots(matching names: Set<String>) -> [MenuBarStatusItemWindowSnapshot] {
        self.snapshots(
            matching: names,
            windowInfo: self.windowInfo() ?? [],
            screenFrames: NSScreen.screens.map(\.frame))
    }

    static func snapshots(
        matching names: Set<String>,
        windowInfo: [[String: Any]],
        screenFrames: [CGRect])
        -> [MenuBarStatusItemWindowSnapshot]
    {
        guard !names.isEmpty else { return [] }
        // Cocoa screen frames and Quartz window bounds have opposite vertical origins.
        let primaryHeight = screenFrames.first?.height ?? 0
        let displayBounds = screenFrames.map {
            CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height)
        }
        return windowInfo.compactMap { record in
            self.snapshot(record: record, matching: names, displayBounds: displayBounds)
        }
    }

    private static func windowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
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
              ["X", "Y", "Width", "Height"].allSatisfy({ dictionary[$0] is NSNumber })
        else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
