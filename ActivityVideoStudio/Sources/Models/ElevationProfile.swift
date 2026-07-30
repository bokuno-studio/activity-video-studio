import Foundation
import CoreGraphics

/// Time-based elevation data, split wherever recording stopped.
struct ElevationProfile {
    struct Sample {
        let timeRatio: CGFloat
        let altitude: Double
    }

    let segments: [[Sample]]
    let startTime: Date
    let duration: TimeInterval
    let minAltitude: Double
    let maxAltitude: Double

    static func make(dataPoints: [FITDataPoint]) -> ElevationProfile? {
        let points = dataPoints.sorted { $0.timestamp < $1.timestamp }
        guard let startTime = points.first?.timestamp,
              let endTime = points.last?.timestamp else { return nil }

        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return nil }

        var segments: [[Sample]] = []
        var current: [Sample] = []
        var previousTimestamp: Date?
        var minAltitude = Double.greatestFiniteMagnitude
        var maxAltitude = -Double.greatestFiniteMagnitude

        for point in points {
            if let previousTimestamp,
               point.timestamp.timeIntervalSince(previousTimestamp) > FITMerger.gapThreshold,
               !current.isEmpty {
                segments.append(current)
                current = []
            }
            previousTimestamp = point.timestamp

            guard let altitude = point.altitude else { continue }
            current.append(Sample(
                timeRatio: CGFloat(min(max(point.timestamp.timeIntervalSince(startTime) / duration, 0), 1)),
                altitude: altitude
            ))
            minAltitude = min(minAltitude, altitude)
            maxAltitude = max(maxAltitude, altitude)
        }
        if !current.isEmpty { segments.append(current) }

        guard !segments.isEmpty, maxAltitude > minAltitude else { return nil }
        return ElevationProfile(
            segments: segments,
            startTime: startTime,
            duration: duration,
            minAltitude: minAltitude,
            maxAltitude: maxAltitude
        )
    }

    func timeRatio(at date: Date) -> CGFloat? {
        guard duration > 0 else { return nil }
        return CGFloat(min(max(date.timeIntervalSince(startTime) / duration, 0), 1))
    }

    func downsampled(maxSamples: Int) -> ElevationProfile {
        let total = segments.reduce(0) { $0 + $1.count }
        guard total > maxSamples, maxSamples > 0 else { return self }

        let budget = max(maxSamples, segments.count)
        var counts = segments.map { max(1, min($0.count, Int((Double($0.count) / Double(total) * Double(budget)).rounded()))) }
        while counts.reduce(0, +) > budget {
            guard let index = counts.indices.filter({ counts[$0] > 1 }).max(by: { counts[$0] < counts[$1] }) else { break }
            counts[index] -= 1
        }

        let result = zip(segments, counts).map { samples, count in
            guard samples.count > count else { return samples }
            guard count > 1 else { return [samples[0]] }
            let last = samples.count - 1
            return (0..<count).map { index in
                samples[min(Int((Double(index) * Double(last) / Double(count - 1)).rounded()), last)]
            }
        }
        return ElevationProfile(segments: result, startTime: startTime, duration: duration, minAltitude: minAltitude, maxAltitude: maxAltitude)
    }
}
