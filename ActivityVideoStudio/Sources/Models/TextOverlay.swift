import Foundation
import CoreGraphics

/// A text overlay to be displayed at a specific time range on the video.
struct TextOverlay: Identifiable {
    let id = UUID()
    var text: String
    var startTime: TimeInterval      // seconds from video start
    var duration: TimeInterval = 15   // how long to display
    var fontSize: CGFloat = 48
    var position: Position = .center
    var color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    var backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.3)
    var fadeInDuration: TimeInterval = 0
    var fadeOutDuration: TimeInterval = 0.5

    enum Position: String, CaseIterable {
        case topCenter = "上中央"
        case center = "中央"
        case bottomCenter = "下中央"
    }

    /// Opacity at a given playback time (handles fade in/out).
    func opacity(at time: TimeInterval) -> Double {
        let relativeTime = time - startTime
        guard relativeTime >= 0, relativeTime <= duration else { return 0 }

        // Fade in
        if relativeTime < fadeInDuration {
            return relativeTime / fadeInDuration
        }
        // Fade out
        let fadeOutStart = duration - fadeOutDuration
        if relativeTime > fadeOutStart {
            return (duration - relativeTime) / fadeOutDuration
        }
        return 1.0
    }
}
