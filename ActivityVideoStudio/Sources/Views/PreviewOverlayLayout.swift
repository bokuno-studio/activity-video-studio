import SwiftUI

/// Keep the clipping region in video-local coordinates, then move both the
/// content and its clip into the player's letterboxed video rectangle.
struct PreviewOverlayLayout: ViewModifier {
    let videoRect: CGRect

    func body(content: Content) -> some View {
        content
            .frame(width: videoRect.width, height: videoRect.height)
            .clipped()
            .offset(x: videoRect.minX, y: videoRect.minY)
    }
}
