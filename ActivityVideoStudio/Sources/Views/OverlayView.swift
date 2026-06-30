import SwiftUI
import AppKit
import CoreLocation
import CoreText

/// Preview-only overlay compositor. Export intentionally remains on
/// `OverlayRenderer`, while this view keeps edits live in the preview.
struct LivePreviewOverlayView: View {
    let frame: LivePreviewOverlayFrame?
    @ObservedObject var settings: OverlaySettings
    let allDataPoints: [FITDataPoint]
    let trackCoordinates: [CLLocationCoordinate2D]
    let textOverlays: [TextOverlay]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = liveScale(for: size)
            let playbackTime = frame?.globalPlaybackTime ?? 0

            ZStack(alignment: .topLeading) {
                if let frame {
                    LiveActivityDataLayer(
                        frame: frame,
                        settings: settings,
                        allDataPoints: allDataPoints,
                        trackCoordinates: trackCoordinates,
                        size: size,
                        scale: scale
                    )
                }

                LiveTextOverlayLayer(
                    overlays: textOverlays,
                    playbackTime: playbackTime,
                    size: size,
                    scale: scale
                )
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

private struct LiveActivityDataLayer: View {
    let frame: LivePreviewOverlayFrame
    @ObservedObject var settings: OverlaySettings
    let allDataPoints: [FITDataPoint]
    let trackCoordinates: [CLLocationCoordinate2D]
    let size: CGSize
    let scale: CGFloat

    private var style: OverlayPresetRenderStyle {
        settings.selectedRenderStyle
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !frame.fitRecordingActive {
                hudText(
                    "FIT 記録開始待ち",
                    size: 16 * scale,
                    color: Color(nsColor: .secondaryLabelColor),
                    weight: .regular
                )
                .opacity(0.8)
                .offset(x: 30 * scale, y: 24 * scale)
            }

            if let rect = unionRect(for: leftMetricRects) {
                roundedPanel(rect: rect, radius: style.metricsCornerRadius * scale, color: style.metricsBackgroundColor)
            }

            if let rect = unionRect(for: rightMetricRects) {
                roundedPanel(rect: rect, radius: style.metricsCornerRadius * scale, color: style.metricsBackgroundColor)
            }

            leftMetrics
            rightMetrics

            if settings.showElevationProfile, let rect = elevationProfileRect(metricsTopY: unionRect(for: rightMetricRects)?.maxY) {
                let displayRect = displayRect(fromRendererRect: rect, in: size)
                LiveElevationProfileView(
                    dataPoints: allDataPoints,
                    currentPoint: frame.dataPoint,
                    totalDistance: frame.totalDistance,
                    style: style,
                    scale: scale
                )
                .frame(width: displayRect.width, height: displayRect.height)
                .offset(x: displayRect.minX, y: displayRect.minY)
            }

            if settings.showMiniMap {
                let displayRect = displayRect(fromRendererRect: mapRect(), in: size)
                LiveGPSTrackMapView(
                    trackCoordinates: trackCoordinates,
                    currentCoordinate: frame.dataPoint.coordinate,
                    style: style,
                    scale: scale
                )
                .frame(width: displayRect.width, height: displayRect.height)
                .offset(x: displayRect.minX, y: displayRect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var leftMetrics: some View {
        let leftX = style.leftX(in: size, scale: scale)
        let y = style.leftStartY(in: size, scale: scale)

        return ZStack(alignment: .topLeading) {
            if settings.showHeartRate {
                let zone = frame.dataPoint.heartRate.map(heartRateZone)
                let value = frame.dataPoint.heartRate.map { "\($0) bpm  Z\(zone ?? 1)" } ?? "-- bpm"
                labelValue(label: "HEART RATE", value: value, x: leftX, y: y, valueColor: zone.map(hrZoneColor) ?? .white)
            }

            if settings.showPace {
                let metricY = y + (settings.showHeartRate ? style.leftMetricAdvance * scale : 0)
                labelValue(label: "PACE", value: frame.dataPoint.paceFormatted ?? "--'--\"", x: leftX, y: metricY)
            }

            if settings.showCadence {
                let preceding = [settings.showHeartRate, settings.showPace].filter { $0 }.count
                let metricY = y + CGFloat(preceding) * style.leftMetricAdvance * scale
                let value = frame.dataPoint.runningCadence.map { "\($0) spm" } ?? "-- spm"
                labelValue(label: "CADENCE", value: value, x: leftX, y: metricY)
            }

            if settings.showCoreTemp, let coreTemp = frame.dataPoint.coreTemperature {
                let preceding = [settings.showHeartRate, settings.showPace, settings.showCadence].filter { $0 }.count
                let metricY = y + CGFloat(preceding) * style.leftMetricAdvance * scale
                labelValue(
                    label: "CORE TEMP",
                    value: String(format: "%.1f°C", coreTemp),
                    x: leftX,
                    y: metricY,
                    valueColor: coreTempColor(coreTemp)
                )
            }
        }
    }

    private var rightMetrics: some View {
        let rightX = style.rightX(in: size, scale: scale)
        let y = style.rightStartY(in: size, scale: scale)

        return ZStack(alignment: .topLeading) {
            if settings.showDistance {
                let current = frame.dataPoint.distance.map { String(format: "%.1f", $0 / 1000.0) } ?? "--"
                let total = String(format: "%.1f KM", frame.totalDistance / 1000.0)
                hudText("\(current) / \(total)", size: style.distanceFontSize * scale, color: .white)
                    .offset(x: rightX, y: topForBaseline(y, fontSize: style.distanceFontSize * scale))
            }

            if settings.showTime {
                labelValue(label: "TIME", value: formatElapsedTime(frame.elapsedTime), x: rightX, y: rightTimeY())
            }

            if settings.showElevationGain {
                labelValue(
                    label: "ELEV GAIN",
                    value: String(format: "+%.0f m", frame.currentElevationGain),
                    x: rightX,
                    y: rightElevationGainY(),
                    valueColor: color(style.elevationColor)
                )
            }

            if settings.showAltitude {
                let value = frame.dataPoint.altitude.map { String(format: "%.0f M", $0) } ?? "-- M"
                labelValue(label: "ALTITUDE", value: value, x: rightX, y: rightAltitudeY())
            }
        }
    }

    private var leftMetricRects: [CGRect] {
        let x = style.leftX(in: size, scale: scale)
        var y = style.leftStartY(in: size, scale: scale)
        var rects: [CGRect] = []

        if settings.showHeartRate {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
            y += style.leftMetricAdvance * scale
        }
        if settings.showPace {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
            y += style.leftMetricAdvance * scale
        }
        if settings.showCadence {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
            y += style.leftMetricAdvance * scale
        }
        if settings.showCoreTemp, frame.dataPoint.coreTemperature != nil {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
        }

        return rects
    }

    private var rightMetricRects: [CGRect] {
        let x = style.rightX(in: size, scale: scale)
        var y = style.rightStartY(in: size, scale: scale)
        var rects: [CGRect] = []

        if settings.showDistance {
            rects.append(textRect(x: x, y: y, fontSize: style.distanceFontSize * scale))
            y += style.rightDistanceAdvance * scale
        }
        if settings.showTime {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
            y += style.rightMetricAdvance * scale
        }
        if settings.showElevationGain {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
            y += style.rightMetricAdvance * scale
        }
        if settings.showAltitude {
            rects.append(labelValueRect(x: x, y: y, valueSize: style.valueFontSize * scale))
        }

        return rects
    }

    private func labelValue(
        label: String,
        value: String,
        x: CGFloat,
        y: CGFloat,
        labelColor: Color? = nil,
        valueColor: Color = .white
    ) -> some View {
        ZStack(alignment: .topLeading) {
            hudText(label, size: style.labelFontSize * scale, color: labelColor ?? color(style.accentColor))
                .offset(x: x, y: topForBaseline(y, fontSize: style.labelFontSize * scale))
            hudText(value, size: style.valueFontSize * scale, color: valueColor)
                .offset(x: x, y: topForBaseline(y - 70 * scale, fontSize: style.valueFontSize * scale))
        }
    }

    private func rightTimeY() -> CGFloat {
        style.rightStartY(in: size, scale: scale)
            + (settings.showDistance ? style.rightDistanceAdvance * scale : 0)
    }

    private func rightElevationGainY() -> CGFloat {
        var y = style.rightStartY(in: size, scale: scale)
        if settings.showDistance { y += style.rightDistanceAdvance * scale }
        if settings.showTime { y += style.rightMetricAdvance * scale }
        return y
    }

    private func rightAltitudeY() -> CGFloat {
        var y = style.rightStartY(in: size, scale: scale)
        if settings.showDistance { y += style.rightDistanceAdvance * scale }
        if settings.showTime { y += style.rightMetricAdvance * scale }
        if settings.showElevationGain { y += style.rightMetricAdvance * scale }
        return y
    }

    private func hudText(_ text: String, size fontSize: CGFloat, color foregroundColor: Color, weight: Font.Weight = .bold) -> some View {
        Text(text)
            .font(.custom("Helvetica", size: max(1, fontSize)).weight(weight))
            .foregroundStyle(foregroundColor)
            .fixedSize()
            .shadow(color: color(self.style.shadowColor), radius: 3 * scale, x: 1.5 * scale, y: 1.5 * scale)
    }

    private func roundedPanel(rect: CGRect, radius: CGFloat, color cgColor: CGColor) -> some View {
        let displayRect = displayRect(fromRendererRect: rect, in: size)
        return RoundedRectangle(cornerRadius: radius)
            .fill(color(cgColor))
            .frame(width: displayRect.width, height: displayRect.height)
            .offset(x: displayRect.minX, y: displayRect.minY)
    }

    private func labelValueRect(x: CGFloat, y: CGFloat, valueSize: CGFloat) -> CGRect {
        CGRect(
            x: x - 18 * scale,
            y: y - 88 * scale,
            width: 700 * scale * style.metricPanelWidthScale,
            height: valueSize + 62 * scale
        )
    }

    private func textRect(x: CGFloat, y: CGFloat, fontSize: CGFloat) -> CGRect {
        CGRect(
            x: x - 18 * scale,
            y: y - 18 * scale,
            width: 600 * scale * style.distancePanelWidthScale,
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

    private func mapRect() -> CGRect {
        let margin = style.mapMargin * scale
        let mapWidth = size.width * style.mapWidthRatio
        let mapHeight = size.height * style.mapHeightRatio

        let x: CGFloat
        switch style.mapPlacement {
        case .topLeft:
            x = margin
        case .topRight:
            x = size.width - mapWidth - margin
        }

        return CGRect(
            x: x,
            y: size.height - mapHeight - margin,
            width: mapWidth,
            height: mapHeight
        )
    }

    private func elevationProfileRect(metricsTopY: CGFloat?) -> CGRect? {
        guard !allDataPoints.isEmpty else { return nil }
        let altitudes = allDataPoints.compactMap(\.altitude)
        guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(), maxAlt > minAlt else { return nil }

        let mapRect = mapRect()
        let topY = mapRect.minY - style.profileGap * scale
        let clearanceBaseY: CGFloat
        if style.mapPlacement == .topLeft {
            clearanceBaseY = size.height * 0.48
        } else {
            clearanceBaseY = metricsTopY ?? size.height * 0.45
        }

        let bottomY = clearanceBaseY + style.profileBottomPadding * scale
        let availableHeight = topY - bottomY
        guard availableHeight >= 36 * scale else { return nil }

        return CGRect(x: mapRect.minX, y: bottomY, width: mapRect.width, height: availableHeight)
    }

    private func topForBaseline(_ baselineY: CGFloat, fontSize: CGFloat) -> CGFloat {
        size.height - baselineY - fontSize
    }

    private func heartRateZone(_ hr: UInt8) -> Int {
        if hr <= settings.z1Max { return 1 }
        if hr <= settings.z2Max { return 2 }
        if hr <= settings.z3Max { return 3 }
        if hr <= settings.z4Max { return 4 }
        return 5
    }

    private func hrZoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return Color(red: 0.6, green: 0.6, blue: 0.6)
        case 2: return Color(red: 0.2, green: 0.8, blue: 0.2)
        case 3: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case 4: return Color(red: 1.0, green: 0.45, blue: 0.1)
        default: return Color(red: 1.0, green: 0.15, blue: 0.15)
        }
    }

    private func coreTempColor(_ temp: Double) -> Color {
        if temp >= 39.5 { return Color(red: 1, green: 0.1, blue: 0.1) }
        if temp >= 39.0 { return Color(red: 1, green: 0.4, blue: 0) }
        if temp >= 38.0 { return Color(red: 1, green: 0.8, blue: 0) }
        return Color(red: 0.3, green: 0.8, blue: 0.3)
    }

    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}

private struct LiveGPSTrackMapView: View {
    let trackCoordinates: [CLLocationCoordinate2D]
    let currentCoordinate: CLLocationCoordinate2D?
    let style: OverlayPresetRenderStyle
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            guard trackCoordinates.count >= 2 else { return }

            let lats = trackCoordinates.map(\.latitude)
            let lons = trackCoordinates.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }

            let latRange = maxLat - minLat
            let lonRange = maxLon - minLon
            guard latRange > 0 || lonRange > 0 else { return }

            let inset = 10 * scale
            let drawRect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let safeLatRange = latRange > 0 ? latRange : 1e-9
            let safeLonRange = lonRange > 0 ? lonRange : 1e-9
            let sx = drawRect.width / CGFloat(safeLonRange)
            let sy = drawRect.height / CGFloat(safeLatRange)
            let fitScale = min(sx, sy)
            let usedWidth = CGFloat(safeLonRange) * fitScale
            let usedHeight = CGFloat(safeLatRange) * fitScale
            let originX = drawRect.midX - usedWidth / 2
            let originY = drawRect.midY - usedHeight / 2

            func project(_ coord: CLLocationCoordinate2D) -> CGPoint {
                CGPoint(
                    x: originX + CGFloat(coord.longitude - minLon) * fitScale,
                    y: originY + CGFloat(maxLat - coord.latitude) * fitScale
                )
            }

            var path = Path()
            path.move(to: project(trackCoordinates[0]))
            for coord in trackCoordinates.dropFirst() {
                path.addLine(to: project(coord))
            }

            context.stroke(
                path,
                with: .color(color(style.trackOutlineColor)),
                style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(color(style.trackLineColor)),
                style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)
            )

            if let currentCoordinate {
                let p = project(currentCoordinate)
                let dot = 12 * scale
                let dotRect = CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
                context.fill(Path(ellipseIn: dotRect), with: .color(color(style.mapDotColor)))
                context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 2.5 * scale)
            }
        }
        .background(color(style.mapBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: style.mapCornerRadius * scale))
    }
}

private struct LiveElevationProfileView: View {
    let dataPoints: [FITDataPoint]
    let currentPoint: FITDataPoint
    let totalDistance: Double
    let style: OverlayPresetRenderStyle
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            let pointsWithAlt = dataPoints.filter { $0.altitude != nil }
            guard pointsWithAlt.count >= 2 else { return }
            let altitudes = pointsWithAlt.compactMap(\.altitude)
            guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(), maxAlt > minAlt else { return }

            let range = maxAlt - minAlt
            var fillPath = Path()
            var linePath = Path()

            for (index, point) in pointsWithAlt.enumerated() {
                guard let altitude = point.altitude else { continue }
                let x = CGFloat(index) / CGFloat(pointsWithAlt.count - 1) * size.width
                let y = size.height - CGFloat((altitude - minAlt) / range) * size.height

                if index == 0 {
                    fillPath.move(to: CGPoint(x: x, y: size.height))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                    linePath.move(to: CGPoint(x: x, y: y))
                } else {
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                    linePath.addLine(to: CGPoint(x: x, y: y))
                }
            }

            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(color(style.elevationFillColor)))
            context.stroke(linePath, with: .color(color(style.elevationLineColor)), lineWidth: 2 * scale)

            if let currentDistance = currentPoint.distance, totalDistance > 0 {
                let markerX = CGFloat(currentDistance / totalDistance) * size.width
                var marker = Path()
                marker.move(to: CGPoint(x: markerX, y: 0))
                marker.addLine(to: CGPoint(x: markerX, y: size.height))
                context.stroke(marker, with: .color(color(style.accentRed)), lineWidth: 2.5 * scale)

                if let altitude = currentPoint.altitude {
                    let y = size.height - CGFloat((altitude - minAlt) / range) * size.height
                    let dotRect = CGRect(x: markerX - 4 * scale, y: y - 4 * scale, width: 8 * scale, height: 8 * scale)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.white))
                }
            }
        }
        .background(color(style.panelBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: style.profileCornerRadius * scale))
    }
}

private struct LiveTextOverlayLayer: View {
    let overlays: [TextOverlay]
    let playbackTime: TimeInterval
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(overlays) { overlay in
                let opacity = overlay.opacity(at: playbackTime)
                if opacity > 0 {
                    LiveTextOverlayView(
                        overlay: overlay,
                        opacity: opacity,
                        scale: scale
                    )
                    .frame(width: size.width, height: size.height)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct LiveTextOverlayView: View {
    let overlay: TextOverlay
    let opacity: Double
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cgContext in
                drawTextOverlay(ctx: cgContext, size: size)
            }
        }
    }

    private func drawTextOverlay(ctx: CGContext, size: CGSize) {
        guard opacity > 0, size.width > 0, size.height > 0 else { return }

        let fontSize = max(1, overlay.fontSize * scale)
        let font = textOverlayFont(size: fontSize)
        let textColor = nsColor(overlay.color, applyingOpacity: opacity, fallback: .white)
        let strokeColor = nsColor(overlay.strokeColor, applyingOpacity: opacity, fallback: .black)
        let shadowColor = cgColor(overlay.shadowColor, applyingOpacity: opacity, fallback: .black)
        let padding = 30 * scale
        let strokeWidth = max(0, overlay.strokeWidth) * scale
        let lineHeight = max(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), fontSize * 1.2)

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
        let centerX = min(max(overlay.relativeX, 0), 1) * size.width
        let centerY = size.height - min(max(overlay.relativeY, 0), 1) * size.height
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
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity

        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.setFillColor(overlay.backgroundColor)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.fill(bgRect)
        ctx.restoreGState()

        let firstBaseline = centerY + totalHeight / 2 - CTFontGetAscent(font)
        for (index, (ctLine, width, bounds)) in lineData.enumerated() {
            let x = centerX - width / 2 - bounds.origin.x
            let y = firstBaseline - lineHeight * CGFloat(index)
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

        ctx.restoreGState()
    }

    private func textOverlayFont(size: CGFloat) -> CTFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.liveNSFontWeight)
        let nsFont = NSFontManager.shared.font(
            withFamily: overlay.fontFamily,
            traits: [],
            weight: overlay.fontWeight.liveNSFontManagerWeight,
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
}

private func liveScale(for size: CGSize) -> CGFloat {
    max(size.width, 1) / 1920.0
}

private func displayRect(fromRendererRect rect: CGRect, in size: CGSize) -> CGRect {
    CGRect(
        x: rect.minX,
        y: size.height - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

private func color(_ cgColor: CGColor) -> Color {
    Color(nsColor: NSColor(cgColor: cgColor) ?? .white)
}

private extension TextOverlay.FontWeight {
    var liveNSFontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var liveNSFontManagerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }
}
