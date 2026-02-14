import AppKit
import CodexBarCore

// swiftlint:disable:next type_body_length
enum IconRenderer {
    private static let creditsCap: Double = 1000
    private static let baseSize = NSSize(width: 18, height: 18)
    // Render to an 18×18 pt template (36×36 px at 2×) to match the system menu bar size.
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2
    private static let canvasPx = Int(outputSize.width * outputScale)

    private struct PixelGrid: Sendable {
        let scale: CGFloat

        func pt(_ px: Int) -> CGFloat {
            CGFloat(px) / self.scale
        }

        func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
        }

        func snapDelta(_ value: CGFloat) -> CGFloat {
            (value * self.scale).rounded() / self.scale
        }
    }

    private static let grid = PixelGrid(scale: outputScale)

    private struct IconCacheKey: Hashable {
        let primary: Int
        let weekly: Int
        let credits: Int
        let stale: Bool
        let style: Int
        let indicator: Int
    }

    private final class IconCacheStore: @unchecked Sendable {
        private var cache: [IconCacheKey: NSImage] = [:]
        private var order: [IconCacheKey] = []
        private let lock = NSLock()

        func cachedIcon(for key: IconCacheKey) -> NSImage? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let image = self.cache[key] else { return nil }
            if let idx = self.order.firstIndex(of: key) {
                self.order.remove(at: idx)
                self.order.append(key)
            }
            return image
        }

        func storeIcon(_ image: NSImage, for key: IconCacheKey, limit: Int) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.cache[key] = image
            self.order.removeAll { $0 == key }
            self.order.append(key)
            while self.order.count > limit {
                let oldest = self.order.removeFirst()
                self.cache.removeValue(forKey: oldest)
            }
        }
    }

    private static let iconCacheStore = IconCacheStore()
    private static let iconCacheLimit = 64
    private static let morphBucketCount = 200
    private static let morphCache = MorphCache(limit: 512)

    private final class MorphCache: @unchecked Sendable {
        private let cache = NSCache<NSNumber, NSImage>()

        init(limit: Int) {
            self.cache.countLimit = limit
        }

        func image(for key: NSNumber) -> NSImage? {
            self.cache.object(forKey: key)
        }

        func set(_ image: NSImage, for key: NSNumber) {
            self.cache.setObject(image, forKey: key)
        }
    }

    private struct RectPx: Hashable, Sendable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        var midXPx: Int {
            self.x + self.w / 2
        }

        var midYPx: Int {
            self.y + self.h / 2
        }

        func rect() -> CGRect {
            Self.grid.rect(x: self.x, y: self.y, w: self.w, h: self.h)
        }

        private static let grid = IconRenderer.grid
    }

    // swiftlint:disable function_body_length
    static func makeIcon(
        primaryRemaining: Double?,
        weeklyRemaining: Double?,
        creditsRemaining: Double?,
        stale: Bool,
        style: IconStyle,
        blink: CGFloat = 0,
        wiggle: CGFloat = 0,
        tilt: CGFloat = 0,
        statusIndicator: ProviderStatusIndicator = .none) -> NSImage
    {
        let shouldCache = blink <= 0.0001 && wiggle <= 0.0001 && tilt <= 0.0001
        let render = {
            self.renderImage {
                // Keep monochrome template icons; Claude uses subtle shape cues only.
                let baseFill = NSColor.labelColor
                let trackFillAlpha: CGFloat = stale ? 0.18 : 0.28
                let trackStrokeAlpha: CGFloat = stale ? 0.28 : 0.44
                let fillColor = baseFill.withAlphaComponent(stale ? 0.55 : 1.0)

                let barWidthPx = 30 // 15 pt at 2×, uses the slot better without touching edges.
                let barXPx = (Self.canvasPx - barWidthPx) / 2

                func drawBar(
                    rectPx: RectPx,
                    remaining: Double?,
                    alpha: CGFloat = 1.0,
                    addNotches: Bool = false,
                    addFace: Bool = false,
                    addGeminiTwist: Bool = false,
                    addAntigravityTwist: Bool = false,
                    addFactoryTwist: Bool = false,
                    addWarpTwist: Bool = false,
                    blink: CGFloat = 0,
                    drawTrackFill: Bool = true,
                    warpEyesFilled: Bool = false)
                {
                    let rect = rectPx.rect()
                    // Claude reads better as a blockier critter; Codex stays as a capsule.
                    // Warp uses small corner radius for rounded rectangle (matching logo style)
                    let cornerRadiusPx = addNotches ? 0 : (addWarpTwist ? 3 : rectPx.h / 2)
                    let radius = Self.grid.pt(cornerRadiusPx)

                    let trackPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                    if drawTrackFill {
                        baseFill.withAlphaComponent(trackFillAlpha * alpha).setFill()
                        trackPath.fill()
                    }

                    // Crisp outline: stroke an inset path so the stroke stays within pixel bounds.
                    let strokeWidthPx = 2 // 1 pt == 2 px at 2×
                    let insetPx = strokeWidthPx / 2
                    let strokeRect = Self.grid.rect(
                        x: rectPx.x + insetPx,
                        y: rectPx.y + insetPx,
                        w: max(0, rectPx.w - insetPx * 2),
                        h: max(0, rectPx.h - insetPx * 2))
                    let strokePath = NSBezierPath(
                        roundedRect: strokeRect,
                        xRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)),
                        yRadius: Self.grid.pt(max(0, cornerRadiusPx - insetPx)))
                    strokePath.lineWidth = CGFloat(strokeWidthPx) / Self.outputScale
                    baseFill.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
                    strokePath.stroke()

                    // Fill: clip to the capsule and paint a left-to-right rect so the progress edge is straight.
                    if let remaining {
                        let clamped = max(0, min(remaining / 100, 1))
                        let fillWidthPx = max(0, min(rectPx.w, Int((CGFloat(rectPx.w) * CGFloat(clamped)).rounded())))
                        if fillWidthPx > 0 {
                            NSGraphicsContext.current?.cgContext.saveGState()
                            trackPath.addClip()
                            fillColor.withAlphaComponent(alpha).setFill()
                            NSBezierPath(
                                rect: Self.grid.rect(
                                    x: rectPx.x,
                                    y: rectPx.y,
                                    w: fillWidthPx,
                                    h: rectPx.h)).fill()
                            NSGraphicsContext.current?.cgContext.restoreGState()
                        }
                    }

                    // Codex face: eye cutouts plus faint eyelids to give the prompt some personality.
                    if addFace {
                        let ctx = NSGraphicsContext.current?.cgContext
                        let eyeSizePx = 4
                        let eyeOffsetPx = 7
                        let eyeCenterYPx = rectPx.y + rectPx.h / 2
                        let centerXPx = rectPx.midXPx

                        ctx?.saveGState()
                        ctx?.setShouldAntialias(false)
                        ctx?.clear(Self.grid.rect(
                            x: centerXPx - eyeOffsetPx - eyeSizePx / 2,
                            y: eyeCenterYPx - eyeSizePx / 2,
                            w: eyeSizePx,
                            h: eyeSizePx))
                        ctx?.clear(Self.grid.rect(
                            x: centerXPx + eyeOffsetPx - eyeSizePx / 2,
                            y: eyeCenterYPx - eyeSizePx / 2,
                            w: eyeSizePx,
                            h: eyeSizePx))
                        ctx?.restoreGState()

                        // Blink: refill eyes from the top down using the bar fill color.
                        if blink > 0.001 {
                            let clamped = max(0, min(blink, 1))
                            let blinkHeightPx = Int((CGFloat(eyeSizePx) * clamped).rounded())
                            fillColor.withAlphaComponent(alpha).setFill()
                            let blinkRectLeft = Self.grid.rect(
                                x: centerXPx - eyeOffsetPx - eyeSizePx / 2,
                                y: eyeCenterYPx + eyeSizePx / 2 - blinkHeightPx,
                                w: eyeSizePx,
                                h: blinkHeightPx)
                            let blinkRectRight = Self.grid.rect(
                                x: centerXPx + eyeOffsetPx - eyeSizePx / 2,
                                y: eyeCenterYPx + eyeSizePx / 2 - blinkHeightPx,
                                w: eyeSizePx,
                                h: blinkHeightPx)
                            NSBezierPath(rect: blinkRectLeft).fill()
                            NSBezierPath(rect: blinkRectRight).fill()
                        }

                        // Hat: a tiny cap hovering above the eyes to give the face more character.
                        let hatWidthPx = 18
                        let hatHeightPx = 4
                        let hatRect = Self.grid.rect(
                            x: centerXPx - hatWidthPx / 2,
                            y: rectPx.y + rectPx.h - hatHeightPx,
                            w: hatWidthPx,
                            h: hatHeightPx)
                        ctx?.saveGState()
                        if abs(tilt) > 0.0001 {
                            // Tilt only the hat; keep eyes pixel-crisp and axis-aligned.
                            let faceCenter = CGPoint(x: Self.grid.pt(centerXPx), y: Self.grid.pt(eyeCenterYPx))
                            ctx?.translateBy(x: faceCenter.x, y: faceCenter.y)
                            ctx?.rotate(by: tilt)
                            ctx?.translateBy(x: -faceCenter.x, y: -faceCenter.y - abs(tilt) * 1.2)
                        }
                        fillColor.withAlphaComponent(alpha).setFill()
                        NSBezierPath(rect: hatRect).fill()
                        ctx?.restoreGState()
                    }

                    // Claude twist: blocky crab-style critter (arms + legs + vertical eyes).
                    if addNotches {
                        let ctx = NSGraphicsContext.current?.cgContext
                        let wiggleOffset = Self.grid.snapDelta(wiggle * 0.6)
                        let wigglePx = Int((wiggleOffset * Self.outputScale).rounded())

                        fillColor.withAlphaComponent(alpha).setFill()

                        // Arms/claws: mid-height side protrusions.
                        // Keep within the 18×18pt canvas: barX is 3px, so 3px arms reach the edge without clipping.
                        let armWidthPx = 3
                        let armHeightPx = max(0, rectPx.h - 6)
                        let armYPx = rectPx.y + 3 + wigglePx / 6
                        let leftArm = Self.grid.rect(
                            x: rectPx.x - armWidthPx,
                            y: armYPx,
                            w: armWidthPx,
                            h: armHeightPx)
                        let rightArm = Self.grid.rect(
                            x: rectPx.x + rectPx.w,
                            y: armYPx,
                            w: armWidthPx,
                            h: armHeightPx)
                        NSBezierPath(rect: leftArm).fill()
                        NSBezierPath(rect: rightArm).fill()

                        // Legs: 4 little pixels underneath, like a tiny crab.
                        let legCount = 4
                        let legWidthPx = 2
                        let legHeightPx = 3
                        let legYPx = rectPx.y - legHeightPx + wigglePx / 6
                        let stepPx = max(1, rectPx.w / (legCount + 1))
                        for idx in 0..<legCount {
                            let cx = rectPx.x + stepPx * (idx + 1)
                            let leg = Self.grid.rect(
                                x: cx - legWidthPx / 2,
                                y: legYPx,
                                w: legWidthPx,
                                h: legHeightPx)
                            NSBezierPath(rect: leg).fill()
                        }

                        // Eyes: tall vertical cutouts near the top.
                        let eyeWidthPx = 2
                        let eyeHeightPx = 5
                        let eyeOffsetPx = 6
                        let eyeYPx = rectPx.y + rectPx.h - eyeHeightPx - 2 + wigglePx / 8
                        ctx?.saveGState()
                        ctx?.setShouldAntialias(false)
                        ctx?.clear(Self.grid.rect(
                            x: rectPx.midXPx - eyeOffsetPx - eyeWidthPx / 2,
                            y: eyeYPx,
                            w: eyeWidthPx,
                            h: eyeHeightPx))
                        ctx?.clear(Self.grid.rect(
                            x: rectPx.midXPx + eyeOffsetPx - eyeWidthPx / 2,
                            y: eyeYPx,
                            w: eyeWidthPx,
                            h: eyeHeightPx))
                        ctx?.restoreGState()

                        // Blink: fill the eyes from the top down (blocky).
                        if blink > 0.001 {
                            let clamped = max(0, min(blink, 1))
                            let blinkHeightPx = Int((CGFloat(eyeHeightPx) * clamped).rounded())
                            fillColor.withAlphaComponent(alpha).setFill()
                            let leftBlink = Self.grid.rect(
                                x: rectPx.midXPx - eyeOffsetPx - eyeWidthPx / 2,
                                y: eyeYPx + eyeHeightPx - blinkHeightPx,
                                w: eyeWidthPx,
                                h: blinkHeightPx)
                            let rightBlink = Self.grid.rect(
                                x: rectPx.midXPx + eyeOffsetPx - eyeWidthPx / 2,
                                y: eyeYPx + eyeHeightPx - blinkHeightPx,
                                w: eyeWidthPx,
                                h: blinkHeightPx)
                            NSBezierPath(rect: leftBlink).fill()
                            NSBezierPath(rect: rightBlink).fill()
                        }
                    }

                    // Gemini twist: sparkle-inspired design with prominent 4-pointed stars as eyes
                    // and decorative points extending from the bar.
                    if addGeminiTwist {
                        let ctx = NSGraphicsContext.current?.cgContext
                        let centerXPx = rectPx.midXPx
                        let eyeCenterYPx = rectPx.y + rectPx.h / 2

                        ctx?.saveGState()
                        ctx?.setShouldAntialias(true)

                        // 4-pointed star cutouts (Gemini sparkle eyes) - BIGGER
                        let starSizePx = 8
                        let eyeOffsetPx = 8
                        let sr = Self.grid.pt(starSizePx / 2)
                        let innerR = sr * 0.25

                        func drawStarCutout(cx: CGFloat, cy: CGFloat) {
                            let path = NSBezierPath()
                            for i in 0..<8 {
                                let angle = CGFloat(i) * .pi / 4 - .pi / 2
                                let radius = (i % 2 == 0) ? sr : innerR
                                let px = cx + cos(angle) * radius
                                let py = cy + sin(angle) * radius
                                if i == 0 {
                                    path.move(to: NSPoint(x: px, y: py))
                                } else {
                                    path.line(to: NSPoint(x: px, y: py))
                                }
                            }
                            path.close()
                            path.fill()
                        }

                        let ldCx = Self.grid.pt(centerXPx - eyeOffsetPx)
                        let rdCx = Self.grid.pt(centerXPx + eyeOffsetPx)
                        let yCy = Self.grid.pt(eyeCenterYPx)

                        // Clear star shapes for eyes
                        ctx?.setBlendMode(.clear)
                        drawStarCutout(cx: ldCx, cy: yCy)
                        drawStarCutout(cx: rdCx, cy: yCy)
                        ctx?.setBlendMode(.normal)

                        // Decorative sparkle points extending from bar (sized to stay within 36px canvas)
                        fillColor.withAlphaComponent(alpha).setFill()
                        let pointHeightPx = 4
                        let pointWidthPx = 4

                        // Top center point (like a crown/sparkle)
                        let topPointPath = NSBezierPath()
                        let topCx = Self.grid.pt(centerXPx)
                        let topBaseY = Self.grid.pt(rectPx.y + rectPx.h)
                        let topPeakY = Self.grid.pt(rectPx.y + rectPx.h + pointHeightPx)
                        let halfW = Self.grid.pt(pointWidthPx / 2)
                        topPointPath.move(to: NSPoint(x: topCx - halfW, y: topBaseY))
                        topPointPath.line(to: NSPoint(x: topCx, y: topPeakY))
                        topPointPath.line(to: NSPoint(x: topCx + halfW, y: topBaseY))
                        topPointPath.close()
                        topPointPath.fill()

                        // Bottom center point
                        let bottomPointPath = NSBezierPath()
                        let bottomBaseY = Self.grid.pt(rectPx.y)
                        let bottomPeakY = Self.grid.pt(rectPx.y - pointHeightPx)
                        bottomPointPath.move(to: NSPoint(x: topCx - halfW, y: bottomBaseY))
                        bottomPointPath.line(to: NSPoint(x: topCx, y: bottomPeakY))
                        bottomPointPath.line(to: NSPoint(x: topCx + halfW, y: bottomBaseY))
                        bottomPointPath.close()
                        bottomPointPath.fill()

                        // Side points (max 3px to stay within canvas edge)
                        let sidePointH = 3
                        let sidePointW = 3
                        let sideHalfW = Self.grid.pt(sidePointW / 2)
                        let barMidY = Self.grid.pt(eyeCenterYPx)

                        // Left side point
                        let leftSidePath = NSBezierPath()
                        let leftBaseX = Self.grid.pt(rectPx.x)
                        let leftPeakX = Self.grid.pt(rectPx.x - sidePointH)
                        leftSidePath.move(to: NSPoint(x: leftBaseX, y: barMidY - sideHalfW))
                        leftSidePath.line(to: NSPoint(x: leftPeakX, y: barMidY))
                        leftSidePath.line(to: NSPoint(x: leftBaseX, y: barMidY + sideHalfW))
                        leftSidePath.close()
                        leftSidePath.fill()

                        // Right side point
                        let rightSidePath = NSBezierPath()
                        let rightBaseX = Self.grid.pt(rectPx.x + rectPx.w)
                        let rightPeakX = Self.grid.pt(rectPx.x + rectPx.w + sidePointH)
                        rightSidePath.move(to: NSPoint(x: rightBaseX, y: barMidY - sideHalfW))
                        rightSidePath.line(to: NSPoint(x: rightPeakX, y: barMidY))
                        rightSidePath.line(to: NSPoint(x: rightBaseX, y: barMidY + sideHalfW))
                        rightSidePath.close()
                        rightSidePath.fill()

                        ctx?.restoreGState()

                        // Blink: fill star eyes
                        if blink > 0.001 {
                            let clamped = max(0, min(blink, 1))
                            fillColor.withAlphaComponent(alpha).setFill()
                            let blinkR = sr * clamped
                            let blinkInnerR = blinkR * 0.25

                            func drawBlinkStar(cx: CGFloat, cy: CGFloat) {
                                let path = NSBezierPath()
                                for i in 0..<8 {
                                    let angle = CGFloat(i) * .pi / 4 - .pi / 2
                                    let radius = (i % 2 == 0) ? blinkR : blinkInnerR
                                    let px = cx + cos(angle) * radius
                                    let py = cy + sin(angle) * radius
                                    if i == 0 {
                                        path.move(to: NSPoint(x: px, y: py))
                                    } else {
                                        path.line(to: NSPoint(x: px, y: py))
                                    }
                                }
                                path.close()
                                path.fill()
                            }

                            drawBlinkStar(cx: ldCx, cy: yCy)
                            drawBlinkStar(cx: rdCx, cy: yCy)
                        }
                    }

                    if addAntigravityTwist {
                        let dotSizePx = 3
                        let dotOffsetXPx = rectPx.x + rectPx.w + 2
                        let dotOffsetYPx = rectPx.y + rectPx.h - 2
                        fillColor.withAlphaComponent(alpha).setFill()
                        let dotRect = Self.grid.rect(
                            x: dotOffsetXPx - dotSizePx / 2,
                            y: dotOffsetYPx - dotSizePx / 2,
                            w: dotSizePx,
                            h: dotSizePx)
                        NSBezierPath(ovalIn: dotRect).fill()
                    }

                    // Factory twist: 8-pointed asterisk/gear-like eyes with cog teeth accents
                    if addFactoryTwist {
                        let ctx = NSGraphicsContext.current?.cgContext
                        let centerXPx = rectPx.midXPx
                        let eyeCenterYPx = rectPx.y + rectPx.h / 2

                        ctx?.saveGState()
                        ctx?.setShouldAntialias(true)

                        // 8-pointed asterisk cutouts (Factory gear-like eyes)
                        let starSizePx = 7
                        let eyeOffsetPx = 8
                        let sr = Self.grid.pt(starSizePx / 2)
                        let innerR = sr * 0.3

                        func drawAsteriskCutout(cx: CGFloat, cy: CGFloat) {
                            let path = NSBezierPath()
                            // 8 points for the asterisk
                            for i in 0..<16 {
                                let angle = CGFloat(i) * .pi / 8 - .pi / 2
                                let radius = (i % 2 == 0) ? sr : innerR
                                let px = cx + cos(angle) * radius
                                let py = cy + sin(angle) * radius
                                if i == 0 {
                                    path.move(to: NSPoint(x: px, y: py))
                                } else {
                                    path.line(to: NSPoint(x: px, y: py))
                                }
                            }
                            path.close()
                            path.fill()
                        }

                        let ldCx = Self.grid.pt(centerXPx - eyeOffsetPx)
                        let rdCx = Self.grid.pt(centerXPx + eyeOffsetPx)
                        let yCy = Self.grid.pt(eyeCenterYPx)

                        // Clear asterisk shapes for eyes
                        ctx?.setBlendMode(.clear)
                        drawAsteriskCutout(cx: ldCx, cy: yCy)
                        drawAsteriskCutout(cx: rdCx, cy: yCy)
                        ctx?.setBlendMode(.normal)

                        // Small gear teeth on top and bottom edges
                        fillColor.withAlphaComponent(alpha).setFill()
                        let toothWidthPx = 3
                        let toothHeightPx = 2

                        // Top teeth (2 small rectangles)
                        let topY = Self.grid.pt(rectPx.y + rectPx.h)
                        let tooth1X = Self.grid.pt(centerXPx - 5 - toothWidthPx / 2)
                        let tooth2X = Self.grid.pt(centerXPx + 5 - toothWidthPx / 2)
                        NSBezierPath(rect: CGRect(
                            x: tooth1X,
                            y: topY,
                            width: Self.grid.pt(toothWidthPx),
                            height: Self.grid.pt(toothHeightPx))).fill()
                        NSBezierPath(rect: CGRect(
                            x: tooth2X,
                            y: topY,
                            width: Self.grid.pt(toothWidthPx),
                            height: Self.grid.pt(toothHeightPx))).fill()

                        // Bottom teeth
                        let bottomY = Self.grid.pt(rectPx.y - toothHeightPx)
                        NSBezierPath(rect: CGRect(
                            x: tooth1X,
                            y: bottomY,
                            width: Self.grid.pt(toothWidthPx),
                            height: Self.grid.pt(toothHeightPx))).fill()
                        NSBezierPath(rect: CGRect(
                            x: tooth2X,
                            y: bottomY,
                            width: Self.grid.pt(toothWidthPx),
                            height: Self.grid.pt(toothHeightPx))).fill()

                        ctx?.restoreGState()

                        // Blink: fill asterisk eyes
                        if blink > 0.001 {
                            let clamped = max(0, min(blink, 1))
                            fillColor.withAlphaComponent(alpha).setFill()
                            let blinkR = sr * clamped
                            let blinkInnerR = blinkR * 0.3

                            func drawBlinkAsterisk(cx: CGFloat, cy: CGFloat) {
                                let path = NSBezierPath()
                                for i in 0..<16 {
                                    let angle = CGFloat(i) * .pi / 8 - .pi / 2
                                    let radius = (i % 2 == 0) ? blinkR : blinkInnerR
                                    let px = cx + cos(angle) * radius
                                    let py = cy + sin(angle) * radius
                                    if i == 0 {
                                        path.move(to: NSPoint(x: px, y: py))
                                    } else {
                                        path.line(to: NSPoint(x: px, y: py))
                                    }
                                }
                                path.close()
                                path.fill()
                            }

                            drawBlinkAsterisk(cx: ldCx, cy: yCy)
                            drawBlinkAsterisk(cx: rdCx, cy: yCy)
                        }
                    }

                    // Warp twist: "Warp" style face with tilted-eye cutouts.
                    if addWarpTwist {
                        let ctx = NSGraphicsContext.current?.cgContext
                        let centerXPx = rectPx.midXPx
                        let eyeCenterYPx = rectPx.y + rectPx.h / 2

                        ctx?.saveGState()
                        ctx?.setShouldAntialias(true) // Smooth edges for tilted ellipse eyes

                        // 1. Draw Eyes (Tilted ellipse cutouts - "fox eye" / "cat eye" style)
                        // Keep sizes in integer pixels so grid conversion stays exact.
                        let eyeWidthPx = 5
                        let eyeHeightPx = 8
                        let eyeOffsetPx = 7
                        let eyeTiltAngle: CGFloat = .pi / 3 // 60 degrees tilt

                        let leftEyeCx = Self.grid.pt(centerXPx) - Self.grid.pt(eyeOffsetPx)
                        let rightEyeCx = Self.grid.pt(centerXPx) + Self.grid.pt(eyeOffsetPx)
                        let eyeCy = Self.grid.pt(eyeCenterYPx)
                        let eyeW = Self.grid.pt(eyeWidthPx)
                        let eyeH = Self.grid.pt(eyeHeightPx)

                        /// Draw a tilted ellipse eye at the given center.
                        func drawTiltedEyeCutout(cx: CGFloat, cy: CGFloat, tiltAngle: CGFloat) {
                            guard let ctx else { return }
                            let eyeRect = CGRect(x: -eyeW / 2, y: -eyeH / 2, width: eyeW, height: eyeH)

                            // Use CGContext transforms instead of AffineTransform-on-path so the rotation origin
                            // is unambiguous and the current blend mode is consistently respected.
                            ctx.saveGState()
                            ctx.translateBy(x: cx, y: cy)
                            ctx.rotate(by: tiltAngle)
                            ctx.addEllipse(in: eyeRect)
                            ctx.fillPath()
                            ctx.restoreGState()
                        }

                        if warpEyesFilled {
                            fillColor.withAlphaComponent(alpha).setFill()
                            drawTiltedEyeCutout(cx: leftEyeCx, cy: eyeCy, tiltAngle: eyeTiltAngle)
                            drawTiltedEyeCutout(cx: rightEyeCx, cy: eyeCy, tiltAngle: -eyeTiltAngle)
                        } else {
                            // Clear eyes using blend mode
                            ctx?.setBlendMode(.clear)
                            drawTiltedEyeCutout(cx: leftEyeCx, cy: eyeCy, tiltAngle: eyeTiltAngle)
                            drawTiltedEyeCutout(cx: rightEyeCx, cy: eyeCy, tiltAngle: -eyeTiltAngle)
                            ctx?.setBlendMode(.normal)
                        }
                        ctx?.restoreGState() // Restore graphics state
                    }
                }

                let effectiveWeeklyRemaining: Double? = {
                    if style == .warp, let weeklyRemaining, weeklyRemaining <= 0 {
                        return nil
                    }
                    return weeklyRemaining
                }()
                let topValue = primaryRemaining
                let bottomValue = effectiveWeeklyRemaining
                let creditsRatio = creditsRemaining.map { min($0 / Self.creditsCap * 100, 100) }

                let hasWeekly = (bottomValue != nil)
                let weeklyAvailable = hasWeekly && (bottomValue ?? 0) > 0
                let creditsAlpha: CGFloat = 1.0
                let topRectPx = RectPx(x: barXPx, y: 19, w: barWidthPx, h: 12)
                let bottomRectPx = RectPx(x: barXPx, y: 5, w: barWidthPx, h: 8)
                let creditsRectPx = RectPx(x: barXPx, y: 14, w: barWidthPx, h: 16)
                let creditsBottomRectPx = RectPx(x: barXPx, y: 4, w: barWidthPx, h: 6)

                // Warp special case: when no bonus or bonus exhausted, show "top monthly, bottom dimmed"
                let warpNoBonus = style == .warp && !weeklyAvailable

                if weeklyAvailable {
                    // Normal: top=primary, bottom=secondary (bonus/weekly).
                    drawBar(
                        rectPx: topRectPx,
                        remaining: topValue,
                        addNotches: style == .claude,
                        addFace: style == .codex,
                        addGeminiTwist: style == .gemini || style == .antigravity,
                        addAntigravityTwist: style == .antigravity,
                        addFactoryTwist: style == .factory,
                        addWarpTwist: style == .warp,
                        blink: blink)
                    drawBar(rectPx: bottomRectPx, remaining: bottomValue)
                } else if !hasWeekly || warpNoBonus {
                    if style == .warp {
                        // Warp: no bonus or bonus exhausted -> top=monthly credits, bottom=dimmed track
                        drawBar(
                            rectPx: topRectPx,
                            remaining: topValue,
                            addWarpTwist: true,
                            blink: blink)
                        drawBar(rectPx: bottomRectPx, remaining: nil, alpha: 0.45)
                    } else {
                        // Weekly missing (e.g. Claude enterprise): keep normal layout but
                        // dim the bottom track to indicate N/A.
                        if topValue == nil, let ratio = creditsRatio {
                            // Credits-only: show credits prominently (e.g. credits loaded before usage).
                            drawBar(
                                rectPx: creditsRectPx,
                                remaining: ratio,
                                alpha: creditsAlpha,
                                addNotches: style == .claude,
                                addFace: style == .codex,
                                addGeminiTwist: style == .gemini || style == .antigravity,
                                addAntigravityTwist: style == .antigravity,
                                addFactoryTwist: style == .factory,
                                addWarpTwist: style == .warp,
                                blink: blink)
                            drawBar(rectPx: creditsBottomRectPx, remaining: nil, alpha: 0.45)
                        } else {
                            drawBar(
                                rectPx: topRectPx,
                                remaining: topValue,
                                addNotches: style == .claude,
                                addFace: style == .codex,
                                addGeminiTwist: style == .gemini || style == .antigravity,
                                addAntigravityTwist: style == .antigravity,
                                addFactoryTwist: style == .factory,
                                addWarpTwist: style == .warp,
                                blink: blink)
                            drawBar(rectPx: bottomRectPx, remaining: nil, alpha: 0.45)
                        }
                    }
                } else {
                    // Weekly exhausted/missing: show credits on top (thicker), weekly (likely 0) on bottom.
                    if let ratio = creditsRatio {
                        drawBar(
                            rectPx: creditsRectPx,
                            remaining: ratio,
                            alpha: creditsAlpha,
                            addNotches: style == .claude,
                            addFace: style == .codex,
                            addGeminiTwist: style == .gemini || style == .antigravity,
                            addAntigravityTwist: style == .antigravity,
                            addFactoryTwist: style == .factory,
                            addWarpTwist: style == .warp,
                            blink: blink)
                    } else {
                        // No credits available; fall back to 5h if present.
                        drawBar(
                            rectPx: topRectPx,
                            remaining: topValue,
                            addNotches: style == .claude,
                            addFace: style == .codex,
                            addGeminiTwist: style == .gemini || style == .antigravity,
                            addAntigravityTwist: style == .antigravity,
                            addFactoryTwist: style == .factory,
                            addWarpTwist: style == .warp,
                            blink: blink)
                    }
                    drawBar(rectPx: creditsBottomRectPx, remaining: bottomValue)
                }

                Self.drawStatusOverlay(indicator: statusIndicator)
            }
        }

        if shouldCache {
            let key = IconCacheKey(
                primary: self.quantizedPercent(primaryRemaining),
                weekly: self.quantizedPercent(weeklyRemaining),
                credits: self.quantizedCredits(creditsRemaining),
                stale: stale,
                style: self.styleKey(style),
                indicator: self.indicatorKey(statusIndicator))
            if let cached = self.cachedIcon(for: key) {
                return cached
            }
            let image = render()
            self.storeIcon(image, for: key)
            return image
        }

        return render()
    }

    // swiftlint:enable function_body_length

    /// Morph helper: unbraids a simplified knot into our bar icon.
    static func makeMorphIcon(progress: Double, style: IconStyle) -> NSImage {
        let clamped = max(0, min(progress, 1))
        let key = self.morphCacheKey(progress: clamped, style: style)
        if let cached = self.morphCache.image(for: key) {
            return cached
        }
        let image = self.renderImage {
            self.drawUnbraidMorph(t: clamped, style: style)
        }
        self.morphCache.set(image, for: key)
        return image
    }

    private static func quantizedPercent(_ value: Double?) -> Int {
        guard let value else { return -1 }
        return Int((value * 10).rounded())
    }

    private static func quantizedCredits(_ value: Double?) -> Int {
        guard let value else { return -1 }
        let clamped = max(0, min(value, self.creditsCap))
        return Int((clamped * 10).rounded())
    }

    private static let styleKeyLookup: [IconStyle: Int] = {
        var lookup: [IconStyle: Int] = [:]
        for (index, style) in IconStyle.allCases.enumerated() {
            lookup[style] = index
        }
        return lookup
    }()

    private static func styleKey(_ style: IconStyle) -> Int {
        self.styleKeyLookup[style] ?? 0
    }

    private static func indicatorKey(_ indicator: ProviderStatusIndicator) -> Int {
        switch indicator {
        case .none: 0
        case .minor: 1
        case .major: 2
        case .critical: 3
        case .maintenance: 4
        case .unknown: 5
        }
    }

    private static func morphCacheKey(progress: Double, style: IconStyle) -> NSNumber {
        let bucket = Int((progress * Double(self.morphBucketCount)).rounded())
        let key = self.styleKey(style) * 1000 + bucket
        return NSNumber(value: key)
    }

    private static func cachedIcon(for key: IconCacheKey) -> NSImage? {
        self.iconCacheStore.cachedIcon(for: key)
    }

    private static func storeIcon(_ image: NSImage, for key: IconCacheKey) {
        self.iconCacheStore.storeIcon(image, for: key, limit: self.iconCacheLimit)
    }

    private static func drawUnbraidMorph(t: Double, style: IconStyle) {
        let t = CGFloat(max(0, min(t, 1)))
        let size = Self.baseSize
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseColor = NSColor.labelColor

        struct Segment {
            let startCenter: CGPoint
            let endCenter: CGPoint
            let startAngle: CGFloat
            let endAngle: CGFloat
            let startLength: CGFloat
            let endLength: CGFloat
            let startThickness: CGFloat
            let endThickness: CGFloat
            let fadeOut: Bool
        }

        let segments: [Segment] = [
            // Upper ribbon -> top bar
            .init(
                startCenter: center.offset(dx: 0, dy: 2),
                endCenter: CGPoint(x: center.x, y: 9.0),
                startAngle: -30,
                endAngle: 0,
                startLength: 16,
                endLength: 14,
                startThickness: 3.4,
                endThickness: 3.0,
                fadeOut: false),
            // Lower ribbon -> bottom bar
            .init(
                startCenter: center.offset(dx: 0, dy: -2),
                endCenter: CGPoint(x: center.x, y: 4.0),
                startAngle: 210,
                endAngle: 0,
                startLength: 16,
                endLength: 12,
                startThickness: 3.4,
                endThickness: 2.4,
                fadeOut: false),
            // Side ribbon fades away
            .init(
                startCenter: center,
                endCenter: center.offset(dx: 0, dy: 6),
                startAngle: 90,
                endAngle: 0,
                startLength: 16,
                endLength: 8,
                startThickness: 3.4,
                endThickness: 1.8,
                fadeOut: true),
        ]

        for seg in segments {
            let p = seg.fadeOut ? t * 1.1 : t
            let c = seg.startCenter.lerp(to: seg.endCenter, p: p)
            let angle = seg.startAngle.lerp(to: seg.endAngle, p: p)
            let length = seg.startLength.lerp(to: seg.endLength, p: p)
            let thickness = seg.startThickness.lerp(to: seg.endThickness, p: p)
            let alpha = seg.fadeOut ? (1 - p) : 1

            self.drawRoundedRibbon(
                center: c,
                length: length,
                thickness: thickness,
                angle: angle,
                color: baseColor.withAlphaComponent(alpha))
        }

        // Cross-fade in bar fill emphasis near the end of the morph.
        if t > 0.55 {
            let barT = (t - 0.55) / 0.45
            let bars = self.makeIcon(
                primaryRemaining: 100,
                weeklyRemaining: 100,
                creditsRemaining: nil,
                stale: false,
                style: style)
            bars.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: barT)
        }
    }

    private static func drawRoundedRibbon(
        center: CGPoint,
        length: CGFloat,
        thickness: CGFloat,
        angle: CGFloat,
        color: NSColor)
    {
        var transform = AffineTransform.identity
        transform.translate(x: center.x, y: center.y)
        transform.rotate(byDegrees: angle)
        transform.translate(x: -center.x, y: -center.y)

        let rect = CGRect(
            x: center.x - length / 2,
            y: center.y - thickness / 2,
            width: length,
            height: thickness)

        let path = NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2)
        path.transform(using: transform)
        color.setFill()
        path.fill()
    }

    private static func drawStatusOverlay(indicator: ProviderStatusIndicator) {
        guard indicator.hasIssue else { return }
        let color = NSColor.labelColor

        switch indicator {
        case .minor, .maintenance:
            let size: CGFloat = 4
            let rect = Self.snapRect(
                x: Self.baseSize.width - size - 2,
                y: 2,
                width: size,
                height: size)
            let path = NSBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
        case .major, .critical, .unknown:
            let lineRect = Self.snapRect(
                x: Self.baseSize.width - 6,
                y: 4,
                width: 2.0,
                height: 6)
            let linePath = NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1)
            color.setFill()
            linePath.fill()

            let dotRect = Self.snapRect(
                x: Self.baseSize.width - 6,
                y: 2,
                width: 2.0,
                height: 2.0)
            NSBezierPath(ovalIn: dotRect).fill()
        case .none:
            break
        }
    }

    private static func withScaledContext(_ draw: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            draw()
            return
        }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .none
        draw()
        ctx.restoreGState()
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * self.outputScale).rounded() / self.outputScale
    }

    private static func snapRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: self.snap(x), y: self.snap(y), width: self.snap(width), height: self.snap(height))
    }

    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: Self.outputSize)

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.outputSize.width * Self.outputScale),
            pixelsHigh: Int(Self.outputSize.height * Self.outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = Self.outputSize // points
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                Self.withScaledContext(draw)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Fallback to legacy focus if the bitmap rep fails for any reason.
            image.lockFocus()
            Self.withScaledContext(draw)
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }
}

extension CGPoint {
    fileprivate func lerp(to other: CGPoint, p: CGFloat) -> CGPoint {
        CGPoint(x: self.x + (other.x - self.x) * p, y: self.y + (other.y - self.y) * p)
    }

    fileprivate func offset(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: self.x + dx, y: self.y + dy)
    }
}

extension CGFloat {
    fileprivate func lerp(to other: CGFloat, p: CGFloat) -> CGFloat {
        self + (other - self) * p
    }
}
