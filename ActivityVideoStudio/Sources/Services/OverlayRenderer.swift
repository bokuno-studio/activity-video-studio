import Foundation
import CoreGraphics
import AppKit

/// Renders activity data overlay onto video frames using Core Graphics.
final class OverlayRenderer {

    let videoSize: CGSize
    var settings: OverlaySettings

    /// All elevation data points for profile graph rendering.
    var allDataPoints: [FITDataPoint] = []

    // Scale factor: sizes are designed for 1920px width, scale up for 4K etc.
    private var scale: CGFloat { videoSize.width / 1920.0 }

    private var barHeight: CGFloat { 80 * scale }
    private var barPadding: CGFloat { 12 * scale }
    private var labelFontSize: CGFloat { 14 * scale }
    private var valueFontSize: CGFloat { 28 * scale }
    private var elevationProfileHeight: CGFloat { 100 * scale }
    private var elevationProfileWidth: CGFloat { 360 * scale }

    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    init(videoSize: CGSize, settings: OverlaySettings = OverlaySettings()) {
        self.videoSize = videoSize
        self.settings = settings
    }

    // MARK: - Public

    /// Total distance from FIT data (for display as denominator).
    var totalDistance: Double {
        allDataPoints.last?.distance ?? 0
    }

    /// Pre-computed cumulative elevation gain at each data point index.
    /// Call `buildElevationGainCache()` after setting `allDataPoints`.
    private var elevationGainCache: [Double] = []

    func buildElevationGainCache() {
        elevationGainCache = []
        var gain = 0.0
        var prevAlt: Double?
        for dp in allDataPoints {
            if let alt = dp.altitude {
                if let prev = prevAlt, alt > prev {
                    gain += alt - prev
                }
                prevAlt = alt
            }
            elevationGainCache.append(gain)
        }
    }

    /// Cumulative elevation gain up to a given distance (uses cache).
    func cumulativeElevationGain(upTo distance: Double?) -> Double {
        guard let target = distance, !elevationGainCache.isEmpty else { return 0 }
        // Binary search for index matching distance
        var lo = 0
        var hi = allDataPoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if let d = allDataPoints[mid].distance, d <= target {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return elevationGainCache[lo]
    }

    var totalElevationGain: Double {
        elevationGainCache.last ?? 0
    }

    /// Text overlays to render.
    var textOverlays: [TextOverlay] = []

    /// Whether FIT recording has started at the current playback position.
    var fitRecordingActive = true

    /// Render overlay for a data point and elapsed time.
    /// - Parameter globalPlaybackTime: The global playback time for text overlay timing.
    func render(dataPoint: FITDataPoint, elapsedTime: TimeInterval, globalPlaybackTime: TimeInterval = 0) -> CGImage? {
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

        // FIT未記録区間の表示
        if !fitRecordingActive {
            drawWaitingIndicator(context: context)
        }

        drawDashboardBar(context: context, dataPoint: dataPoint, elapsedTime: elapsedTime)

        if settings.showElevationProfile {
            drawElevationProfile(context: context, currentPoint: dataPoint)
        }

        // Text overlays
        for textOverlay in textOverlays {
            let opacity = textOverlay.opacity(at: globalPlaybackTime)
            if opacity > 0 {
                drawTextOverlay(context: context, overlay: textOverlay, opacity: opacity)
            }
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
            let current = dataPoint.distance.map { String(format: "%.2f", $0 / 1000.0) } ?? "--"
            let total = String(format: "%.2f", totalDistance / 1000.0)
            metrics.append(("DISTANCE", "\(current) / \(total) km", white))
        }
        if settings.showHeartRate {
            let (v, c) = formatHeartRate(dataPoint.heartRate)
            metrics.append(("HEART RATE", v, c))
        }
        if settings.showPace {
            let v = dataPoint.paceFormatted.map { "\($0)/km" } ?? "--'--\"/km"
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
            let v = dataPoint.runningCadence.map { "\($0) spm" } ?? "-- spm"
            metrics.append(("CADENCE", v, white))
        }
        if settings.showElevationGain {
            let gain = cumulativeElevationGain(upTo: dataPoint.distance)
            let v = String(format: "+%.0f m", gain)
            metrics.append(("ELEV GAIN", v, CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1)))
        }
        if settings.showCoreTemp {
            let v: String
            let c: CGColor
            if let ct = dataPoint.coreTemperature {
                v = String(format: "%.1f°C", ct)
                c = coreTempColor(ct)
            } else {
                v = "--°C"
                c = white
            }
            metrics.append(("CORE TEMP", v, c))
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
            x: videoSize.width - elevationProfileWidth - 16 * scale,
            y: barHeight + 16 * scale,
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
        context.setLineWidth(2 * scale)
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
            context.setLineWidth(2.5 * scale)
            context.beginPath()
            context.move(to: CGPoint(x: markerX, y: profileRect.minY))
            context.addLine(to: CGPoint(x: markerX, y: profileRect.maxY))
            context.strokePath()
        }
    }

    // MARK: - Text overlay

    private func drawTextOverlay(context: CGContext, overlay: TextOverlay, opacity: Double) {
        let scaledFontSize = overlay.fontSize * scale
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, scaledFontSize, nil)
        let textColor = NSColor(cgColor: overlay.color)?.withAlphaComponent(opacity) ?? NSColor.white.withAlphaComponent(opacity)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attrStr = NSAttributedString(string: overlay.text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // Position
        let x: CGFloat
        let y: CGFloat
        let padding = 20 * scale

        x = (videoSize.width - bounds.width) / 2

        switch overlay.position {
        case .topCenter:
            y = videoSize.height - padding - scaledFontSize
        case .center:
            y = (videoSize.height - scaledFontSize) / 2
        case .bottomCenter:
            y = barHeight + padding + scaledFontSize
        }

        // Background
        let bgRect = CGRect(
            x: x - padding,
            y: y - padding / 2,
            width: bounds.width + padding * 2,
            height: scaledFontSize + padding
        )
        context.saveGState()
        context.setAlpha(opacity)
        context.setFillColor(overlay.backgroundColor)
        context.fill(bgRect)
        context.restoreGState()

        // Text
        context.saveGState()
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Waiting indicator

    private func drawWaitingIndicator(context: CGContext) {
        let indicatorFont = CTFontCreateWithName("Helvetica" as CFString, 16 * scale, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: indicatorFont,
            .foregroundColor: NSColor(white: 0.6, alpha: 0.8)
        ]
        let str = NSAttributedString(string: "⏳ FIT 記録開始待ち", attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let x = 16 * scale
        let y = barHeight + 16 * scale

        // Background
        let bgRect = CGRect(x: x - 8 * scale, y: y - 4 * scale, width: bounds.width + 16 * scale, height: 20 * scale)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        context.fill(bgRect)

        context.saveGState()
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
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

    private func coreTempColor(_ temp: Double) -> CGColor {
        if temp >= 39.5 {
            return CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1)   // Danger
        } else if temp >= 39.0 {
            return CGColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1)   // Warning
        } else if temp >= 38.0 {
            return CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)   // Elevated
        } else {
            return CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1)   // Normal
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
