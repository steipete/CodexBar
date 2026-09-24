import AppKit
import CloudKit
import CodexBarCore
import SwiftUI
import Testing
import Vision
@testable import CodexBar

@MainActor
struct CloudSyncDeviceRemovalTests {
    @Test
    func `overlapping removals coalesce per device and allow later retries`() async {
        let state = CloudSyncState()
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        defer {
            startedSignal.finish()
            releaseSignal.finish()
        }
        var calls: [String] = []
        state.removeDeviceHandler = { deviceID in
            calls.append(deviceID)
            if calls.count == 1 {
                startedSignal.yield(())
                for await _ in release {
                    break
                }
            }
        }
        let first = Task { await state.requestDeviceRemoval("old") }
        defer { first.cancel() }
        var events = started.makeAsyncIterator()
        _ = await events.next()

        await state.requestDeviceRemoval("old")
        await state.requestDeviceRemoval("other")
        #expect(calls == ["old", "other"])
        releaseSignal.yield(())
        await first.value
        await state.requestDeviceRemoval("old")
        #expect(calls == ["old", "other", "old"])
    }

    @Test
    func `device selection waits for queued fetched snapshots to be applied`() async {
        let state = CloudSyncState()
        let queue = CloudSyncDelegateEventQueue()
        queue.enqueue {
            try? await Task.sleep(for: .milliseconds(50))
            await MainActor.run { state.fleetSnapshots = Self.makeState().fleetSnapshots }
        }

        await queue.drain()

        #expect(Set(state.recordNames(removing: "old", currentDeviceID: "current")) == [
            "snapshot-old-claude", "snapshot-old-codex",
        ])
    }

    @Test
    func `removing a duplicate Mac selects its device and all accounts without matching hostnames`() {
        let state = Self.makeState()
        #expect(Set(state.recordNames(removing: "old", currentDeviceID: "current")) == [
            "device-old", "snapshot-old-claude", "snapshot-old-codex",
        ])
        #expect(state.recordNames(removing: "current", currentDeviceID: "current").isEmpty)
        #expect(state.recordNames(removing: "unknown", currentDeviceID: "current").isEmpty)
    }

    @Test
    func `confirmed removal clears fleet records and metadata but preserves shared configuration`() async throws {
        let state = Self.makeState()
        let names = state.recordNames(removing: "old", currentDeviceID: "current")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CloudSyncPersistence(fileURL: directory.appendingPathComponent("sync.json"))
        var envelope = CloudSyncPersistence.Envelope(
            stateSerialization: nil,
            encodedSystemFields: [:],
            dirtyProviders: ["claude"],
            preferencesDirty: true,
            fleetDevices: state.fleetDevices,
            fleetSnapshots: state.fleetSnapshots)
        for name in names + ["prefs-global", "intent-claude"] {
            envelope.encodedSystemFields[name] = Data([1])
            envelope.recordMetadata[name] = .init(recordType: "fixture")
        }
        try persistence.save(envelope)
        let engine = CloudSyncEngine(
            settings: Self.makeSettings(directory: directory), state: state, persistence: persistence)

        await engine.applyDeletedRecords(names)
        await engine.applyDeletedRecords(names)

        let saved = persistence.load()
        #expect(Set(saved.fleetDevices.keys) == ["device-current", "device-other"])
        #expect(Set(saved.fleetSnapshots.keys) == ["snapshot-current", "snapshot-other"])
        #expect(Set(saved.encodedSystemFields.keys) == ["prefs-global", "intent-claude"])
        #expect(Set(saved.recordMetadata.keys) == ["prefs-global", "intent-claude"])
        #expect(saved.dirtyProviders == ["claude"])
        #expect(saved.preferencesDirty)
        #expect(Set(state.fleetDevices.keys) == Set(saved.fleetDevices.keys))
        #expect(Set(state.fleetSnapshots.keys) == Set(saved.fleetSnapshots.keys))
    }

    @Test
    func `disabled engine does not remove records or access CloudKit`() async {
        let state = Self.makeState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CloudSyncEngine(
            settings: Self.makeSettings(directory: directory),
            state: state,
            persistence: CloudSyncPersistence(fileURL: directory.appendingPathComponent("sync.json")))
        await engine.removeDevice("old")
        #expect(state.fleetDevices.count == 3)
        #expect(state.fleetSnapshots.count == 4)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("sync.json").path))
    }

    @Test
    func `render synthetic Macs list`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ICLOUD_PROOF_PATH"] else { return }
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            try Self.renderPane(path: path)
        }
    }

    private static func renderPane(path: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = Self.makeSettings(directory: directory)
        settings.iCloudSyncEnabled = true
        let view = ICloudSyncPane(settings: settings, state: Self.makeState())
            .environment(\.colorScheme, .light)
            .environment(\.accessibilityEnabled, true)
            .frame(width: 560, height: 680)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
        try Self.verifyRemoveButtons(in: bitmap)
    }

    private static func verifyRemoveButtons(in bitmap: NSBitmapImageRep) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        let image = try #require(bitmap.cgImage)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (text: String, y: CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text.replacingOccurrences(of: " ", with: "").lowercased(), observation.boundingBox.midY)
        }
        let current = try #require(lines.first { $0.text.contains("thismac") })
        let rows = lines.filter { $0.text.contains("examplemacbook") || $0.text.contains("exampledesktop") }
        let buttons = lines.filter { $0.text.contains("remove") }
        #expect(rows.count == 3)
        #expect(buttons.count == 2)
        for row in rows {
            let isCurrent = abs(row.y - current.y) < 0.025
            #expect(buttons.filter { abs($0.y - row.y) < 0.025 }.count == (isCurrent ? 0 : 1))
        }
    }

    private static func makeSettings(directory: URL) -> SettingsStore {
        let defaults = InMemoryUserDefaults()
        defaults.set("current", forKey: "iCloudSyncDeviceID")
        return testSettingsStore(suiteName: directory.lastPathComponent, userDefaults: defaults)
    }

    private static func makeState() -> CloudSyncState {
        let state = CloudSyncState()
        for id in ["current", "old", "other"] {
            let device = DeviceSyncPayload(
                deviceID: id,
                hostName: id == "other" ? "Example Desktop" : "Example MacBook",
                model: "Fixture",
                appVersion: "0.65.0",
                lastSeen: Date(timeIntervalSince1970: 100))
            state.fleetDevices[device.recordName] = device
        }
        for (name, id, provider) in [
            ("snapshot-old-claude", "old", ProviderInstanceID.claude),
            ("snapshot-old-codex", "old", .codex),
            ("snapshot-current", "current", .claude),
            ("snapshot-other", "other", .claude),
        ] {
            state.fleetSnapshots[name] = AccountSnapshotSyncPayload(
                provider: provider,
                deviceID: id,
                accountIdentity: nil,
                displayLabel: "Synthetic account",
                usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date(timeIntervalSince1970: 100)))
        }
        return state
    }
}
