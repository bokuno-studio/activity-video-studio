import Foundation
import CoreGraphics
import AppKit

/// Renders activity data overlay onto video frames using Core Graphics.
final class OverlayRenderer {

    let videoSize: CGSize
    var settings: OverlaySettings

    /// All elevation data points for profile graph rendering.
    var allDataPoints: [FITDataPoint] = []

    private let barHeight: CGFloat = 70
    private let barPadding: CGFloat = 10
    private let labelFontSize: CGFloat = 10
    private let valueFontSize: CGFloat = 20
    private let elevationProfileHeight: CGFloat = 50
    private let elevationProfileWidth: CGFloat = 200

    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    init(videoSize: CGSize, settings: OverlaySettings = OverlaySettings()) {
        self.videoSize = videoSize
        self.settings = settings
    }

    // MARK: - Public

    /// Render overlay for a data point and elapsed time.
    func render(dataPoint: FITDataPoint, elapsedTime: TimeInterval) -> CGImage? {
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.textMatrix = .identity

        drawDashboardBar(context: context, dataPoint: dataPoint, elapsedTime: elapsedTime)

        if settings.showElevationProfile {
            drawElevationProfile(context: context, currentPoint: dataPoint)
        }

        return context.makeImage()
    }

    // MARK: - Dashboard bar

    private func drawDashboardBar(context: CGContext, dataPoint: FITDataPoint, elapsedTime: TimeInterval) {
        let barRect = CGRect(x: 0, y: 0, width: videoSize.width, height: barHeight)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: settings.overlayOpacity))
        context.fill(barRect)

        // Collect enabled metrics
        var metrics: [(label: String, value: String, color: CGColor)] = []

        if settings.showTime {
            metrics.append(("TIME", formatElapsedTime(elapsedTime), white))
        }
        if settings.showDistance {
            let v = dataPoint.distance.map { String(format: "%.2f km", $0 / 1000.0) } ?? "-- km"
            metrics.append(("DISTANCE", v, white))
        }
        if settings.showHeartRate {
            let (v, c) = formatHeartRate(dataPoint.heartRate)
            metrics.append(("HEART RATE", v, c))
        }
        if settings.showPace {
            let v = dataPoint.pace.map { String(format: "%.1f min/km", $0) } ?? "-- min/km"
            metrics.append(("PACE", v, white))
        }
        if settings.showAltitude {
            let v = dataPoint.altitude.map { String(format: "%.0f m", $0) } ?? "-- m"
            metrics.append(("ALTITUDE", v, white))
        }
        if settings.showGrade {
            let v: String
            let c: CGColor
            if let grade = dataPoint.grade {
                v = String(format: "%+.1f%%", grade)
                c = gradeColor(grade)
            } else {
                v = "-- %"
                c = white
            }
            metrics.append(("GRADE", v, c))
        }
        if settings.showCadence {
            let v = dataPoint.cadence.map { "\($0) spm" } ?? "-- spm"
            metrics.append(("CADENCE", v, white))
        }

        guard !metrics.isEmpty else { return }

        let sectionWidth = videoSize.width / CGFloat(metrics.count)
        for (i, metric) in metrics.enumerated() {
            drawMetric(
                context: context,
                label: metric.label,
                value: metric.value,
                x: sectionWidth * CGFloat(i),
                sectionWidth: sectionWidth,
                color: metric.color
            )
        }
    }

    private func drawMetric(context: CGContext, label: String, value: String, x: CGFloat, sectionWidth: CGFloat, color: CGColor) {
        // Label
        let labelFont = CTFontCreateWithName("Helvetica" as CFString, labelFontSize, nil)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor(white: 0.7, alpha: 1.0)
        ]
        let labelStr = NSAttributedString(string: label, attributes: labelAttrs)
        let labelLine = CTLineCreateWithAttributedString(labelStr)
        let labelBounds = CTLineGetBoundsWithOptions(labelLine, [])
        let labelX = x + (sectionWidth - labelBounds.width) / 2
        let labelY = barHeight - barPadding - labelFontSize

        context.saveGState()
        context.textPosition = CGPoint(x: labelX, y: labelY)
        CTLineDraw(labelLine, context)
        context.restoreGState()

        // Value
        let valueFont = CTFontCreateWithName("Helvetica-Bold" as CFString, valueFontSize, nil)
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.white
        ]
        let valueStr = NSAttributedString(string: value, attributes: valueAttrs)
        let valueLine = CTLineCreateWithAttributedString(valueStr)
        let valueBounds = CTLineGetBoundsWithOptions(valueLine, [])
        let valueX = x + (sectionWidth - valueBounds.width) / 2
        let valueY: CGFloat = barPadding

        context.saveGState()
        context.textPosition = CGPoint(x: valueX, y: valueY)
        CTLineDraw(valueLine, context)
        context.restoreGState()
    }

    // MARK: - Elevation profile

    private func drawElevationProfile(context: CGContext, currentPoint: FITDataPoint) {
        guard !allDataPoints.isEmpty else { return }

        let altitudes = allDataPoints.compactMap { $0.altitude }
        guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(), maxAlt > minAlt else { return }

        let profileRect = CGRect(
            x: videoSize.width - elevationProfileWidth - 16,
            y: barHeight + 12,
            width: elevationProfileWidth,
            height: elevationProfileHeight
        )

        // Background
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        context.fill(profileRect)

        // Draw elevation line
        let range = maxAlt - minAlt
        let pointsWithAlt = allDataPoints.filter { $0.altitude != nil }
        guard pointsWithAlt.count >= 2 else { return }

        context.setStrokeColor(CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 0.9))
        context.setLineWidth(1.5)
        context.beginPath()

        for (i, dp) in pointsWithAlt.enumerated() {
            guard let alt = dp.altitude else { continue }
            let x = profileRect.minX + (CGFloat(i) / CGFloat(pointsWithAlt.count - 1)) * profileRect.width
            let y = profileRect.minY + ((alt - minAlt) / range) * Double(profileRect.height)
            if i == 0 {
                context.move(to: CGPoint(x: x, y: y))
            } else {
                context.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.strokePath()

        // Current position marker
        if let currentDist = currentPoint.distance,
           let totalDist = allDataPoints.last?.distance,
           totalDist > 0 {
            let progress = currentDist / totalDist
            let markerX = profileRect.minX + CGFloat(progress) * profileRect.width

            context.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
            context.setLineWidth(2)
            context.beginPath()
            context.move(to: CGPoint(x: markerX, y: profileRect.minY))
            context.addLine(to: CGPoint(x: markerX, y: profileRect.maxY))
            context.strokePath()
        }
    }

    // MARK: - Formatting & colors

    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func formatHeartRate(_ hr: UInt8?) -> (String, CGColor) {
        guard let hr = hr else { return ("-- bpm", white) }
        return ("\(hr) bpm", heartRateColor(hr))
    }

    private func heartRateColor(_ hr: UInt8) -> CGColor {
        if hr <= settings.z1Max {
            return CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        } else if hr <= settings.z2Max {
            return CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)
        } else if hr <= settings.z3Max {
            return CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        } else if hr <= settings.z4Max {
            return CGColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1)
        } else {
            return CGColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1)
        }
    }

    private func gradeColor(_ grade: Double) -> CGColor {
        if grade > 5 {
            return CGColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1) // Steep uphill
        } else if grade > 0 {
            return CGColor(red: 1.0, green: 0.7, blue: 0.3, alpha: 1) // Mild uphill
        } else if grade > -5 {
            return CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1) // Mild downhill
        } else {
            return CGColor(red: 0.3, green: 0.4, blue: 1.0, alpha: 1) // Steep downhill
        }
    }
}
