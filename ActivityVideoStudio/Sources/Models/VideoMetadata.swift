import Foundation
import CoreGraphics

/// Metadata extracted from a GoPro MP4 file.
struct VideoMetadata {
    let url: URL
    let creationDate: Date?
    let quickTimeCreationDate: Date?
    let duration: TimeInterval  // seconds
    let naturalSize: CGSize?

    init(
        url: URL,
        creationDate: Date?,
        quickTimeCreationDate: Date? = nil,
        duration: TimeInterval,
        naturalSize: CGSize?
    ) {
        self.url = url
        self.creationDate = creationDate
        self.quickTimeCreationDate = quickTimeCreationDate
        self.duration = duration
        self.naturalSize = naturalSize
    }

    var usesQuickTimeCreationDate: Bool {
        quickTimeCreationDate != nil
    }

    var nativeWidth: Int? {
        guard let naturalSize else { return nil }
        return Int(abs(naturalSize.width).rounded(.down))
    }
}
