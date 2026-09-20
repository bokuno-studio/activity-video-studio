import SwiftUI
import AppKit
import CoreText

struct LiveTextOverlayLayer: View {
    let overlays: [TextOverlay]
    let playbackTime: TimeInterval
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(overlays) { overlay in
                let opacity = overlay.opacity(at: playbackTime)
                if opacity > 0 {
                    LiveTextOverlayView(
                        overlay: overlay,
                        opacity: opacity,
                        scale: scale
                    )
                    .frame(width: size.width, height: size.height)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct LiveTextOverlayView: View {
    let overlay: TextOverlay
    let opacity: Double
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cgContext in
                drawTextOverlay(ctx: cgContext, size: size)
            }
        }
    }

    private func drawTextOverlay(ctx: CGContext, size: CGSize) {
        guard opacity > 0, size.width > 0, size.height > 0 else { return }

        let fontSize = max(1, overlay.fontSize * scale)
        let font = textOverlayFont(size: fontSize)
        let textColor = nsColor(overlay.color, applyingOpacity: opacity, fallback: .white)
        let strokeColor = nsColor(overlay.strokeColor, applyingOpacity: opacity, fallback: .black)
        let shadowColor = cgColor(overlay.shadowColor, applyingOpacity: opacity, fallback: .black)
        let padding = 30 * scale
        let strokeWidth = max(0, overlay.strokeWidth) * scale
        let lineHeight = max(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), fontSize * 1.2)

        let lines = overlay.text.components(separatedBy: "\n")
        var lineData: [(CTLine, CGFloat, CGRect)] = []
        var maxWidth: CGFloat = 0

        for lineText in lines {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            if strokeWidth > 0 {
                attrs[.strokeColor] = strokeColor
                attrs[.strokeWidth] = -(strokeWidth / fontSize * 100)
            }
            let attrStr = NSAttributedString(string: lineText, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            lineData.append((ctLine, width, bounds))
            maxWidth = max(maxWidth, width)
        }

        let totalHeight = lineHeight * CGFloat(lines.count)
        let centerX = min(max(overlay.relativeX, 0), 1) * size.width
        let centerY = size.height - min(max(overlay.relativeY, 0), 1) * size.height
        let textRect = CGRect(
            x: centerX - maxWidth / 2,
            y: centerY - totalHeight / 2,
            width: maxWidth,
            height: totalHeight
        )
        let bgRect = CGRect(
            x: textRect.minX - padding - strokeWidth,
            y: textRect.minY - padding / 2 - strokeWidth,
            width: maxWidth + padding * 2 + strokeWidth * 2,
            height: totalHeight + padding + strokeWidth * 2
        ).integral

        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity

        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.setFillColor(overlay.backgroundColor)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.fill(bgRect)
        ctx.restoreGState()

        let firstBaseline = centerY + totalHeight / 2 - CTFontGetAscent(font)
        for (index, (ctLine, width, bounds)) in lineData.enumerated() {
            let x = centerX - width / 2 - bounds.origin.x
            let y = firstBaseline - lineHeight * CGFloat(index)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: overlay.shadowOffsetX * scale, height: overlay.shadowOffsetY * scale),
                blur: max(0, overlay.shadowBlur) * scale,
                color: shadowColor
            )
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }

        ctx.restoreGState()
    }

    private func textOverlayFont(size: CGFloat) -> CTFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.liveNSFontWeight)
        let nsFont = NSFontManager.shared.font(
            withFamily: overlay.fontFamily,
            traits: [],
            weight: overlay.fontWeight.liveNSFontManagerWeight,
            size: size
        ) ?? fallback

        return CTFontCreateWithName(nsFont.fontName as CFString, size, nil)
    }

    private func nsColor(_ color: CGColor, applyingOpacity opacity: Double, fallback: NSColor) -> NSColor {
        let base = NSColor(cgColor: color) ?? fallback
        return base.withAlphaComponent(base.alphaComponent * CGFloat(opacity))
    }

    private func cgColor(_ color: CGColor, applyingOpacity opacity: Double, fallback: NSColor) -> CGColor {
        nsColor(color, applyingOpacity: opacity, fallback: fallback).cgColor
    }
}

private extension TextOverlay.FontWeight {
    var liveNSFontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var liveNSFontManagerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }
}
