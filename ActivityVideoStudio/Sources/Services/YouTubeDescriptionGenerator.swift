import Foundation

/// Generates YouTube video description from FIT activity data.
final class YouTubeDescriptionGenerator {

    struct ActivitySummary {
        let date: Date
        let totalDistance: Double       // meters
        let totalDuration: TimeInterval // seconds
        let elevationGain: Double       // meters
        let avgHeartRate: Int           // bpm
        let maxHeartRate: Int           // bpm
        let avgPace: Double             // seconds/km
        let minAltitude: Double         // meters
        let maxAltitude: Double         // meters
    }

    /// Generate summary from FIT data points.
    static func summarize(dataPoints: [FITDataPoint]) -> ActivitySummary? {
        guard let first = dataPoints.first, let last = dataPoints.last else { return nil }

        let hrs = dataPoints.compactMap { $0.heartRate }
        let alts = dataPoints.compactMap { $0.altitude }

        let totalDistance = last.distance ?? 0
        let totalDuration = last.timestamp.timeIntervalSince(first.timestamp)

        var elevGain = 0.0
        var prevAlt: Double?
        for dp in dataPoints {
            if let alt = dp.altitude {
                if let prev = prevAlt, alt > prev { elevGain += alt - prev }
                prevAlt = alt
            }
        }

        let avgHR = hrs.isEmpty ? 0 : hrs.reduce(0) { $0 + Int($1) } / hrs.count
        let maxHR = hrs.isEmpty ? 0 : Int(hrs.max()!)
        let avgPace = totalDistance > 0 ? totalDuration / (totalDistance / 1000) : 0

        return ActivitySummary(
            date: first.timestamp,
            totalDistance: totalDistance,
            totalDuration: totalDuration,
            elevationGain: elevGain,
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            avgPace: avgPace,
            minAltitude: alts.min() ?? 0,
            maxAltitude: alts.max() ?? 0
        )
    }

    /// Generate YouTube description text.
    static func generate(summary: ActivitySummary, chapters: [(time: TimeInterval, label: String)] = []) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy年M月d日"
        dateFormatter.locale = Locale(identifier: "ja_JP")

        let distKm = summary.totalDistance / 1000
        let paceMin = Int(summary.avgPace) / 60
        let paceSec = Int(summary.avgPace) % 60

        var lines: [String] = []

        // Header
        lines.append("📍 \(dateFormatter.string(from: summary.date)) トレイルランニング")
        lines.append("")

        // Stats
        lines.append("📊 アクティビティデータ")
        lines.append("距離: \(String(format: "%.2f", distKm)) km")
        lines.append("時間: \(formatDuration(summary.totalDuration))")
        lines.append("獲得標高: \(String(format: "%.0f", summary.elevationGain)) m")
        lines.append("標高: \(String(format: "%.0f", summary.minAltitude)) m 〜 \(String(format: "%.0f", summary.maxAltitude)) m")
        lines.append("平均ペース: \(paceMin)'\(String(format: "%02d", paceSec))\"/km")
        lines.append("平均心拍: \(summary.avgHeartRate) bpm / 最大心拍: \(summary.maxHeartRate) bpm")
        lines.append("")

        // Chapters
        if !chapters.isEmpty {
            lines.append("📖 チャプター")
            lines.append(contentsOf: chapterLines(chapters: chapters))
            lines.append("")
        }

        // Equipment
        lines.append("🎥 撮影機材")
        lines.append("カメラ: アクションカメラ")
        lines.append("GPS: GPSウォッチ")
        lines.append("編集アプリ: ActivityVideoStudio（Mac）https://apps.apple.com/app/activityvideostudio/id6764239734")
        lines.append("")

        // Hashtags
        lines.append("#トレイルランニング #trailrunning #アクションカメラ #アウトドア #ランニング")

        return lines.joined(separator: "\n")
    }

    static func chapterLines(chapters: [(time: TimeInterval, label: String)]) -> [String] {
        normalizedChapters(chapters).map { chapter in
            "\(formatTimestamp(chapter.seconds)) \(chapter.label)"
        }
    }

    // MARK: - Formatting

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d時間%02d分%02d秒", h, m, s)
        }
        return String(format: "%d分%02d秒", m, s)
    }

    private struct NormalizedChapter {
        var seconds: Int
        var label: String
    }

    private static func normalizedChapters(_ chapters: [(time: TimeInterval, label: String)]) -> [NormalizedChapter] {
        let sorted = chapters
            .enumerated()
            .map { index, chapter in
                (
                    index: index,
                    seconds: max(0, Int(chapter.time)),
                    rawLabel: chapter.label.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .sorted {
                if $0.seconds != $1.seconds { return $0.seconds < $1.seconds }
                return $0.index < $1.index
            }

        guard !sorted.isEmpty else { return [] }

        var result: [NormalizedChapter] = []
        if sorted[0].seconds > 0 {
            result.append(NormalizedChapter(seconds: 0, label: "スタート"))
        }

        for chapter in sorted {
            let label = chapter.rawLabel.isEmpty ? defaultChapterLabel(for: chapter.seconds) : chapter.rawLabel
            if let duplicateIndex = result.firstIndex(where: { $0.seconds == chapter.seconds }) {
                if result[duplicateIndex].label == defaultChapterLabel(for: chapter.seconds), !chapter.rawLabel.isEmpty {
                    result[duplicateIndex].label = chapter.rawLabel
                }
            } else {
                result.append(NormalizedChapter(seconds: chapter.seconds, label: label))
            }
        }

        return result
    }

    private static func defaultChapterLabel(for seconds: Int) -> String {
        seconds == 0 ? "スタート" : "チャプター"
    }

    private static func formatTimestamp(_ total: Int) -> String {
        let total = max(0, total)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

}
