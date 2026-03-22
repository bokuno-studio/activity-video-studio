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
    private var elevationProfileHeight: CGFloat { 120 * scale }
    private var elevationProfileWidth: CGFloat { 420 * scale }

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

        // === LEFT SIDE (top→bottom): HR → PACE → CADENCE → CORE ===
        var leftY = videoSize.height - 50 * scale

        // HR + Zone
        if settings.showHeartRate {
            let hrValue: String
            let hrColor: CGColor
            if let hr = dataPoint.heartRate {
                let zone = heartRateZone(hr)
                hrValue = "\(hr) bpm  Z\(zone)"
                hrColor = hrZoneColorByZone(zone)
            } else {
                hrValue = "-- bpm"
                hrColor = white
            }
            drawLabelValue(ctx: ctx, label: "HEART RATE", value: hrValue, x: 50 * scale, y: leftY, labelColor: accentColor, valueColor: hrColor)
            leftY -= 130 * scale
        }

        // PACE
        if settings.showPace {
            let value = dataPoint.paceFormatted ?? "--'--\""
            drawLabelValue(ctx: ctx, label: "PACE", value: value, x: 50 * scale, y: leftY, labelColor: accentColor)
            leftY -= 130 * scale
        }

        // CADENCE
        if settings.showCadence {
            let value = dataPoint.runningCadence.map { "\($0) spm" } ?? "-- spm"
            drawLabelValue(ctx: ctx, label: "CADENCE", value: value, x: 50 * scale, y: leftY, labelColor: accentColor)
            leftY -= 130 * scale
        }

        // CORE TEMP
        if settings.showCoreTemp, let ct = dataPoint.coreTemperature {
            let value = String(format: "%.1f°C", ct)
            let c = coreTempColor(ct)
            drawLabelValue(ctx: ctx, label: "CORE TEMP", value: value, x: 50 * scale, y: leftY, labelColor: accentColor, valueColor: c)
        }

        // === RIGHT SIDE (top→bottom): GPS Track(SwiftUI) → Distance → TIME → ELEV GAIN → ALTITUDE → 標高グラフ ===

        // Distance - right, below GPS track area
        let rightX = videoSize.width - 450 * scale
        var rightY = videoSize.height - 420 * scale

        if settings.showDistance {
            let current = dataPoint.distance.map { String(format: "%.1f", $0 / 1000.0) } ?? "--"
            let total = String(format: "/ %.1f KM", totalDistance / 1000.0)
            drawText(ctx: ctx, text: "\(current) KM", x: rightX, y: rightY, fontSize: 90 * scale, color: white, bold: true)
            drawText(ctx: ctx, text: total, x: rightX, y: rightY - 40 * scale, fontSize: 32 * scale, color: white)
            rightY -= 150 * scale
        }

        // TIME - right, below distance
        if settings.showTime {
            let value = formatElapsedTime(elapsedTime)
            drawLabelValue(ctx: ctx, label: "TIME", value: value, x: rightX, y: rightY, labelColor: accentColor)
            rightY -= 130 * scale
        }

        // ELEV GAIN - right, below time
        if settings.showElevationGain {
            let gain = cumulativeElevationGain(upTo: dataPoint.distance)
            let value = String(format: "+%.0f m", gain)
            drawLabelValue(ctx: ctx, label: "ELEV GAIN", value: value, x: rightX, y: rightY, labelColor: accentColor, valueColor: CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1))
            rightY -= 130 * scale
        }

        // ALTITUDE (current elevation) - right, below elev gain
        if settings.showAltitude {
            let value = dataPoint.altitude.map { String(format: "%.0f M", $0) } ?? "-- M"
            drawLabelValue(ctx: ctx, label: "ALTITUDE", value: value, x: rightX, y: rightY, labelColor: accentColor)
        }

        // Elevation profile - right bottom
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

    // MARK: - HR Zone

    private func heartRateZone(_ hr: UInt8) -> Int {
        if hr <= settings.z1Max { return 1 }
        else if hr <= settings.z2Max { return 2 }
        else if hr <= settings.z3Max { return 3 }
        else if hr <= settings.z4Max { return 4 }
        else { return 5 }
    }

    private func hrZoneColorByZone(_ zone: Int) -> CGColor {
        switch zone {
        case 1: return CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)   // Gray
        case 2: return CGColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1)   // Green
        case 3: return CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1)   // Yellow
        case 4: return CGColor(red: 1.0, green: 0.45, blue: 0.1, alpha: 1)  // Orange
        default: return CGColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1) // Red
        }
    }

    // MARK: - Elevation Profile

    private func drawElevationProfile(ctx: CGContext, currentPoint: FITDataPoint) {
        guard !allDataPoints.isEmpty else { return }
        let altitudes = allDataPoints.compactMap { $0.altitude }
        guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(), maxAlt > minAlt else { return }

        // Position: right bottom
        let profileRect = CGRect(
            x: videoSize.width - elevationProfileWidth - 30 * scale,
            y: 30 * scale,
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

    private func drawLabelValue(ctx: CGContext, label: String, value: String, x: CGFloat, y: CGFloat, labelColor: CGColor, valueSize: CGFloat = 80, valueColor: CGColor? = nil) {
        // Label
        drawText(ctx: ctx, text: label, x: x, y: y, fontSize: 28 * scale, color: labelColor, bold: true)
        // Value
        drawText(ctx: ctx, text: value, x: x, y: y - 70 * scale, fontSize: valueSize * scale, color: valueColor ?? white, bold: true)
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
