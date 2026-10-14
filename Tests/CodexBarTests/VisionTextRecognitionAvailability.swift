import CoreGraphics
import Vision

/// GitHub's hosted macOS 27 (Xcode 27) image throws from `VNRecognizeTextRequest`, while real hardware recognizes
/// text normally. OCR-based assertions run only where Vision text recognition works.
enum VisionTextRecognition {
    static let isAvailable: Bool = {
        let side = 32
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return false }
        do {
            try VNImageRequestHandler(cgImage: image).perform([VNRecognizeTextRequest()])
            return true
        } catch {
            return false
        }
    }()
}
