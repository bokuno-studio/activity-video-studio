import Foundation

/// Metadata extracted from a GoPro MP4 file.
struct VideoMetadata {
    let url: URL
    let creationDate: Date?
    let duration: TimeInterval  // seconds
}
