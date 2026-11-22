import AppKit
import CoreText
import Foundation

extension MenuBarLayoutRenderer {
    static func statusImage(
        title: NSAttributedString,
        foregroundColor: NSColor,
        verticalAdjustment: Int = 0) -> NSImage?
    {
        guard title.length > 0 else { return nil }
        // Preserve colored glyphs and attachments; monochrome attachment masks may join the template.
        let line = CTLineCreateWithAttributedString(title)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let attributes = title.attributes(at: CTRunGetStringRange(run).location, effectiveRange: nil)
            guard attributes[.foregroundColor] as? NSColor == foregroundColor,
                  (attributes[.attachment] as? NSTextAttachment)?.image?.isTemplate != false,
                  let font = runAttributes[kCTFontAttributeName] as? NSFont,
                  !CTFontGetSymbolicTraits(font as CTFont).contains(.traitColorGlyphs)
            else { return nil }
        }
        let prepared = Self.prepareImageTitle(title, verticalAdjustment: verticalAdjustment)
        let size = NSSize(width: max(1, ceil(prepared.bounds.width)), height: 22)
        // Drawing handlers preserve the destination scale; the template lets AppKit own highlight and inactive tinting.
        // Capture immutable content only: AppKit can call the handler away from the main thread.
        let image = NSImage(size: size, flipped: false) { _ in
            prepared.title.draw(with: prepared.rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// High contrast keeps the full mark and both rows in the attributed-title path, so AppKit
    /// cannot dim just the mark on an inactive display. The handler preserves the destination scale.
    static func spanningIconTitle(
        _ icon: NSImage,
        title: NSAttributedString,
        font: NSFont,
        options: MenuBarLayoutRenderOptions) -> NSAttributedString
    {
        let prepared = Self.prepareImageTitle(
            title,
            x: icon.size.width,
            verticalAdjustment: options.verticalAdjustment)
        let size = NSSize(width: max(1, ceil(icon.size.width + prepared.bounds.width)), height: 22)
        let mark = Self.offsetLeadingIcon(
            Self.attachmentImage(icon, tint: .labelColor), adjustment: options.verticalAdjustment)
        let iconRect = NSRect(
            x: 0,
            y: (size.height - mark.size.height) / 2,
            width: mark.size.width,
            height: mark.size.height)
        let appearance = NSAppearance(named: NSAppearance.Name(rawValue: options.appearanceName))
        // No renderer, options, mutable attributed strings, or actor-isolated state escapes here.
        let image = NSImage(size: size, flipped: false) { _ in
            let draw = {
                mark.draw(in: iconRect)
                prepared.title.draw(with: prepared.rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        image.isTemplate = false
        let attachment = NSTextAttachment()
        attachment.image = image
        // NSStatusBarButton centers titles against the standard menu-bar system font rather than
        // the smaller stacked font. Centering the 22 pt attachment on that cap band keeps
        // attributedTitle.size().height == 22 across sizes and matches native button.image alignment.
        let menuBarFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attachmentY = floor((menuBarFont.capHeight - size.height) / 2)
        attachment.bounds = NSRect(x: 0, y: attachmentY, width: size.width, height: size.height)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func offsetLeadingIcon(_ image: NSImage, adjustment: Int) -> NSImage {
        // Bake the offset into the surfaced image so the status button and preferences preview share it.
        // Cap the canvas at the 22 pt menu bar content height to avoid proportional downscaling.
        let maxShift = max(0, floor((22 - image.size.height) / 2))
        let shift = min(CGFloat(abs(adjustment)), maxShift)
        guard adjustment != 0, shift > 0 else { return image }

        let offsetImage = NSImage(
            size: NSSize(width: image.size.width, height: image.size.height + 2 * shift),
            flipped: false)
        { _ in
            image.draw(
                in: NSRect(
                    x: 0,
                    y: adjustment > 0 ? 2 * shift : 0,
                    width: image.size.width,
                    height: image.size.height))
            return true
        }
        offsetImage.isTemplate = image.isTemplate
        return offsetImage
    }

    /// Removes `baselineOffset` from all text runs and undoes each attachment run's recorded
    /// baseline shift so image-backed titles center cleanly in the 22 pt menu-bar canvas and apply
    /// only the user's `verticalAdjustment`, even when composed rows carry different baseline shifts.
    private static func prepareImageTitle(
        _ title: NSAttributedString,
        x: CGFloat = 0,
        canvasHeight: CGFloat = 22,
        verticalAdjustment: Int = 0)
        -> (title: NSAttributedString, bounds: NSRect, rect: NSRect)
    {
        let fullRange = NSRange(location: 0, length: title.length)
        let unshifted = NSMutableAttributedString(attributedString: title)
        // Meter/pace runs bake their shift into attachment bounds instead of baselineOffset.
        // Normalize each run with its own recorded shift before moving the complete title.
        title.enumerateAttributes(in: fullRange) { attributes, range, _ in
            guard let shift = (attributes[Self.attachmentBaselineShiftKey] as? NSNumber)?.doubleValue,
                  shift != 0,
                  let source = attributes[.attachment] as? NSTextAttachment else { return }
            let attachment = NSTextAttachment()
            attachment.image = source.image
            attachment.bounds = source.bounds.offsetBy(dx: 0, dy: -CGFloat(shift))
            unshifted.addAttribute(.attachment, value: attachment, range: range)
        }
        unshifted.removeAttribute(Self.attachmentBaselineShiftKey, range: fullRange)
        unshifted.removeAttribute(.baselineOffset, range: fullRange)
        let immutableTitle = NSAttributedString(attributedString: unshifted)
        let bounds = immutableTitle.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let rect = NSRect(
            x: x - bounds.minX,
            y: floor((canvasHeight - bounds.height) / 2) - bounds.minY + CGFloat(verticalAdjustment),
            width: bounds.width,
            height: bounds.height)
        return (immutableTitle, bounds, rect)
    }
}
