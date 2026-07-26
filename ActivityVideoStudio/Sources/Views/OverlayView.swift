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
    let trackSegments: [[CLLocationCoordinate2D]]
    let textOverlays: [TextOverlay]
    let textPlaybackTime: TimeInterval
    @StateObject private var geometryCache = LivePreviewOverlayGeometryCache()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = liveScale(for: size)
            let playbackTime = frame?.globalPlaybackTime ?? textPlaybackTime

            ZStack(alignment: .topLeading) {
                if let frame {
                    LiveActivityDataLayer(
                        frame: frame,
                        settings: settings,
                        allDataPoints: allDataPoints,
                        trackSegments: trackSegments,
                        size: size,
                        scale: scale,
                        geometryCache: geometryCache
                    )
                }

                LiveTextOverlayLayer(
                    overlays: textOverlays,
                    playbackTime: playbackTime,
                    size: size,
                    scale: scale
                )
            }
            .opacity(settings.effectiveOverlayOpacity)
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
    let trackSegments: [[CLLocationCoordinate2D]]
    let size: CGSize
    let scale: CGFloat
    @ObservedObject var geometryCache: LivePreviewOverlayGeometryCache

    private var style: OverlayPresetRenderStyle {
        settings.selectedRenderStyle
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if frame.recordingState == .noRecording {
                Text("記録なし")
                    .font(.system(size: 34 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 30 * scale)
                    .padding(.vertical, 16 * scale)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12 * scale))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if frame.recordingState == .waitingForStart {
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
                    style: style,
                    scale: scale,
                    geometryCache: geometryCache
                )
                .frame(width: displayRect.width, height: displayRect.height)
                .offset(x: displayRect.minX, y: displayRect.minY)
            }

            if settings.showMiniMap, hasDrawableTrack {
                let displayRect = displayRect(fromRendererRect: mapRect(), in: size)
                LiveGPSTrackMapView(
                    trackSegments: trackSegments,
                    currentCoordinate: frame.dataPoint.coordinate,
                    style: style,
                    scale: scale,
                    geometryCache: geometryCache
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

            if settings.showGrade {
                labelValue(
                    label: "GRADE",
                    value: frame.dataPoint.gradeFormatted(fallbackDataPoints: allDataPoints),
                    x: rightX,
                    y: rightGradeY()
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
        if settings.showGrade {
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

    private func rightGradeY() -> CGFloat {
        var y = style.rightStartY(in: size, scale: scale)
        if settings.showDistance { y += style.rightDistanceAdvance * scale }
        if settings.showTime { y += style.rightMetricAdvance * scale }
        if settings.showElevationGain { y += style.rightMetricAdvance * scale }
        return y
    }

    private func rightAltitudeY() -> CGFloat {
        var y = style.rightStartY(in: size, scale: scale)
        if settings.showDistance { y += style.rightDistanceAdvance * scale }
        if settings.showTime { y += style.rightMetricAdvance * scale }
        if settings.showElevationGain { y += style.rightMetricAdvance * scale }
        if settings.showGrade { y += style.rightMetricAdvance * scale }
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
        guard geometryCache.hasDrawableElevationProfile(for: allDataPoints) else { return nil }

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

    private var hasDrawableTrack: Bool {
        geometryCache.hasDrawableTrack(for: trackSegments)
    }

    private func topForBaseline(_ baselineY: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(1, fontSize), nil)
        return size.height - baselineY - CTFontGetAscent(font)
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
    let trackSegments: [[CLLocationCoordinate2D]]
    let currentCoordinate: CLLocationCoordinate2D?
    let style: OverlayPresetRenderStyle
    let scale: CGFloat
    @ObservedObject var geometryCache: LivePreviewOverlayGeometryCache

    var body: some View {
        if geometryCache.hasDrawableTrack(for: trackSegments) {
            Canvas { context, size in
                guard let drawing = geometryCache.trackDrawing(
                    for: trackSegments,
                    size: size,
                    scale: scale
                ) else { return }

                context.stroke(
                    drawing.path,
                    with: .color(color(style.trackOutlineColor)),
                    style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    drawing.path,
                    with: .color(color(style.trackLineColor)),
                    style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)
                )

                if let currentCoordinate, CLLocationCoordinate2DIsValid(currentCoordinate) {
                    let p = drawing.project(currentCoordinate)
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
}

private struct LiveElevationProfileView: View {
    let dataPoints: [FITDataPoint]
    let currentPoint: FITDataPoint
    let style: OverlayPresetRenderStyle
    let scale: CGFloat
    @ObservedObject var geometryCache: LivePreviewOverlayGeometryCache

    var body: some View {
        Canvas { context, size in
            guard let drawing = geometryCache.elevationDrawing(for: dataPoints, size: size) else { return }

            context.fill(drawing.fillPath, with: .color(color(style.elevationFillColor)))
            context.stroke(drawing.linePath, with: .color(color(style.elevationLineColor)), lineWidth: 2 * scale)

            if let currentDistance = currentPoint.distance, drawing.totalDistance > 0 {
                let markerX = CGFloat(min(max(currentDistance / drawing.totalDistance, 0), 1)) * size.width
                var marker = Path()
                marker.move(to: CGPoint(x: markerX, y: 0))
                marker.addLine(to: CGPoint(x: markerX, y: size.height))
                context.stroke(marker, with: .color(color(style.accentRed)), lineWidth: 2.5 * scale)

                if let altitude = currentPoint.altitude {
                    let y = drawing.y(forAltitude: altitude, in: size)
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
                offset: CGSize(width: overlay.shadowOffsetX * scale, height: overlay.shadowOffsetY * scale),
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

private final class LivePreviewOverlayGeometryCache: ObservableObject {
    private static let maxPreviewTrackPoints = 2_000
    private static let maxPreviewElevationSamples = 2_000

    private var trackSourceCache: (key: CoordinateSignature, source: PreviewTrackSource?)?
    private var trackDrawingCache: (key: PreviewTrackDrawingKey, drawing: PreviewTrackDrawing)?
    private var elevationSourceCache: (key: DataPointSignature, source: PreviewElevationSource?)?
    private var elevationDrawingCache: (key: PreviewElevationDrawingKey, drawing: PreviewElevationDrawing)?

    func hasDrawableTrack(for segments: [[CLLocationCoordinate2D]]) -> Bool {
        trackSource(for: segments) != nil
    }

    func trackDrawing(
        for segments: [[CLLocationCoordinate2D]],
        size: CGSize,
        scale: CGFloat
    ) -> PreviewTrackDrawing? {
        guard let source = trackSource(for: segments) else { return nil }
        let key = PreviewTrackDrawingKey(sourceKey: source.key, size: size, scale: scale)
        if let cached = trackDrawingCache, cached.key == key {
            return cached.drawing
        }

        guard let drawing = Self.makeTrackDrawing(source: source, size: size, scale: scale) else {
            trackDrawingCache = nil
            return nil
        }
        trackDrawingCache = (key, drawing)
        return drawing
    }

    func hasDrawableElevationProfile(for dataPoints: [FITDataPoint]) -> Bool {
        elevationSource(for: dataPoints) != nil
    }

    func elevationDrawing(for dataPoints: [FITDataPoint], size: CGSize) -> PreviewElevationDrawing? {
        guard let source = elevationSource(for: dataPoints) else { return nil }
        let key = PreviewElevationDrawingKey(sourceKey: source.key, size: size)
        if let cached = elevationDrawingCache, cached.key == key {
            return cached.drawing
        }

        let drawing = Self.makeElevationDrawing(source: source, size: size)
        elevationDrawingCache = (key, drawing)
        return drawing
    }

    private func trackSource(for segments: [[CLLocationCoordinate2D]]) -> PreviewTrackSource? {
        let key = CoordinateSignature(segments)
        if let cached = trackSourceCache, cached.key == key {
            return cached.source
        }

        let source = Self.makeTrackSource(segments: segments, key: key)
        trackSourceCache = (key, source)
        trackDrawingCache = nil
        return source
    }

    private func elevationSource(for dataPoints: [FITDataPoint]) -> PreviewElevationSource? {
        let key = DataPointSignature(dataPoints)
        if let cached = elevationSourceCache, cached.key == key {
            return cached.source
        }

        let source = Self.makeElevationSource(dataPoints: dataPoints, key: key)
        elevationSourceCache = (key, source)
        elevationDrawingCache = nil
        return source
    }

    private static func makeTrackSource(
        segments: [[CLLocationCoordinate2D]],
        key: CoordinateSignature
    ) -> PreviewTrackSource? {
        var validCoordinates: [CLLocationCoordinate2D] = []
        var pathSegments: [[CLLocationCoordinate2D]] = []
        validCoordinates.reserveCapacity(segments.reduce(0) { $0 + $1.count })

        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude

        for segment in segments {
            let validSegment = downsampled(segment.filter(CLLocationCoordinate2DIsValid), maxCount: maxPreviewTrackPoints)
            guard !validSegment.isEmpty else { continue }
            pathSegments.append(validSegment)
            for coordinate in validSegment {
                validCoordinates.append(coordinate)
                minLat = min(minLat, coordinate.latitude)
                maxLat = max(maxLat, coordinate.latitude)
            }
        }

        guard validCoordinates.count >= 2 else { return nil }

        let centerLatitude = (minLat + maxLat) / 2
        let lonScale = max(abs(cos(centerLatitude * .pi / 180)), 1e-9)
        var minProjectedLon = Double.greatestFiniteMagnitude
        var maxProjectedLon = -Double.greatestFiniteMagnitude

        for coordinate in validCoordinates {
            let projectedLongitude = coordinate.longitude * lonScale
            minProjectedLon = min(minProjectedLon, projectedLongitude)
            maxProjectedLon = max(maxProjectedLon, projectedLongitude)
        }

        let latRange = maxLat - minLat
        let lonRange = maxProjectedLon - minProjectedLon
        guard latRange > 0 || lonRange > 0 else { return nil }

        return PreviewTrackSource(
            key: key,
            segments: pathSegments,
            minLat: minLat,
            maxLat: maxLat,
            minProjectedLon: minProjectedLon,
            maxProjectedLon: maxProjectedLon,
            lonScale: lonScale
        )
    }

    private static func makeTrackDrawing(
        source: PreviewTrackSource,
        size: CGSize,
        scale: CGFloat
    ) -> PreviewTrackDrawing? {
        guard size.width > 0, size.height > 0, source.segments.contains(where: { !$0.isEmpty }) else { return nil }

        let inset = 10 * scale
        let drawRect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let safeLatRange = source.latRange > 0 ? source.latRange : 1e-9
        let safeLonRange = source.lonRange > 0 ? source.lonRange : 1e-9
        let sx = drawRect.width / CGFloat(safeLonRange)
        let sy = drawRect.height / CGFloat(safeLatRange)
        let fitScale = min(sx, sy)
        let usedWidth = CGFloat(safeLonRange) * fitScale
        let usedHeight = CGFloat(safeLatRange) * fitScale
        let originX = drawRect.midX - usedWidth / 2
        let originY = drawRect.midY - usedHeight / 2

        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(
                x: originX + CGFloat(source.projectedLongitude(coordinate) - source.minProjectedLon) * fitScale,
                y: originY + CGFloat(source.maxLat - coordinate.latitude) * fitScale
            )
        }

        var path = Path()
        for segment in source.segments where !segment.isEmpty {
            path.move(to: project(segment[0]))
            for coordinate in segment.dropFirst() { path.addLine(to: project(coordinate)) }
        }

        return PreviewTrackDrawing(
            path: path,
            originX: originX,
            originY: originY,
            fitScale: fitScale,
            minProjectedLon: source.minProjectedLon,
            maxLat: source.maxLat,
            lonScale: source.lonScale
        )
    }

    private static func makeElevationSource(
        dataPoints: [FITDataPoint],
        key: DataPointSignature
    ) -> PreviewElevationSource? {
        var rawSamples: [(distance: Double, altitude: Double)] = []
        rawSamples.reserveCapacity(dataPoints.count)

        var totalDistance = 0.0
        var minAltitude = Double.greatestFiniteMagnitude
        var maxAltitude = -Double.greatestFiniteMagnitude

        for point in dataPoints {
            guard let altitude = point.altitude, let distance = point.distance else { continue }
            rawSamples.append((distance, altitude))
            totalDistance = max(totalDistance, distance)
            minAltitude = min(minAltitude, altitude)
            maxAltitude = max(maxAltitude, altitude)
        }

        guard rawSamples.count >= 2, totalDistance > 0, maxAltitude > minAltitude else { return nil }

        let samples = rawSamples.map { sample in
            ElevationProfileSample(
                distanceRatio: CGFloat(min(max(sample.distance / totalDistance, 0), 1)),
                altitude: sample.altitude
            )
        }

        return PreviewElevationSource(
            key: key,
            samples: downsampled(samples, maxCount: maxPreviewElevationSamples),
            totalDistance: totalDistance,
            minAltitude: minAltitude,
            maxAltitude: maxAltitude
        )
    }

    private static func makeElevationDrawing(
        source: PreviewElevationSource,
        size: CGSize
    ) -> PreviewElevationDrawing {
        let range = source.maxAltitude - source.minAltitude
        var fillPath = Path()
        var linePath = Path()

        for (index, sample) in source.samples.enumerated() {
            let x = sample.distanceRatio * size.width
            let y = size.height - CGFloat((sample.altitude - source.minAltitude) / range) * size.height

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

        return PreviewElevationDrawing(
            fillPath: fillPath,
            linePath: linePath,
            totalDistance: source.totalDistance,
            minAltitude: source.minAltitude,
            maxAltitude: source.maxAltitude
        )
    }

    private static func downsampled<T>(_ values: [T], maxCount: Int) -> [T] {
        guard values.count > maxCount, maxCount >= 2 else { return values }

        let lastSourceIndex = values.count - 1
        let lastTargetIndex = maxCount - 1
        return (0..<maxCount).map { index in
            let sourceIndex = Int((Double(index) * Double(lastSourceIndex) / Double(lastTargetIndex)).rounded())
            return values[min(sourceIndex, lastSourceIndex)]
        }
    }
}

private struct ElevationProfileSample {
    let distanceRatio: CGFloat
    let altitude: Double
}

private struct PreviewTrackSource {
    let key: CoordinateSignature
    let segments: [[CLLocationCoordinate2D]]
    let minLat: Double
    let maxLat: Double
    let minProjectedLon: Double
    let maxProjectedLon: Double
    let lonScale: Double

    var latRange: Double { maxLat - minLat }
    var lonRange: Double { maxProjectedLon - minProjectedLon }

    func projectedLongitude(_ coordinate: CLLocationCoordinate2D) -> Double {
        coordinate.longitude * lonScale
    }
}

private struct PreviewTrackDrawing {
    let path: Path
    let originX: CGFloat
    let originY: CGFloat
    let fitScale: CGFloat
    let minProjectedLon: Double
    let maxLat: Double
    let lonScale: Double

    func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        CGPoint(
            x: originX + CGFloat(coordinate.longitude * lonScale - minProjectedLon) * fitScale,
            y: originY + CGFloat(maxLat - coordinate.latitude) * fitScale
        )
    }
}

private struct PreviewElevationSource {
    let key: DataPointSignature
    let samples: [ElevationProfileSample]
    let totalDistance: Double
    let minAltitude: Double
    let maxAltitude: Double
}

private struct PreviewElevationDrawing {
    let fillPath: Path
    let linePath: Path
    let totalDistance: Double
    let minAltitude: Double
    let maxAltitude: Double

    func y(forAltitude altitude: Double, in size: CGSize) -> CGFloat {
        let range = maxAltitude - minAltitude
        return size.height - CGFloat((altitude - minAltitude) / range) * size.height
    }
}

private struct PreviewTrackDrawingKey: Hashable {
    let sourceKey: CoordinateSignature
    let width: Int64
    let height: Int64
    let scale: Int64

    init(sourceKey: CoordinateSignature, size: CGSize, scale: CGFloat) {
        self.sourceKey = sourceKey
        width = quantized(size.width, scale: 1_000)
        height = quantized(size.height, scale: 1_000)
        self.scale = quantized(scale, scale: 1_000_000)
    }
}

private struct PreviewElevationDrawingKey: Hashable {
    let sourceKey: DataPointSignature
    let width: Int64
    let height: Int64

    init(sourceKey: DataPointSignature, size: CGSize) {
        self.sourceKey = sourceKey
        width = quantized(size.width, scale: 1_000)
        height = quantized(size.height, scale: 1_000)
    }
}

private struct CoordinateSignature: Hashable {
    let count: Int
    let segmentCounts: [Int]
    let firstLatitude: Int64
    let firstLongitude: Int64
    let middleLatitude: Int64
    let middleLongitude: Int64
    let lastLatitude: Int64
    let lastLongitude: Int64

    init(_ segments: [[CLLocationCoordinate2D]]) {
        let coordinates = segments.flatMap { $0 }
        count = coordinates.count
        // The segment layout is part of the visual output, not just its points.
        segmentCounts = segments.map(\.count)
        let first = coordinates.first
        let middle = coordinates.isEmpty ? nil : coordinates[coordinates.count / 2]
        let last = coordinates.last
        firstLatitude = quantizedCoordinate(first?.latitude)
        firstLongitude = quantizedCoordinate(first?.longitude)
        middleLatitude = quantizedCoordinate(middle?.latitude)
        middleLongitude = quantizedCoordinate(middle?.longitude)
        lastLatitude = quantizedCoordinate(last?.latitude)
        lastLongitude = quantizedCoordinate(last?.longitude)
    }
}

private struct DataPointSignature: Hashable {
    let count: Int
    let first: DataPointSignatureComponent
    let middle: DataPointSignatureComponent
    let last: DataPointSignatureComponent

    init(_ dataPoints: [FITDataPoint]) {
        count = dataPoints.count
        first = DataPointSignatureComponent(dataPoints.first)
        middle = DataPointSignatureComponent(dataPoints.isEmpty ? nil : dataPoints[dataPoints.count / 2])
        last = DataPointSignatureComponent(dataPoints.last)
    }
}

private struct DataPointSignatureComponent: Hashable {
    let timestamp: Int64
    let distance: Int64
    let altitude: Int64

    init(_ dataPoint: FITDataPoint?) {
        timestamp = quantized(dataPoint?.timestamp.timeIntervalSinceReferenceDate, scale: 1_000)
        distance = quantized(dataPoint?.distance, scale: 1_000)
        altitude = quantized(dataPoint?.altitude, scale: 1_000)
    }
}

private func quantizedCoordinate(_ value: Double?) -> Int64 {
    quantized(value, scale: 100_000_000)
}

private func quantized(_ value: CGFloat, scale: Double) -> Int64 {
    quantized(Double(value), scale: scale)
}

private func quantized(_ value: Double?, scale: Double) -> Int64 {
    guard let value else { return Int64.min }
    return quantized(value, scale: scale)
}

private func quantized(_ value: Double, scale: Double) -> Int64 {
    guard value.isFinite, scale.isFinite, scale > 0 else { return Int64.min }
    let scaled = (value * scale).rounded()
    if scaled >= Double(Int64.max) { return Int64.max }
    if scaled <= Double(Int64.min) { return Int64.min }
    return Int64(scaled)
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
