import SwiftUI

/// Displays the overlay image on top of the video.
struct OverlayView: View {
    let overlayImage: CGImage?

    var body: some View {
        if let image = overlayImage {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
