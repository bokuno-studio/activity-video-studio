import Foundation
import CoreGraphics
import AppKit
import CoreLocation

/// Renders floating activity data overlay with circular HR gauge.
/// Layout: right side dominant, no bottom bar, drop shadows on text.
final class OverlayRenderer {

    let videoSize: CGSize
    var settings: OverlaySettings
    var allDataPoints: [FITDataPoint] = []
    var textOverlays: [TextOverlay] = []
    var trackCoordinates: [CLLocationCoordinate2D] = []
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
    private let metricsBackgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)

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
        let leftX = 50 * scale
        var leftY = videoSize.height - 50 * scale
        var leftMetricRects: [CGRect] = []

        if settings.showHeartRate {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: 80 * scale))
            leftY -= 130 * scale
        }

        if settings.showPace {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: 80 * scale))
            leftY -= 130 * scale
        }

        if settings.showCadence {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: 80 * scale))
            leftY -= 130 * scale
        }

        if settings.showCoreTemp, dataPoint.coreTemperature != nil {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: 80 * scale))
        }

        if let leftBackgroundRect = unionRect(for: leftMetricRects) {
            drawMetricsBackground(ctx: ctx, rect: leftBackgroundRect)
        }

        leftY = videoSize.height - 50 * scale

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
            drawLabelValue(ctx: ctx, label: "HEART RATE", value: hrValue, x: leftX, y: leftY, labelColor: accentColor, valueColor: hrColor)
            leftY -= 130 * scale
        }

        // PACE
        if settings.showPace {
            let value = dataPoint.paceFormatted ?? "--'--\""
            drawLabelValue(ctx: ctx, label: "PACE", value: value, x: leftX, y: leftY, labelColor: accentColor)
            leftY -= 130 * scale
        }

        // CADENCE
        if settings.showCadence {
            let value = dataPoint.runningCadence.map { "\($0) spm" } ?? "-- spm"
            drawLabelValue(ctx: ctx, label: "CADENCE", value: value, x: leftX, y: leftY, labelColor: accentColor)
            leftY -= 130 * scale
        }

        // CORE TEMP
        if settings.showCoreTemp, let ct = dataPoint.coreTemperature {
            let value = String(format: "%.1f°C", ct)
            let c = coreTempColor(ct)
            drawLabelValue(ctx: ctx, label: "CORE TEMP", value: value, x: leftX, y: leftY, labelColor: accentColor, valueColor: c)
        }

        // === RIGHT SIDE (top→bottom): GPS track (drawn directly by OverlayRenderer) → Distance → TIME → ELEV GAIN → ALTITUDE → 標高グラフ ===

        // Distance - right, below GPS track area.
        // GPS track drawn directly by OverlayRenderer (see drawGPSTrack) in the top-right corner.
        // Formula keeps the text clear of the map across 720p / 1080p / 4K.
        let rightX = videoSize.width - 450 * scale
        var rightY = videoSize.height * 0.65 - 130 * scale
        var rightMetricRects: [CGRect] = []

        if settings.showDistance {
            rightMetricRects.append(textRect(x: rightX, y: rightY, fontSize: 68 * scale))
            rightY -= 120 * scale
        }

        if settings.showTime {
            rightMetricRects.append(labelValueRect(x: rightX, y: rightY, valueSize: 80 * scale))
            rightY -= 130 * scale
        }

        if settings.showElevationGain {
            rightMetricRects.append(labelValueRect(x: rightX, y: rightY, valueSize: 80 * scale))
            rightY -= 130 * scale
        }

        if settings.showAltitude {
            rightMetricRects.append(labelValueRect(x: rightX, y: rightY, valueSize: 80 * scale))
        }

        if let rightBackgroundRect = unionRect(for: rightMetricRects) {
            drawMetricsBackground(ctx: ctx, rect: rightBackgroundRect)
        }

        rightY = videoSize.height * 0.65 - 130 * scale

        if settings.showDistance {
            let current = dataPoint.distance.map { String(format: "%.1f", $0 / 1000.0) } ?? "--"
            let total = String(format: "%.1f KM", totalDistance / 1000.0)
            // Show as "X.X / Y.Y KM" on a single line to avoid visual confusion
            let distText = "\(current) / \(total)"
            drawText(ctx: ctx, text: distText, x: rightX, y: rightY, fontSize: 68 * scale, color: white, bold: true)
            rightY -= 120 * scale
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

        // GPS track (top-right) — matches SwiftUI GPSTrackView layout in PreviewView
        drawGPSTrack(ctx: ctx, currentPoint: dataPoint)

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

        // Position: center bottom (avoids overlap with right metrics column)
        let profileRect = CGRect(
            x: (videoSize.width - elevationProfileWidth) / 2,
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

    // MARK: - GPS Track (top-right mini-map)

    private func drawGPSTrack(ctx: CGContext, currentPoint: FITDataPoint) {
        guard trackCoordinates.count >= 2 else { return }

        // Layout: match SwiftUI GPSTrackView (22% width, 28% height, top-right, 20pt margin).
        let margin = 20 * scale
        let mapWidth = videoSize.width * 0.22
        let mapHeight = videoSize.height * 0.28
        let mapRect = CGRect(
            x: videoSize.width - mapWidth - margin,
            y: videoSize.height - mapHeight - margin,
            width: mapWidth,
            height: mapHeight
        )

        // Background: semi-transparent black, 8pt corner radius
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        let bgPath = CGPath(
            roundedRect: mapRect,
            cornerWidth: 8 * scale,
            cornerHeight: 8 * scale,
            transform: nil
        )
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Compute bounding box over the entire track.
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        for c in trackCoordinates {
            if c.latitude < minLat { minLat = c.latitude }
            if c.latitude > maxLat { maxLat = c.latitude }
            if c.longitude < minLon { minLon = c.longitude }
            if c.longitude > maxLon { maxLon = c.longitude }
        }

        let latRange = maxLat - minLat
        let lonRange = maxLon - minLon
        // Degenerate bbox (all points collinear / identical); bail out gracefully.
        guard latRange > 0 || lonRange > 0 else { return }

        // Preserve aspect ratio inside the map area with an inset.
        let inset = 10 * scale
        let drawRect = mapRect.insetBy(dx: inset, dy: inset)

        // Guard against divide-by-zero when all points share a lat or lon.
        let safeLatRange = latRange > 0 ? latRange : 1e-9
        let safeLonRange = lonRange > 0 ? lonRange : 1e-9

        // Fit: compute scale that fits both axes, keeping aspect ratio.
        let sx = drawRect.width / CGFloat(safeLonRange)
        let sy = drawRect.height / CGFloat(safeLatRange)
        let fitScale = min(sx, sy)
        let usedWidth = CGFloat(safeLonRange) * fitScale
        let usedHeight = CGFloat(safeLatRange) * fitScale
        let originX = drawRect.midX - usedWidth / 2
        let originY = drawRect.midY - usedHeight / 2

        // Lon → X (east = +X). Lat → Y with north = top.
        // CGContext origin is bottom-left, so latitude maps directly (higher lat = higher Y).
        func project(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let x = originX + CGFloat(coord.longitude - minLon) * fitScale
            let y = originY + CGFloat(coord.latitude - minLat) * fitScale
            return CGPoint(x: x, y: y)
        }

        // Build polyline path once.
        let polyline = CGMutablePath()
        polyline.move(to: project(trackCoordinates[0]))
        for c in trackCoordinates.dropFirst() {
            polyline.addLine(to: project(c))
        }

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Clip to rounded map rect so the polyline never escapes the frame.
        ctx.addPath(bgPath)
        ctx.clip()

        // Outline (black, alpha 0.5, 5pt)
        ctx.addPath(polyline)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        ctx.setLineWidth(5 * scale)
        ctx.strokePath()

        // Foreground (cyan, 3pt)
        ctx.addPath(polyline)
        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.88, blue: 0.98, alpha: 1.0))
        ctx.setLineWidth(3 * scale)
        ctx.strokePath()

        // Current position dot (red with white stroke) — only when we have a coord.
        if let current = currentPoint.coordinate {
            let p = project(current)
            let dotDiameter = 12 * scale
            let dotRect = CGRect(
                x: p.x - dotDiameter / 2,
                y: p.y - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            ctx.setFillColor(CGColor(red: 1.0, green: 0.2, blue: 0.15, alpha: 1.0))
            ctx.fillEllipse(in: dotRect)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(2.5 * scale)
            ctx.strokeEllipse(in: dotRect)
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

    private func labelValueRect(x: CGFloat, y: CGFloat, valueSize: CGFloat) -> CGRect {
        // Width 700 comfortably fits long values like "150 bpm  Z3" at 80pt
        CGRect(
            x: x - 18 * scale,
            y: y - 88 * scale,
            width: 700 * scale,
            height: valueSize + 62 * scale
        )
    }

    private func textRect(x: CGFloat, y: CGFloat, fontSize: CGFloat) -> CGRect {
        // Width 600 comfortably fits "X.X / Y.Y KM" at 68pt
        CGRect(
            x: x - 18 * scale,
            y: y - 18 * scale,
            width: 600 * scale,
            height: fontSize + 30 * scale
        )
    }

    private func unionRect(for rects: [CGRect]) -> CGRect? {
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }
        return union.insetBy(dx: -14 * scale, dy: -12 * scale)
    }

    private func drawMetricsBackground(ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(metricsBackgroundColor)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 8 * scale,
            cornerHeight: 8 * scale,
            transform: nil
        )
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Text overlay

    private func drawTextOverlay(ctx: CGContext, overlay: TextOverlay, opacity: Double) {
        let fontSize = overlay.fontSize * scale
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let textColor = NSColor(cgColor: overlay.color)?.withAlphaComponent(opacity) ?? NSColor.white.withAlphaComponent(opacity)
        let padding = 30 * scale
        let lineSpacing = fontSize * 1.2

        // Split text into lines
        let lines = overlay.text.components(separatedBy: "\n")
        var lineData: [(CTLine, CGRect)] = []
        var maxWidth: CGFloat = 0

        for lineText in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let attrStr = NSAttributedString(string: lineText, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            lineData.append((ctLine, bounds))
            maxWidth = max(maxWidth, bounds.width)
        }

        let totalHeight = lineSpacing * CGFloat(lines.count)

        // Vertical position
        let baseY: CGFloat
        switch overlay.position {
        case .topCenter:
            baseY = videoSize.height - padding - totalHeight
        case .center:
            baseY = (videoSize.height + totalHeight) / 2 - lineSpacing
        case .bottomCenter:
            baseY = padding + 80 * scale + totalHeight - lineSpacing
        }

        // Background
        let bgRect = CGRect(
            x: (videoSize.width - maxWidth) / 2 - padding,
            y: baseY - totalHeight + lineSpacing - padding / 2,
            width: maxWidth + padding * 2,
            height: totalHeight + padding
        )
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.setFillColor(overlay.backgroundColor)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.fill(bgRect)
        ctx.restoreGState()

        // Draw each line centered
        for (i, (ctLine, bounds)) in lineData.enumerated() {
            let x = (videoSize.width - bounds.width) / 2
            let y = baseY - lineSpacing * CGFloat(i)
            ctx.saveGState()
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
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
