import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct CodexBarTests {
    @Test
    func iconRendererProducesTemplateImage() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 75,
            creditsRemaining: 500,
            stale: false,
            style: .codex)
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
    }

    @Test
    func iconRendererRendersAtPixelAlignedSize() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 75,
            creditsRemaining: 500,
            stale: false,
            style: .claude)
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(bitmapReps.contains { rep in
            rep.pixelsWide == 36 && rep.pixelsHigh == 36
        })
    }

    @Test
    func iconRendererCachesStaticIcons() {
        let first = IconRenderer.makeIcon(
            primaryRemaining: 42,
            weeklyRemaining: 17,
            creditsRemaining: 250,
            stale: false,
            style: .codex)
        let second = IconRenderer.makeIcon(
            primaryRemaining: 42,
            weeklyRemaining: 17,
            creditsRemaining: 250,
            stale: false,
            style: .codex)
        #expect(first === second)
    }

    @Test
    func iconRendererCodexEyesPunchThroughWhenUnknown() {
        // Regression: when remaining is nil, CoreGraphics inherits the previous fill alpha which caused
        // destinationOut “eyes” to become semi-transparent instead of fully punched through.
        let image = IconRenderer.makeIcon(
            primaryRemaining: nil,
            weeklyRemaining: 1,
            creditsRemaining: nil,
            stale: false,
            style: .codex)

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = bitmapReps.first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        #expect(rep != nil)
        guard let rep else { return }

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let isTransparent: (Int, Int) -> Bool = { x, y in
            alphaAt(px: x, y) < 0.05
        }

        // Flood-fill from the border through transparent pixels to label the "outside".
        var visited = Array(repeating: Array(repeating: false, count: w), count: h)
        var queue: [(Int, Int)] = []
        queue.reserveCapacity(w * 2 + h * 2)

        func enqueueIfOutside(_ x: Int, _ y: Int) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            guard !visited[y][x], isTransparent(x, y) else { return }
            visited[y][x] = true
            queue.append((x, y))
        }

        for x in 0..<w {
            enqueueIfOutside(x, 0)
            enqueueIfOutside(x, h - 1)
        }
        for y in 0..<h {
            enqueueIfOutside(0, y)
            enqueueIfOutside(w - 1, y)
        }

        while let (x, y) = queue.first {
            queue.removeFirst()
            enqueueIfOutside(x + 1, y)
            enqueueIfOutside(x - 1, y)
            enqueueIfOutside(x, y + 1)
            enqueueIfOutside(x, y - 1)
        }

        // Any remaining transparent pixels not reachable from the border are internal holes (i.e. the eyes).
        var internalHoles = 0
        for y in 0..<h {
            for x in 0..<w where isTransparent(x, y) && !visited[y][x] {
                internalHoles += 1
            }
        }

        #expect(internalHoles >= 16) // at least one 4×4 eye block, but typically two eyes => 32
    }

    @Test
    func iconRendererWarpEyesCutOutAtExpectedCenters() {
        // Regression: Warp eyes should be tilted in-place and remain centered on the face.
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 50,
            creditsRemaining: nil,
            stale: false,
            style: .warp)

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = bitmapReps.first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        #expect(rep != nil)
        guard let rep else { return }

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        func minAlphaNear(px cx: Int, _ cy: Int, radius: Int) -> CGFloat {
            var minAlpha: CGFloat = 1.0
            let x0 = max(0, cx - radius)
            let x1 = min(rep.pixelsWide - 1, cx + radius)
            let y0 = max(0, cy - radius)
            let y1 = min(rep.pixelsHigh - 1, cy + radius)
            for y in y0...y1 {
                for x in x0...x1 {
                    minAlpha = min(minAlpha, alphaAt(px: x, y))
                }
            }
            return minAlpha
        }

        func minAlphaNearEitherOrigin(px cx: Int, _ cy: Int, radius: Int) -> CGFloat {
            let flippedY = (rep.pixelsHigh - 1) - cy
            return min(minAlphaNear(px: cx, cy, radius: radius), minAlphaNear(px: cx, flippedY, radius: radius))
        }

        // These are the center pixels for the two Warp eye cutouts in the top bar (36×36 canvas).
        // If the eyes are rotated around the wrong origin, these points will not be fully punched out.
        let leftEyeCenter = (x: 11, y: 25)
        let rightEyeCenter = (x: 25, y: 25)

        // The eye ellipse height is even (8 px), so the exact center can land between pixel rows.
        // Assert via a small neighborhood search rather than a single pixel.
        #expect(minAlphaNearEitherOrigin(px: leftEyeCenter.x, leftEyeCenter.y, radius: 2) < 0.05)
        #expect(minAlphaNearEitherOrigin(px: rightEyeCenter.x, rightEyeCenter.y, radius: 2) < 0.05)

        // Sanity: nearby top bar track area should remain visible (not everything is transparent).
        let midAlpha = max(alphaAt(px: 18, 25), alphaAt(px: 18, (rep.pixelsHigh - 1) - 25))
        #expect(midAlpha > 0.05)
    }

    @Test
    func accountInfoParsesAuthToken() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let token = Self.fakeJWT(email: "user@example.com", plan: "pro")
        let auth = ["tokens": ["idToken": token]]
        let data = try JSONSerialization.data(withJSONObject: auth)
        let authURL = tmp.appendingPathComponent("auth.json")
        try data.write(to: authURL)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        let account = fetcher.loadAccountInfo()
        #expect(account.email == "user@example.com")
        #expect(account.plan == "pro")
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64(header)).\(b64(payload))."
    }
}
