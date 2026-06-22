import Foundation

/// A chapter marker for YouTube chapter generation.
struct ChapterMarker: Identifiable, Codable {
    let id: UUID
    var time: TimeInterval      // Absolute time on the combined untrimmed video timeline
    var label: String = ""

    init(id: UUID = UUID(), time: TimeInterval, label: String = "") {
        self.id = id
        self.time = time
        self.label = label
    }
}
