import AppKit
import CoreText

/// Camera date-back lettering, drawn as vectors on the existing FP32 photo canvas.
enum PhotoDateStampRenderer {
    static func draw(_ style: DateStampStyle, in rect: CGRect, context: CGContext, date: Date = Date()) {
        guard rect.width > 0, rect.height > 0 else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = style.dateFormat
        let lettering = path(for: formatter.string(from: date))
        let shortSide = min(rect.width, rect.height)
        let padding = shortSide * 0.038
        let height = min(shortSide * 0.024, (rect.width - padding * 2) / max(lettering.boundingBoxOfPath.width, 1))
        var scale = CGAffineTransform(a: height, b: 0, c: -height * 0.035, d: height, tx: 0, ty: 0)
        guard let sized = lettering.copy(using: &scale) else { return }
        let bounds = sized.boundingBoxOfPath
        var placement = CGAffineTransform(translationX: rect.maxX - padding - bounds.maxX,
                                         y: rect.maxY - padding - bounds.maxY)
        guard let stamp = sized.copy(using: &placement) else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.setShouldAntialias(true)
        context.setBlendMode(.normal)
        // A red exposure halo and a warm core stay legible on both light and dark photos.
        context.setShadow(offset: .zero, blur: height * 0.18,
                          color: NSColor(srgbRed: 1, green: 0.16, blue: 0.015, alpha: 0.55).cgColor)
        context.setFillColor(NSColor(srgbRed: 1, green: 0.43, blue: 0.09, alpha: 0.94).cgColor)
        context.addPath(stamp)
        context.fillPath()
        context.setShadow(offset: .zero, blur: height * 0.035,
                          color: NSColor(srgbRed: 1, green: 0.48, blue: 0.12, alpha: 0.45).cgColor)
        context.setStrokeColor(NSColor(srgbRed: 1, green: 0.71, blue: 0.31, alpha: 0.38).cgColor)
        context.setLineWidth(height * 0.018)
        context.setLineJoin(.round)
        context.addPath(stamp)
        context.strokePath()
    }

    private static func path(for text: String) -> CGPath {
        let result = CGMutablePath()
        // Segments A ... G, clockwise from the top; G is the middle bar.
        let masks = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f]
        let segments: [(CGPoint, CGPoint)] = [
            (.init(x: 0.08, y: 0.045), .init(x: 0.52, y: 0.045)),
            (.init(x: 0.555, y: 0.105), .init(x: 0.555, y: 0.445)),
            (.init(x: 0.555, y: 0.555), .init(x: 0.555, y: 0.895)),
            (.init(x: 0.08, y: 0.955), .init(x: 0.52, y: 0.955)),
            (.init(x: 0.045, y: 0.555), .init(x: 0.045, y: 0.895)),
            (.init(x: 0.045, y: 0.105), .init(x: 0.045, y: 0.445)),
            (.init(x: 0.08, y: 0.5), .init(x: 0.52, y: 0.5))
        ]
        var x: CGFloat = 0
        for character in text {
            let glyph = CGMutablePath()
            let advance: CGFloat
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                for (index, ends) in segments.enumerated() where masks[digit] & (1 << index) != 0 {
                    segment(from: ends.0, to: ends.1, width: 0.075, into: glyph)
                }
                advance = 0.75
            } else if character == "." {
                glyph.addRoundedRect(in: CGRect(x: 0.015, y: 0.89, width: 0.095, height: 0.095),
                                     cornerWidth: 0.018, cornerHeight: 0.018)
                advance = 0.27
            } else if character == "/" {
                segment(from: CGPoint(x: 0.04, y: 0.94), to: CGPoint(x: 0.38, y: 0.05), width: 0.065, into: glyph)
                advance = 0.53
            } else {
                // Preserve the existing Japanese date format, using glyph outlines in the same ink.
                let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 1, nil)
                var code = character.utf16.first ?? 32
                var index: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(font, &code, &index, 1),
                   let outline = CTFontCreatePathForGlyph(font, index, nil), !outline.isEmpty {
                    let box = outline.boundingBoxOfPath
                    let factor = 0.88 / max(box.height, 0.01)
                    var transform = CGAffineTransform(a: factor, b: 0, c: 0, d: -factor,
                                                     tx: -box.minX * factor, ty: 0.95 + box.minY * factor)
                    if let normalized = outline.copy(using: &transform) { glyph.addPath(normalized) }
                    advance = box.width * factor + 0.18
                } else {
                    advance = 0.35
                }
            }
            result.addPath(glyph, transform: CGAffineTransform(translationX: x, y: 0))
            x += advance
        }
        return result
    }

    private static func segment(from start: CGPoint, to end: CGPoint, width: CGFloat, into path: CGMutablePath) {
        let length = hypot(end.x - start.x, end.y - start.y)
        let dx = (end.x - start.x) / length * width / 2
        let dy = (end.y - start.y) / length * width / 2
        path.move(to: start)
        path.addLine(to: CGPoint(x: start.x + dx - dy, y: start.y + dy + dx))
        path.addLine(to: CGPoint(x: end.x - dx - dy, y: end.y - dy + dx))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - dx + dy, y: end.y - dy - dx))
        path.addLine(to: CGPoint(x: start.x + dx + dy, y: start.y + dy - dx))
        path.closeSubpath()
    }
}
