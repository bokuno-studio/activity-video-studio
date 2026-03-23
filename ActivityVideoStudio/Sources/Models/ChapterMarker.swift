import Foundation

/// A chapter marker for YouTube chapter generation.
struct ChapterMarker: Identifiable {
    let id = UUID()
    var time: TimeInterval      // Trimmed playback time (0 = after trim start)
    var label: String = ""
}
