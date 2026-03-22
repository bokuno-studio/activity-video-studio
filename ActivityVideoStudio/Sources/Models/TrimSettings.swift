import Foundation

/// Trim settings for a single video segment.
struct TrimSettings {
    var startTrim: TimeInterval = 0    // seconds to cut from start
    var endTrim: TimeInterval = 0      // seconds to cut from end

    /// Trimmed duration given the original duration.
    func trimmedDuration(original: TimeInterval) -> TimeInterval {
        max(0, original - startTrim - endTrim)
    }
}
