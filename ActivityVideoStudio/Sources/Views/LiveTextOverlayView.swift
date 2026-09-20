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

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            guard opacity > 0, size.width > 0, size.height > 0 else { return }
            // Core Text must draw into a video-local surface. Canvas's borrowed
            // CGContext can carry the enclosing view's clip/transform, including
            // letterbox placement. Flipping that context does not reset its clip.
            // Composite the completed surface so placement cannot truncate a line.
            let pixelWidth = Int(ceil(size.width * displayScale))
            let pixelHeight = Int(ceil(size.height * displayScale))
            guard let bitmap = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            bitmap.scaleBy(x: CGFloat(pixelWidth) / size.width,
                           y: CGFloat(pixelHeight) / size.height)
            bitmap.textMatrix = .identity
            OverlayRenderer.drawTextOverlay(
                ctx: bitmap, overlay: overlay, opacity: opacity,
                videoSize: size, scale: scale,
                font: textOverlayFont(size: max(1, overlay.fontSize * scale))
            )
            if let image = bitmap.makeImage() {
                context.draw(Image(decorative: image, scale: displayScale),
                             in: CGRect(origin: .zero, size: size))
            }
        }
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
