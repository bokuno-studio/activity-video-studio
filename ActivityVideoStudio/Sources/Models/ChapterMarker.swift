import Foundation

/// A chapter marker for YouTube chapter generation.
struct ChapterMarker: Identifiable {
    let id = UUID()
    var time: TimeInterval      // Absolute time on the combined untrimmed video timeline
    var label: String = ""
}
