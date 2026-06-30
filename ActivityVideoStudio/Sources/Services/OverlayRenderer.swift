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
    private var renderStyle: OverlayPresetRenderStyle { settings.overlayPreset.renderStyle }
    private var accentColor: CGColor { renderStyle.accentColor }
    private var accentRed: CGColor { renderStyle.accentRed }
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private var shadowColor: CGColor { renderStyle.shadowColor }
    private var metricsBackgroundColor: CGColor { renderStyle.metricsBackgroundColor }


    init(videoSize: CGSize, settings: OverlaySettings = OverlaySettings()) {
        self.videoSize = videoSize
        self.settings = settings
    }

    func makeExportCopy() -> OverlayRenderer {
        let copy = OverlayRenderer(videoSize: videoSize, settings: settings.snapshot())
        copy.allDataPoints = allDataPoints
        copy.textOverlays = textOverlays
        copy.trackCoordinates = trackCoordinates
        copy.fitRecordingActive = fitRecordingActive
        copy.elevationGainCache = elevationGainCache
        return copy
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

        let style = renderStyle
        let labelFontSize = style.labelFontSize
        let valueFontSize = style.valueFontSize
        let distanceFontSize = style.distanceFontSize * scale
        let leftAdvance = style.leftMetricAdvance * scale
        let rightDistanceAdvance = style.rightDistanceAdvance * scale
        let rightAdvance = style.rightMetricAdvance * scale

        // === LEFT SIDE (top→bottom): HR → PACE → CADENCE → CORE ===
        let leftX = style.leftX(in: videoSize, scale: scale)
        var leftY = style.leftStartY(in: videoSize, scale: scale)
        var leftMetricRects: [CGRect] = []

        if settings.showHeartRate {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: valueFontSize * scale))
            leftY += leftAdvance
        }

        if settings.showPace {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: valueFontSize * scale))
            leftY += leftAdvance
        }

        if settings.showCadence {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: valueFontSize * scale))
            leftY += leftAdvance
        }

        if settings.showCoreTemp, dataPoint.coreTemperature != nil {
            leftMetricRects.append(labelValueRect(x: leftX, y: leftY, valueSize: valueFontSize * scale))
        }

        if let leftBackgroundRect = unionRect(for: leftMetricRects) {
            drawMetricsBackground(ctx: ctx, rect: leftBackgroundRect)
        }

        leftY = style.leftStartY(in: videoSize, scale: scale)

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
            drawLabelValue(ctx: ctx, label: "HEART RATE", value: hrValue, x: leftX, y: leftY, labelColor: accentColor, valueSize: valueFontSize, valueColor: hrColor, labelSize: labelFontSize)
            leftY += leftAdvance
        }

        // PACE
        if settings.showPace {
            let value = dataPoint.paceFormatted ?? "--'--\""
            drawLabelValue(ctx: ctx, label: "PACE", value: value, x: leftX, y: leftY, labelColor: accentColor, valueSize: valueFontSize, labelSize: labelFontSize)
            leftY += leftAdvance
        }

        // CADENCE
        if settings.showCadence {
            let value = dataPoint.runningCadence.map { "\($0) spm" } ?? "-- spm"
            drawLabelValue(ctx: ctx, label: "CADENCE", value: value, x: leftX, y: leftY, labelColor: accentColor, valueSize: valueFontSize, labelSize: labelFontSize)
            leftY += leftAdvance
        }

        // CORE TEMP
        if settings.showCoreTemp, let ct = dataPoint.coreTemperature {
            let value = String(format: "%.1f°C", ct)
            let c = coreTempColor(ct)
            drawLabelValue(ctx: ctx, label: "CORE TEMP", value: value, x: leftX, y: leftY, labelColor: accentColor, valueSize: valueFontSize, valueColor: c, labelSize: labelFontSize)
        }

        // === RIGHT SIDE (top→bottom): GPS track (drawn directly by OverlayRenderer) → Distance → TIME → ELEV GAIN → ALTITUDE → 標高グラフ ===

        // Distance - right, below GPS track area.
        // GPS track drawn directly by OverlayRenderer (see drawGPSTrack) in the top-right corner.
        // Formula keeps the text clear of the map across 720p / 1080p / 4K.
        let rightX = style.rightX(in: videoSize, scale: scale)
        var rightY = style.rightStartY(in: videoSize, scale: scale)
        var rightMetricRects: [CGRect] = []

        if settings.showDistance {
            rightMetricRects.append(textRect(x: rightX, y: rightY, fontSize: distanceFontSize))
            rightY += rightDistanceAdvance
        }

        if settings.showTime {
            rightMetricRects.append(labelValueRect(x: rightX, y: rightY, valueSize: valueFontSize * scale))
            rightY += rightAdvance
        }

        if settings.showElevationGain {
            rightMetricRects.append(labelValueRect(x: rightX, y: rightY, valueSize: valueFontSize * scale))
            rightY += rightAdvance
        }

        if settings.showAltitude {
            rightMetricRects.append(labelValueRect(x: rightX, y: rightY, valueSize: valueFontSize * scale))
        }

        let rightBackgroundRect = unionRect(for: rightMetricRects)
        if let rightBackgroundRect {
            drawMetricsBackground(ctx: ctx, rect: rightBackgroundRect)
        }

        rightY = style.rightStartY(in: videoSize, scale: scale)

        if settings.showDistance {
            let current = dataPoint.distance.map { String(format: "%.1f", $0 / 1000.0) } ?? "--"
            let total = String(format: "%.1f KM", totalDistance / 1000.0)
            // Show as "X.X / Y.Y KM" on a single line to avoid visual confusion
            let distText = "\(current) / \(total)"
            drawText(ctx: ctx, text: distText, x: rightX, y: rightY, fontSize: distanceFontSize, color: white, bold: true)
            rightY += rightDistanceAdvance
        }

        // TIME - right, below distance
        if settings.showTime {
            let value = formatElapsedTime(elapsedTime)
            drawLabelValue(ctx: ctx, label: "TIME", value: value, x: rightX, y: rightY, labelColor: accentColor, valueSize: valueFontSize, labelSize: labelFontSize)
            rightY += rightAdvance
        }

        // ELEV GAIN - right, below time
        if settings.showElevationGain {
            let gain = cumulativeElevationGain(upTo: dataPoint.distance)
            let value = String(format: "+%.0f m", gain)
            drawLabelValue(ctx: ctx, label: "ELEV GAIN", value: value, x: rightX, y: rightY, labelColor: accentColor, valueSize: valueFontSize, valueColor: style.elevationColor, labelSize: labelFontSize)
            rightY += rightAdvance
        }

        // ALTITUDE (current elevation) - right, below elev gain
        if settings.showAltitude {
            let value = dataPoint.altitude.map { String(format: "%.0f M", $0) } ?? "-- M"
            drawLabelValue(ctx: ctx, label: "ALTITUDE", value: value, x: rightX, y: rightY, labelColor: accentColor, valueSize: valueFontSize, labelSize: labelFontSize)
        }

        // Elevation profile - directly under the top-right mini-map
        if settings.showElevationProfile {
            drawElevationProfile(ctx: ctx, currentPoint: dataPoint, metricsTopY: rightBackgroundRect?.maxY)
        }

        // GPS track (top-right mini-map)
        if settings.showMiniMap {
            drawGPSTrack(ctx: ctx, currentPoint: dataPoint)
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

    /// Draws the elevation profile directly under the top-right mini-map, sharing
    /// its width and right edge. The height is fit into the gap between the map's
    /// bottom and the top of the right metrics block (`metricsTopY`), so the graph
    /// never overlaps the map above it or the metrics below it.
    private func drawElevationProfile(ctx: CGContext, currentPoint: FITDataPoint, metricsTopY: CGFloat?) {
        guard !allDataPoints.isEmpty else { return }
        let altitudes = allDataPoints.compactMap { $0.altitude }
        guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(), maxAlt > minAlt else { return }

        let style = renderStyle
        let mapRect = self.mapRect()
        let mapBottom = mapRect.minY

        let topY = mapBottom - style.profileGap * scale         // just below the map
        // Clear the right metrics block. Its top edge is the union rect's maxY;
        // fall back to a safe default if no metrics are shown.
        let clearanceBaseY: CGFloat
        if style.mapPlacement == .topLeft {
            clearanceBaseY = videoSize.height * 0.48
        } else {
            clearanceBaseY = metricsTopY ?? videoSize.height * 0.45
        }
        let bottomY = clearanceBaseY + style.profileBottomPadding * scale
        let availableHeight = topY - bottomY
        // Too little room (very short overlay) → skip rather than overlap.
        guard availableHeight >= 36 * scale else { return }

        let profileRect = CGRect(
            x: mapRect.minX,
            y: bottomY,
            width: mapRect.width,
            height: availableHeight
        )

        // Semi-transparent background
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(style.panelBackgroundColor)
        let bgPath = CGPath(roundedRect: profileRect, cornerWidth: style.profileCornerRadius * scale, cornerHeight: style.profileCornerRadius * scale, transform: nil)
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
        ctx.setFillColor(style.elevationFillColor)
        ctx.fillPath()

        // Stroke the line
        ctx.setStrokeColor(style.elevationLineColor)
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

        let style = renderStyle
        let mapRect = self.mapRect()

        // Background: semi-transparent black, 8pt corner radius
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(style.mapBackgroundColor)
        let bgPath = CGPath(
            roundedRect: mapRect,
            cornerWidth: style.mapCornerRadius * scale,
            cornerHeight: style.mapCornerRadius * scale,
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
        ctx.setStrokeColor(style.trackOutlineColor)
        ctx.setLineWidth(5 * scale)
        ctx.strokePath()

        // Foreground (cyan, 3pt)
        ctx.addPath(polyline)
        ctx.setStrokeColor(style.trackLineColor)
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
            ctx.setFillColor(style.mapDotColor)
            ctx.fillEllipse(in: dotRect)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(2.5 * scale)
            ctx.strokeEllipse(in: dotRect)
        }

        ctx.restoreGState()
    }

    private func mapRect() -> CGRect {
        let style = renderStyle
        let margin = style.mapMargin * scale
        let mapWidth = videoSize.width * style.mapWidthRatio
        let mapHeight = videoSize.height * style.mapHeightRatio

        let x: CGFloat
        switch style.mapPlacement {
        case .topLeft:
            x = margin
        case .topRight:
            x = videoSize.width - mapWidth - margin
        }

        return CGRect(
            x: x,
            y: videoSize.height - mapHeight - margin,
            width: mapWidth,
            height: mapHeight
        )
    }

    // MARK: - Text helpers

    private func drawLabelValue(
        ctx: CGContext,
        label: String,
        value: String,
        x: CGFloat,
        y: CGFloat,
        labelColor: CGColor,
        valueSize: CGFloat = 80,
        valueColor: CGColor? = nil,
        labelSize: CGFloat = 28
    ) {
        // Label
        drawText(ctx: ctx, text: label, x: x, y: y, fontSize: labelSize * scale, color: labelColor, bold: true)
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
            width: 700 * scale * renderStyle.metricPanelWidthScale,
            height: valueSize + 62 * scale
        )
    }

    private func textRect(x: CGFloat, y: CGFloat, fontSize: CGFloat) -> CGRect {
        // Width 600 comfortably fits "X.X / Y.Y KM" at 68pt
        CGRect(
            x: x - 18 * scale,
            y: y - 18 * scale,
            width: 600 * scale * renderStyle.distancePanelWidthScale,
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
            cornerWidth: renderStyle.metricsCornerRadius * scale,
            cornerHeight: renderStyle.metricsCornerRadius * scale,
            transform: nil
        )
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Text overlay

    private func drawTextOverlay(ctx: CGContext, overlay: TextOverlay, opacity: Double) {
        let fontSize = max(1, overlay.fontSize * scale)
        let font = textOverlayFont(for: overlay, size: fontSize)
        let textColor = nsColor(overlay.color, applyingOpacity: opacity, fallback: .white)
        let strokeColor = nsColor(overlay.strokeColor, applyingOpacity: opacity, fallback: .black)
        let shadowColor = cgColor(overlay.shadowColor, applyingOpacity: opacity, fallback: .black)
        let padding = 30 * scale
        let strokeWidth = max(0, overlay.strokeWidth) * scale
        let lineHeight = max(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), fontSize * 1.2)

        // Split text into lines
        let lines = overlay.text.components(separatedBy: "\n")
        var lineData: [(CTLine, CGFloat, CGRect)] = []
        var maxWidth: CGFloat = 0

        for lineText in lines {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            if strokeWidth > 0 {
                attrs[.strokeColor] = strokeColor
                attrs[.strokeWidth] = -(strokeWidth / fontSize * 100)
            }
            let attrStr = NSAttributedString(string: lineText, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            lineData.append((ctLine, width, bounds))
            maxWidth = max(maxWidth, width)
        }

        let totalHeight = lineHeight * CGFloat(lines.count)
        let centerX = min(max(overlay.relativeX, 0), 1) * videoSize.width
        let centerY = videoSize.height - min(max(overlay.relativeY, 0), 1) * videoSize.height

        // Background
        let textRect = CGRect(
            x: centerX - maxWidth / 2,
            y: centerY - totalHeight / 2,
            width: maxWidth,
            height: totalHeight
        )
        let bgRect = CGRect(
            x: textRect.minX - padding - strokeWidth,
            y: textRect.minY - padding / 2 - strokeWidth,
            width: maxWidth + padding * 2 + strokeWidth * 2,
            height: totalHeight + padding + strokeWidth * 2
        ).integral
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.setFillColor(overlay.backgroundColor)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.fill(bgRect)
        ctx.restoreGState()

        // Draw each line centered around the relative placement anchor.
        let firstBaseline = centerY + totalHeight / 2 - CTFontGetAscent(font)
        for (i, (ctLine, width, bounds)) in lineData.enumerated() {
            let x = centerX - width / 2 - bounds.origin.x
            let y = firstBaseline - lineHeight * CGFloat(i)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: overlay.shadowOffsetX * scale, height: -overlay.shadowOffsetY * scale),
                blur: max(0, overlay.shadowBlur) * scale,
                color: shadowColor
            )
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }

    private func textOverlayFont(for overlay: TextOverlay, size: CGFloat) -> CTFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.nsFontWeight)
        let nsFont = NSFontManager.shared.font(
            withFamily: overlay.fontFamily,
            traits: [],
            weight: overlay.fontWeight.nsFontManagerWeight,
            size: size
        ) ?? fallback

        return CTFontCreateWithName(nsFont.fontName as CFString, size, nil)
    }

    private func nsColor(_ color: CGColor, applyingOpacity opacity: Double, fallback: NSColor) -> NSColor {
        let base = NSColor(cgColor: color) ?? fallback
        return base.withAlphaComponent(base.alphaComponent * CGFloat(opacity))
    }

    private func cgColor(_ color: CGColor, applyingOpacity opacity: Double, fallback: NSColor) -> CGColor {
        nsColor(color, applyingOpacity: opacity, fallback: fallback).cgColor
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

enum OverlayMapPlacement {
    case topLeft
    case topRight
}

enum OverlayHorizontalPosition {
    case left(CGFloat)
    case right(CGFloat)
    case proportion(CGFloat, offset: CGFloat)

    func x(in width: CGFloat, scale: CGFloat) -> CGFloat {
        switch self {
        case .left(let offset):
            return offset * scale
        case .right(let inset):
            return width - inset * scale
        case .proportion(let fraction, let offset):
            return width * fraction + offset * scale
        }
    }
}

enum OverlayVerticalPosition {
    case top(CGFloat)
    case bottom(CGFloat)
    case proportion(CGFloat, offset: CGFloat)

    func y(in height: CGFloat, scale: CGFloat) -> CGFloat {
        switch self {
        case .top(let inset):
            return height - inset * scale
        case .bottom(let offset):
            return offset * scale
        case .proportion(let fraction, let offset):
            return height * fraction + offset * scale
        }
    }
}

struct OverlayPresetRenderStyle {
    var accentColor: CGColor
    var accentRed: CGColor
    var shadowColor: CGColor
    var metricsBackgroundColor: CGColor
    var panelBackgroundColor: CGColor
    var mapBackgroundColor: CGColor
    var elevationColor: CGColor
    var elevationLineColor: CGColor
    var elevationFillColor: CGColor
    var trackOutlineColor: CGColor
    var trackLineColor: CGColor
    var mapDotColor: CGColor
    var labelFontSize: CGFloat
    var valueFontSize: CGFloat
    var distanceFontSize: CGFloat
    var leftXPosition: OverlayHorizontalPosition
    var leftStartYPosition: OverlayVerticalPosition
    var rightXPosition: OverlayHorizontalPosition
    var rightStartYPosition: OverlayVerticalPosition
    var leftMetricAdvance: CGFloat
    var rightDistanceAdvance: CGFloat
    var rightMetricAdvance: CGFloat
    var metricPanelWidthScale: CGFloat
    var distancePanelWidthScale: CGFloat
    var metricsCornerRadius: CGFloat
    var mapWidthRatio: CGFloat
    var mapHeightRatio: CGFloat
    var mapMargin: CGFloat
    var mapCornerRadius: CGFloat
    var mapPlacement: OverlayMapPlacement
    var profileGap: CGFloat
    var profileBottomPadding: CGFloat
    var profileCornerRadius: CGFloat

    func leftX(in videoSize: CGSize, scale: CGFloat) -> CGFloat {
        leftXPosition.x(in: videoSize.width, scale: scale)
    }

    func leftStartY(in videoSize: CGSize, scale: CGFloat) -> CGFloat {
        leftStartYPosition.y(in: videoSize.height, scale: scale)
    }

    func rightX(in videoSize: CGSize, scale: CGFloat) -> CGFloat {
        rightXPosition.x(in: videoSize.width, scale: scale)
    }

    func rightStartY(in videoSize: CGSize, scale: CGFloat) -> CGFloat {
        rightStartYPosition.y(in: videoSize.height, scale: scale)
    }
}

extension OverlayPreset {
    var renderStyle: OverlayPresetRenderStyle {
        switch self {
        case .defaultPreset:
            return OverlayPresetRenderStyle(
                accentColor: overlayColor(1.0, 0.45, 0.1, 1),
                accentRed: overlayColor(1.0, 0.2, 0.15, 1),
                shadowColor: overlayColor(0, 0, 0, 0.7),
                metricsBackgroundColor: overlayColor(0, 0, 0, 0.45),
                panelBackgroundColor: overlayColor(0, 0, 0, 0.35),
                mapBackgroundColor: overlayColor(0, 0, 0, 0.45),
                elevationColor: overlayColor(0.3, 0.8, 0.3, 1),
                elevationLineColor: overlayColor(0.3, 0.8, 0.3, 0.9),
                elevationFillColor: overlayColor(0.3, 0.8, 0.3, 0.2),
                trackOutlineColor: overlayColor(0, 0, 0, 0.5),
                trackLineColor: overlayColor(0.0, 0.88, 0.98, 1.0),
                mapDotColor: overlayColor(1.0, 0.2, 0.15, 1.0),
                labelFontSize: 28,
                valueFontSize: 80,
                distanceFontSize: 68,
                leftXPosition: .left(50),
                leftStartYPosition: .top(50),
                rightXPosition: .right(450),
                rightStartYPosition: .proportion(0.65, offset: -130),
                leftMetricAdvance: -130,
                rightDistanceAdvance: -120,
                rightMetricAdvance: -130,
                metricPanelWidthScale: 1,
                distancePanelWidthScale: 1,
                metricsCornerRadius: 8,
                mapWidthRatio: 0.22,
                mapHeightRatio: 0.28,
                mapMargin: 20,
                mapCornerRadius: 8,
                mapPlacement: .topRight,
                profileGap: 12,
                profileBottomPadding: 14,
                profileCornerRadius: 6
            )

        case .compact:
            return OverlayPresetRenderStyle(
                accentColor: overlayColor(0.0, 0.78, 1.0, 1),
                accentRed: overlayColor(1.0, 0.25, 0.18, 1),
                shadowColor: overlayColor(0, 0, 0, 0.75),
                metricsBackgroundColor: overlayColor(0.02, 0.04, 0.05, 0.38),
                panelBackgroundColor: overlayColor(0.02, 0.04, 0.05, 0.32),
                mapBackgroundColor: overlayColor(0.02, 0.04, 0.05, 0.4),
                elevationColor: overlayColor(0.58, 0.95, 0.36, 1),
                elevationLineColor: overlayColor(0.58, 0.95, 0.36, 0.9),
                elevationFillColor: overlayColor(0.58, 0.95, 0.36, 0.18),
                trackOutlineColor: overlayColor(0, 0, 0, 0.55),
                trackLineColor: overlayColor(0.0, 0.95, 1.0, 1),
                mapDotColor: overlayColor(1.0, 0.24, 0.18, 1),
                labelFontSize: 22,
                valueFontSize: 58,
                distanceFontSize: 50,
                leftXPosition: .left(36),
                leftStartYPosition: .top(38),
                rightXPosition: .right(360),
                rightStartYPosition: .proportion(0.62, offset: -92),
                leftMetricAdvance: -96,
                rightDistanceAdvance: -86,
                rightMetricAdvance: -96,
                metricPanelWidthScale: 0.82,
                distancePanelWidthScale: 0.84,
                metricsCornerRadius: 6,
                mapWidthRatio: 0.18,
                mapHeightRatio: 0.22,
                mapMargin: 18,
                mapCornerRadius: 6,
                mapPlacement: .topRight,
                profileGap: 10,
                profileBottomPadding: 12,
                profileCornerRadius: 5
            )

        case .highContrast:
            return OverlayPresetRenderStyle(
                accentColor: overlayColor(1.0, 0.84, 0.0, 1),
                accentRed: overlayColor(1.0, 0.12, 0.1, 1),
                shadowColor: overlayColor(0, 0, 0, 0.9),
                metricsBackgroundColor: overlayColor(0, 0, 0, 0.72),
                panelBackgroundColor: overlayColor(0, 0, 0, 0.62),
                mapBackgroundColor: overlayColor(0, 0, 0, 0.68),
                elevationColor: overlayColor(0.62, 1.0, 0.32, 1),
                elevationLineColor: overlayColor(0.62, 1.0, 0.32, 1),
                elevationFillColor: overlayColor(0.62, 1.0, 0.32, 0.24),
                trackOutlineColor: overlayColor(0, 0, 0, 0.9),
                trackLineColor: overlayColor(1, 1, 1, 1),
                mapDotColor: overlayColor(1.0, 0.12, 0.1, 1),
                labelFontSize: 30,
                valueFontSize: 84,
                distanceFontSize: 70,
                leftXPosition: .left(50),
                leftStartYPosition: .top(52),
                rightXPosition: .right(470),
                rightStartYPosition: .proportion(0.65, offset: -132),
                leftMetricAdvance: -134,
                rightDistanceAdvance: -124,
                rightMetricAdvance: -134,
                metricPanelWidthScale: 1.04,
                distancePanelWidthScale: 1.04,
                metricsCornerRadius: 4,
                mapWidthRatio: 0.22,
                mapHeightRatio: 0.28,
                mapMargin: 20,
                mapCornerRadius: 4,
                mapPlacement: .topRight,
                profileGap: 12,
                profileBottomPadding: 14,
                profileCornerRadius: 4
            )

        case .lowerThird:
            return OverlayPresetRenderStyle(
                accentColor: overlayColor(0.0, 0.9, 0.85, 1),
                accentRed: overlayColor(1.0, 0.22, 0.16, 1),
                shadowColor: overlayColor(0, 0, 0, 0.78),
                metricsBackgroundColor: overlayColor(0.01, 0.02, 0.02, 0.52),
                panelBackgroundColor: overlayColor(0.01, 0.02, 0.02, 0.42),
                mapBackgroundColor: overlayColor(0.01, 0.02, 0.02, 0.46),
                elevationColor: overlayColor(0.92, 0.95, 0.34, 1),
                elevationLineColor: overlayColor(0.92, 0.95, 0.34, 0.9),
                elevationFillColor: overlayColor(0.92, 0.95, 0.34, 0.2),
                trackOutlineColor: overlayColor(0, 0, 0, 0.6),
                trackLineColor: overlayColor(0.0, 0.92, 0.86, 1),
                mapDotColor: overlayColor(1.0, 0.22, 0.16, 1),
                labelFontSize: 22,
                valueFontSize: 58,
                distanceFontSize: 48,
                leftXPosition: .left(50),
                leftStartYPosition: .bottom(232),
                rightXPosition: .right(670),
                rightStartYPosition: .bottom(232),
                leftMetricAdvance: 96,
                rightDistanceAdvance: 94,
                rightMetricAdvance: 96,
                metricPanelWidthScale: 0.82,
                distancePanelWidthScale: 0.9,
                metricsCornerRadius: 8,
                mapWidthRatio: 0.20,
                mapHeightRatio: 0.25,
                mapMargin: 20,
                mapCornerRadius: 8,
                mapPlacement: .topRight,
                profileGap: 12,
                profileBottomPadding: 14,
                profileCornerRadius: 6
            )

        case .mapLeft:
            return OverlayPresetRenderStyle(
                accentColor: overlayColor(1.0, 0.52, 0.12, 1),
                accentRed: overlayColor(1.0, 0.2, 0.15, 1),
                shadowColor: overlayColor(0, 0, 0, 0.76),
                metricsBackgroundColor: overlayColor(0, 0, 0, 0.48),
                panelBackgroundColor: overlayColor(0, 0, 0, 0.38),
                mapBackgroundColor: overlayColor(0, 0, 0, 0.48),
                elevationColor: overlayColor(0.35, 0.86, 0.38, 1),
                elevationLineColor: overlayColor(0.35, 0.86, 0.38, 0.92),
                elevationFillColor: overlayColor(0.35, 0.86, 0.38, 0.2),
                trackOutlineColor: overlayColor(0, 0, 0, 0.56),
                trackLineColor: overlayColor(0.0, 0.84, 1.0, 1),
                mapDotColor: overlayColor(1.0, 0.2, 0.15, 1),
                labelFontSize: 24,
                valueFontSize: 64,
                distanceFontSize: 54,
                leftXPosition: .left(50),
                leftStartYPosition: .proportion(0.43, offset: 0),
                rightXPosition: .right(450),
                rightStartYPosition: .proportion(0.58, offset: 0),
                leftMetricAdvance: -108,
                rightDistanceAdvance: -98,
                rightMetricAdvance: -108,
                metricPanelWidthScale: 0.9,
                distancePanelWidthScale: 0.9,
                metricsCornerRadius: 8,
                mapWidthRatio: 0.22,
                mapHeightRatio: 0.28,
                mapMargin: 20,
                mapCornerRadius: 8,
                mapPlacement: .topLeft,
                profileGap: 12,
                profileBottomPadding: 14,
                profileCornerRadius: 6
            )
        }
    }
}

func overlayColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private extension TextOverlay.FontWeight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var nsFontManagerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }
}
