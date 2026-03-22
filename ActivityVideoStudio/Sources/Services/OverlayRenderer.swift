import Foundation
import CoreGraphics
import AppKit

/// Renders floating activity data overlay with circular HR gauge.
/// Layout: right side dominant, no bottom bar, drop shadows on text.
final class OverlayRenderer {

    let videoSize: CGSize
    var settings: OverlaySettings
    var allDataPoints: [FITDataPoint] = []
    var textOverlays: [TextOverlay] = []
    var fitRecordingActive = true

    private var scale: CGFloat { videoSize.width / 1920.0 }

    // Elevation gain cache
    private var elevationGainCache: [Double] = []

    func buildElevationGainCache() {
        elevationGainCache = []
        var gain = 0.0
        var prevAlt: Double?
        for dp in allDataPoints {
            if let a = dp.altitude { if let pa = prevAlt, a > pa { gain += a - pa }; prevAlt = a }
            elevationGainCache.append(gain)
        }
    }

    func cumulativeElevationGain(upTo distance: Double?) -> Double {
        guard let target = distance, !elevationGainCache.isEmpty else { return 0 }
        var lo = 0; var hi = allDataPoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if let d = allDataPoints[mid].distance, d <= target { lo = mid } else { hi = mid - 1 }
        }
        return elevationGainCache[lo]
    }

    var totalDistance: Double { allDataPoints.last?.distance ?? 0 }
    var totalElevationGain: Double { elevationGainCache.last ?? 0 }

    // Colors
    private let accentColor = CGColor(red: 1.0, green: 0.45, blue: 0.1, alpha: 1)   // Orange
    private let accentRed = CGColor(red: 1.0, green: 0.2, blue: 0.15, alpha: 1)
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.7)

    // Elevation profile
    private var elevationProfileHeight: CGFloat { 100 * scale }
    private var elevationProfileWidth: CGFloat { 360 * scale }

    init(videoSize: CGSize, settings: OverlaySettings = OverlaySettings()) {
        self.videoSize = videoSize
        self.settings = settings
    }

    // MARK: - Render

    func render(dataPoint: FITDataPoint, elapsedTime: TimeInterval, globalPlaybackTime: TimeInterval = 0) -> CGImage? {
        let w = Int(videoSize.width), h = Int(videoSize.height)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.textMatrix = .identity
        ctx.setShadow(offset: CGSize(width: 1.5 * scale, height: -1.5 * scale), blur: 3 * scale, color: shadowColor)

        if !fitRecordingActive {
            drawWaitingIndicator(ctx: ctx)
        }

        // Right side: top area - SLOPE + ELEVATION
        var rightY = videoSize.height - 30 * scale

        if settings.showGrade {
            let label = "SLOPE"
            let value: String
            if let grade = dataPoint.grade {
                value = String(format: "%+.0f %%", grade)
            } else {
                value = "-- %"
            }
            drawLabelValue(ctx: ctx, label: label, value: value, x: videoSize.width - 400 * scale, y: rightY, labelColor: accentColor, valueSize: 48)
        }

        if settings.showAltitude {
            let label = "ELEVATION"
            let value = dataPoint.altitude.map { String(format: "%.0f M", $0) } ?? "-- M"
            drawLabelValue(ctx: ctx, label: label, value: value, x: videoSize.width - 180 * scale, y: rightY, labelColor: accentColor, valueSize: 48)
        }

        // Right side: middle - HR gauge
        if settings.showHeartRate {
            let gaugeCenter = CGPoint(x: videoSize.width - 160 * scale, y: videoSize.height * 0.45)
            let gaugeRadius = 120 * scale
            drawHeartRateGauge(ctx: ctx, hr: dataPoint.heartRate, center: gaugeCenter, radius: gaugeRadius)
        }

        // Right side: below HR - Time
        rightY = videoSize.height * 0.22
        if settings.showTime {
            let value = formatElapsedTime(elapsedTime)
            drawLabelValue(ctx: ctx, label: "TIME", value: value, x: videoSize.width - 300 * scale, y: rightY, labelColor: accentColor, valueSize: 44)
        }

        // Right bottom - Pace
        if settings.showPace {
            let value = dataPoint.paceFormatted ?? "--'--\""
            drawText(ctx: ctx, text: value, x: videoSize.width - 200 * scale, y: 50 * scale, fontSize: 44 * scale, color: white, bold: true)
        }

        // Right bottom - Core temp (above pace)
        if settings.showCoreTemp, let ct = dataPoint.coreTemperature {
            let value = String(format: "%.1f°C", ct)
            let c = coreTempColor(ct)
            drawLabelValue(ctx: ctx, label: "CORE", value: value, x: videoSize.width - 200 * scale, y: 150 * scale, labelColor: accentColor, valueSize: 36, valueColor: c)
        }

        // Left bottom - Distance
        if settings.showDistance {
            let current = dataPoint.distance.map { String(format: "%.1f", $0 / 1000.0) } ?? "--"
            let total = String(format: "/ %.1f", totalDistance / 1000.0)
            drawText(ctx: ctx, text: "\(current) KM", x: 40 * scale, y: 60 * scale, fontSize: 50 * scale, color: white, bold: true)
            drawText(ctx: ctx, text: total, x: 40 * scale, y: 30 * scale, fontSize: 22 * scale, color: white)
        }

        // Left bottom - Cadence (above distance)
        if settings.showCadence {
            let value = dataPoint.runningCadence.map { "\($0) spm" } ?? "-- spm"
            drawLabelValue(ctx: ctx, label: "CADENCE", value: value, x: 40 * scale, y: 190 * scale, labelColor: accentColor, valueSize: 36)
        }

        // Left bottom - Elev gain (above cadence)
        if settings.showElevationGain {
            let gain = cumulativeElevationGain(upTo: dataPoint.distance)
            let value = String(format: "+%.0f m", gain)
            drawLabelValue(ctx: ctx, label: "ELEV GAIN", value: value, x: 40 * scale, y: 290 * scale, labelColor: accentColor, valueSize: 36, valueColor: CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1))
        }

        // Elevation profile - right side above pace
        if settings.showElevationProfile {
            drawElevationProfile(ctx: ctx, currentPoint: dataPoint)
        }

        // Text overlays
        for textOverlay in textOverlays {
            let opacity = textOverlay.opacity(at: globalPlaybackTime)
            if opacity > 0 { drawTextOverlay(ctx: ctx, overlay: textOverlay, opacity: opacity) }
        }

        return ctx.makeImage()
    }

    // MARK: - HR Gauge

    private func drawHeartRateGauge(ctx: CGContext, hr: UInt8?, center: CGPoint, radius: CGFloat) {
        let startAngle = CGFloat.pi * 0.75  // bottom-left
        let endAngle = CGFloat.pi * 0.25    // bottom-right (going clockwise through top)
        let totalArc = CGFloat.pi * 1.5

        // Background arc
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.5))
        ctx.setLineWidth(12 * scale)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

        // HR value arc
        if let hr = hr {
            let hrFraction = CGFloat(min(max(Int(hr) - 60, 0), 140)) / 140.0 // 60-200 range
            let hrAngle = startAngle - totalArc * hrFraction

            // Draw colored arc segments
            let segments = 50
            for i in 0..<segments {
                let segFraction = CGFloat(i) / CGFloat(segments)
                if segFraction > hrFraction { break }

                let segStart = startAngle - totalArc * segFraction
                let segEnd = startAngle - totalArc * min(segFraction + 1.0 / CGFloat(segments), hrFraction)

                let color = hrZoneColor(fraction: segFraction)

                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 0)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(12 * scale)
                ctx.setLineCap(.butt)
                ctx.addArc(center: center, radius: radius, startAngle: segStart, endAngle: segEnd, clockwise: true)
                ctx.strokePath()
                ctx.restoreGState()
            }

            // HR number
            let hrStr = "\(hr)"
            let hrFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 80 * scale, nil)
            let hrAttrs: [NSAttributedString.Key: Any] = [
                .font: hrFont,
                .foregroundColor: NSColor.white
            ]
            let hrAttrStr = NSAttributedString(string: hrStr, attributes: hrAttrs)
            let hrLine = CTLineCreateWithAttributedString(hrAttrStr)
            let hrBounds = CTLineGetBoundsWithOptions(hrLine, [])
            let hrX = center.x - hrBounds.width / 2
            let hrY = center.y - 10 * scale

            ctx.saveGState()
            ctx.textPosition = CGPoint(x: hrX, y: hrY)
            CTLineDraw(hrLine, ctx)
            ctx.restoreGState()

            // "BPM" label below number
            drawText(ctx: ctx, text: "BPM", x: center.x - 28 * scale, y: center.y - radius + 15 * scale, fontSize: 22 * scale, color: accentColor, bold: true)

            // "HR" label above
            drawText(ctx: ctx, text: "HR", x: center.x - 14 * scale, y: center.y + radius - 5 * scale, fontSize: 18 * scale, color: accentColor, bold: true)
        }
    }

    /// Color for HR gauge arc by fraction (0=low, 1=high).
    private func hrZoneColor(fraction: CGFloat) -> CGColor {
        if fraction < 0.3 {
            return CGColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1)   // Green (Z1-Z2)
        } else if fraction < 0.5 {
            return CGColor(red: 0.4, green: 0.9, blue: 0.1, alpha: 1)   // Light green
        } else if fraction < 0.65 {
            return CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)   // Yellow (Z3)
        } else if fraction < 0.8 {
            return CGColor(red: 1.0, green: 0.45, blue: 0.1, alpha: 1)  // Orange (Z4)
        } else {
            return CGColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1) // Red (Z5)
        }
    }

    // MARK: - Elevation Profile

    private func drawElevationProfile(ctx: CGContext, currentPoint: FITDataPoint) {
        guard !allDataPoints.isEmpty else { return }
        let altitudes = allDataPoints.compactMap { $0.altitude }
        guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(), maxAlt > minAlt else { return }

        let profileRect = CGRect(
            x: videoSize.width - elevationProfileWidth - 20 * scale,
            y: 120 * scale,
            width: elevationProfileWidth,
            height: elevationProfileHeight
        )

        // Semi-transparent background
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        let bgPath = CGPath(roundedRect: profileRect, cornerWidth: 6 * scale, cornerHeight: 6 * scale, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Elevation line
        let range = maxAlt - minAlt
        let pointsWithAlt = allDataPoints.filter { $0.altitude != nil }
        guard pointsWithAlt.count >= 2 else { return }

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)

        // Fill under the line
        ctx.beginPath()
        ctx.move(to: CGPoint(x: profileRect.minX, y: profileRect.minY))
        for (i, dp) in pointsWithAlt.enumerated() {
            guard let alt = dp.altitude else { continue }
            let x = profileRect.minX + (CGFloat(i) / CGFloat(pointsWithAlt.count - 1)) * profileRect.width
            let y = profileRect.minY + ((alt - minAlt) / range) * Double(profileRect.height)
            if i == 0 { ctx.move(to: CGPoint(x: x, y: profileRect.minY)); ctx.addLine(to: CGPoint(x: x, y: y)) }
            else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.addLine(to: CGPoint(x: profileRect.maxX, y: profileRect.minY))
        ctx.closePath()
        ctx.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 0.2))
        ctx.fillPath()

        // Stroke the line
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 0.9))
        ctx.setLineWidth(2 * scale)
        ctx.beginPath()
        for (i, dp) in pointsWithAlt.enumerated() {
            guard let alt = dp.altitude else { continue }
            let x = profileRect.minX + (CGFloat(i) / CGFloat(pointsWithAlt.count - 1)) * profileRect.width
            let y = profileRect.minY + ((alt - minAlt) / range) * Double(profileRect.height)
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.strokePath()

        // Current position marker
        if let cd = currentPoint.distance, let td = allDataPoints.last?.distance, td > 0 {
            let progress = cd / td
            let mx = profileRect.minX + CGFloat(progress) * profileRect.width
            ctx.setStrokeColor(accentRed)
            ctx.setLineWidth(2.5 * scale)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: mx, y: profileRect.minY))
            ctx.addLine(to: CGPoint(x: mx, y: profileRect.maxY))
            ctx.strokePath()

            // Dot at current altitude
            if let alt = currentPoint.altitude {
                let dotY = profileRect.minY + ((alt - minAlt) / range) * Double(profileRect.height)
                ctx.setFillColor(white)
                ctx.fillEllipse(in: CGRect(x: mx - 4 * scale, y: CGFloat(dotY) - 4 * scale, width: 8 * scale, height: 8 * scale))
            }
        }

        ctx.restoreGState()
    }

    // MARK: - Text helpers

    private func drawLabelValue(ctx: CGContext, label: String, value: String, x: CGFloat, y: CGFloat, labelColor: CGColor, valueSize: CGFloat = 44, valueColor: CGColor? = nil) {
        // Label
        drawText(ctx: ctx, text: label, x: x, y: y, fontSize: 18 * scale, color: labelColor, bold: true)
        // Value
        drawText(ctx: ctx, text: value, x: x, y: y - 40 * scale, fontSize: valueSize * scale, color: valueColor ?? white, bold: true)
    }

    private func drawText(ctx: CGContext, text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, color: CGColor, bold: Bool = false) {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)

        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Text overlay

    private func drawTextOverlay(ctx: CGContext, overlay: TextOverlay, opacity: Double) {
        let fontSize = overlay.fontSize * scale
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let textColor = NSColor(cgColor: overlay.color)?.withAlphaComponent(opacity) ?? NSColor.white.withAlphaComponent(opacity)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let attrStr = NSAttributedString(string: overlay.text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let x = (videoSize.width - bounds.width) / 2
        let y: CGFloat
        let padding = 20 * scale

        switch overlay.position {
        case .topCenter: y = videoSize.height - padding - fontSize
        case .center: y = (videoSize.height - fontSize) / 2
        case .bottomCenter: y = padding + fontSize + 80 * scale
        }

        let bgRect = CGRect(x: x - padding, y: y - padding / 2, width: bounds.width + padding * 2, height: fontSize + padding)
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.setFillColor(overlay.backgroundColor)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.fill(bgRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Waiting indicator

    private func drawWaitingIndicator(ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16 * scale, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.6, alpha: 0.8)
        ]
        let str = NSAttributedString(string: "FIT 記録開始待ち", attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)

        ctx.saveGState()
        ctx.textPosition = CGPoint(x: 30 * scale, y: videoSize.height - 40 * scale)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Formatting

    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    private func coreTempColor(_ temp: Double) -> CGColor {
        if temp >= 39.5 { return CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1) }
        else if temp >= 39.0 { return CGColor(red: 1, green: 0.4, blue: 0, alpha: 1) }
        else if temp >= 38.0 { return CGColor(red: 1, green: 0.8, blue: 0, alpha: 1) }
        else { return CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1) }
    }
}
