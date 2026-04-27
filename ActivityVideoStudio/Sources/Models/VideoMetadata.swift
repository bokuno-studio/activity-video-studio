import Foundation
import CoreGraphics

/// Metadata extracted from a GoPro MP4 file.
struct VideoMetadata {
    let url: URL
    let creationDate: Date?
    let duration: TimeInterval  // seconds
    let naturalSize: CGSize?

    var nativeWidth: Int? {
        guard let naturalSize else { return nil }
        return Int(abs(naturalSize.width).rounded(.down))
    }
}
