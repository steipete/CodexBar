import AppKit
import SwiftUI

@MainActor
enum ShareStatsRenderer {
    static func pngData(
        for payload: ShareStatsPayload,
        pixelSize: CGSize = ShareStatsCardView.size) -> Data?
    {
        let logicalSize = ShareStatsCardView.size
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let view = NSHostingView(rootView: ShareStatsCardView(payload: payload))
        view.frame = CGRect(origin: .zero, size: logicalSize)
        view.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width.rounded()),
            pixelsHigh: Int(pixelSize.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = logicalSize
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        view.displayIgnoringOpacity(view.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }

    static func image(for payload: ShareStatsPayload) -> NSImage? {
        guard let data = self.pngData(for: payload) else { return nil }
        return NSImage(data: data)
    }
}

@MainActor
enum ShareStatsExporter {
    static func copyImage(_ payload: ShareStatsPayload) -> Bool {
        guard let data = ShareStatsRenderer.pngData(for: payload),
              let image = NSImage(data: data) else { return false }
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func copyText(_ payload: ShareStatsPayload) {
        MenuPasteboardCopy.perform(ShareStatsFormatting.text(payload))
    }

    static func saveImage(_ payload: ShareStatsPayload) -> Bool {
        guard let data = ShareStatsRenderer.pngData(for: payload) else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = self.defaultFilename(payload)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    private static func defaultFilename(_ payload: ShareStatsPayload) -> String {
        "codexbar-usage-last-\(payload.days)-days.png"
    }
}
