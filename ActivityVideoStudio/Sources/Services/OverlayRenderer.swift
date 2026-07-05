import Foundation
import CoreGraphics
import AppKit
import CoreLocation

/// Renders floating activity data overlay with circular HR gauge.
/// Layout: right side dominant, no bottom bar, drop shadows on text.
final class OverlayRenderer {

    let videoSize: CGSize
    var settings: OverlaySettings
    var allDataPoints: [FITDataPoint] = [] {
        didSet {
            hasDistanceData = allDataPoints.contains { $0.distance != nil }
            invalidateElevationProfileCache()
            buildElevationGainCache()
        }
    }
    var textOverlays: [TextOverlay] = []
    var trackCoordinates: [CLLocationCoordinate2D] = [] {
        didSet {
            invalidateTrackCache()
        }
    }
    var fitRecordingActive = true
    private var hasDistanceData = false

    private var scale: CGFloat { videoSize.width / 1920.0 }

    // Elevation gain cache
    private var elevationGainCache: [Double] = []
    private var renderContextCache: BitmapContextCache?
    private var opacityContextCache: BitmapContextCache?
    private var fontCache: [FontCacheKey: CTFont] = [:]
    private var trackSourceCache: (key: CoordinateSignature, source: RendererTrackSource?)?
    private var trackDrawingCache: (key: RendererTrackDrawingKey, drawing: RendererTrackDrawing)?
    private var elevationSourceCache: (key: DataPointSignature, source: RendererElevationSource?)?
    private var elevationDrawingCache: (key: RendererElevationDrawingKey, drawing: RendererElevationDrawing)?

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
    private var renderStyle: OverlayPresetRenderStyle { settings.selectedRenderStyle }
    private var accentColor: CGColor { renderStyle.accentColor }
    private var accentRed: CGColor { renderStyle.accentRed }
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private var shadowColor: CGColor { renderStyle.shadowColor }
    private var metricsBackgroundColor: CGColor { renderStyle.metricsBackgroundColor }


    init(videoSize: CGSize, settings: OverlaySettings = OverlaySettings()) {
        self.videoSize = videoSize
        self.settings = settings
    }

    func makeExportCopy(videoSize exportVideoSize: CGSize? = nil) -> OverlayRenderer {
        let copy = OverlayRenderer(videoSize: exportVideoSize ?? videoSize, settings: settings.snapshot())
        copy.allDataPoints = allDataPoints
        copy.textOverlays = textOverlays
        copy.trackCoordinates = trackCoordinates
        copy.fitRecordingActive = fitRecordingActive
        copy.elevationGainCache = elevationGainCache
        return copy
    }

    func isFitRecordingActive(dataPoint: FITDataPoint, elapsedTime: TimeInterval) -> Bool {
        guard elapsedTime >= 0 else { return false }
        guard hasDistanceData else { return true }
        return (dataPoint.distance ?? 0) > 0
    }

    // MARK: - Render

    func render(
        dataPoint: FITDataPoint,
        elapsedTime: TimeInterval,
        globalPlaybackTime: TimeInterval = 0,
        fitRecordingActive: Bool? = nil
    ) -> CGImage? {
        let w = Int(videoSize.width), h = Int(videoSize.height)
        guard let ctx = Self.bitmapContext(width: w, height: h, cache: &renderContextCache) else { return nil }

        Self.prepareBitmapContext(ctx, width: w, height: h)
        ctx.textMatrix = .identity
        ctx.setShadow(offset: CGSize(width: 1.5 * scale, height: -1.5 * scale), blur: 3 * scale, color: shadowColor)

        let effectiveFITRecordingActive = fitRecordingActive ?? self.fitRecordingActive
        if !effectiveFITRecordingActive {
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

        // === RIGHT SIDE (top→bottom): GPS track (drawn directly by OverlayRenderer) → Distance → TIME → ELEV GAIN → GRADE → ALTITUDE → 標高グラフ ===

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

        if settings.showGrade {
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

        // GRADE - right, below elevation gain
        if settings.showGrade {
            let value = dataPoint.gradeFormatted(fallbackDataPoints: allDataPoints)
            drawLabelValue(ctx: ctx, label: "GRADE", value: value, x: rightX, y: rightY, labelColor: accentColor, valueSize: valueFontSize, labelSize: labelFontSize)
            rightY += rightAdvance
        }

        // ALTITUDE (current elevation) - right, below grade
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

        _ = drawTextOverlays(ctx: ctx, globalPlaybackTime: globalPlaybackTime)

        guard let overlayImage = ctx.makeImage() else { return nil }
        return imageByApplyingOverlayOpacity(overlayImage, width: w, height: h)
    }

    func renderTextOverlaysOnly(globalPlaybackTime: TimeInterval) -> CGImage? {
        let w = Int(videoSize.width), h = Int(videoSize.height)
        guard let ctx = Self.bitmapContext(width: w, height: h, cache: &renderContextCache) else { return nil }

        Self.prepareBitmapContext(ctx, width: w, height: h)
        ctx.textMatrix = .identity

        guard drawTextOverlays(ctx: ctx, globalPlaybackTime: globalPlaybackTime),
              let overlayImage = ctx.makeImage() else {
            return nil
        }
        return imageByApplyingOverlayOpacity(overlayImage, width: w, height: h)
    }

    private static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func bitmapContext(
        width: Int,
        height: Int,
        cache: inout BitmapContextCache?
    ) -> CGContext? {
        if let cached = cache, cached.width == width, cached.height == height {
            return cached.context
        }

        guard let context = Self.makeBitmapContext(width: width, height: height) else { return nil }
        cache = BitmapContextCache(width: width, height: height, context: context)
        return context
    }

    private static func prepareBitmapContext(_ context: CGContext, width: Int, height: Int) {
        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setBlendMode(.normal)
        context.setAlpha(1)
        context.clear(rect)
        context.setLineWidth(1)
        context.setLineCap(.butt)
        context.setLineJoin(.miter)
        context.textMatrix = .identity
    }

    private func imageByApplyingOverlayOpacity(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let opacity = CGFloat(settings.effectiveOverlayOpacity)
        guard opacity < 1 else { return image }
        guard let ctx = Self.bitmapContext(width: width, height: height, cache: &opacityContextCache) else { return image }

        Self.prepareBitmapContext(ctx, width: width, height: height)
        ctx.setAlpha(opacity)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage() ?? image
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
        guard let profileData = elevationProfileSource() else { return }

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
        guard let drawing = elevationDrawing(source: profileData, profileRect: profileRect) else { return }

        // Semi-transparent background
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(style.panelBackgroundColor)
        ctx.addPath(drawing.backgroundPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Elevation line
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)

        // Fill under the line
        ctx.addPath(drawing.fillPath)
        ctx.setFillColor(style.elevationFillColor)
        ctx.fillPath()

        // Stroke the line
        ctx.setStrokeColor(style.elevationLineColor)
        ctx.setLineWidth(2 * scale)
        ctx.addPath(drawing.linePath)
        ctx.strokePath()

        // Current position marker
        if let cd = currentPoint.distance, profileData.totalDistance > 0 {
            let progress = min(max(cd / profileData.totalDistance, 0), 1)
            let mx = profileRect.minX + CGFloat(progress) * profileRect.width
            ctx.setStrokeColor(accentRed)
            ctx.setLineWidth(2.5 * scale)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: mx, y: profileRect.minY))
            ctx.addLine(to: CGPoint(x: mx, y: profileRect.maxY))
            ctx.strokePath()

            // Dot at current altitude
            if let alt = currentPoint.altitude {
                let dotY = drawing.y(forAltitude: alt)
                ctx.setFillColor(white)
                ctx.fillEllipse(in: CGRect(x: mx - 4 * scale, y: CGFloat(dotY) - 4 * scale, width: 8 * scale, height: 8 * scale))
            }
        }

        ctx.restoreGState()
    }

    private func elevationProfileSource() -> RendererElevationSource? {
        let key = DataPointSignature(dataPoints: allDataPoints)
        if let cached = elevationSourceCache, cached.key == key {
            return cached.source
        }

        let source = Self.makeElevationSource(dataPoints: allDataPoints, key: key)
        elevationSourceCache = (key, source)
        elevationDrawingCache = nil
        return source
    }

    private func elevationDrawing(
        source: RendererElevationSource,
        profileRect: CGRect
    ) -> RendererElevationDrawing? {
        let cornerRadius = renderStyle.profileCornerRadius * scale
        let key = RendererElevationDrawingKey(
            sourceKey: source.key,
            profileRect: profileRect,
            cornerRadius: cornerRadius
        )
        if let cached = elevationDrawingCache, cached.key == key {
            return cached.drawing
        }

        guard let drawing = Self.makeElevationDrawing(
            source: source,
            profileRect: profileRect,
            cornerRadius: cornerRadius
        ) else {
            elevationDrawingCache = nil
            return nil
        }

        elevationDrawingCache = (key, drawing)
        return drawing
    }

    private static func makeElevationSource(
        dataPoints: [FITDataPoint],
        key: DataPointSignature
    ) -> RendererElevationSource? {
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

        return RendererElevationSource(
            key: key,
            samples: samples,
            totalDistance: totalDistance,
            minAltitude: minAltitude,
            maxAltitude: maxAltitude
        )
    }

    private static func makeElevationDrawing(
        source: RendererElevationSource,
        profileRect: CGRect,
        cornerRadius: CGFloat
    ) -> RendererElevationDrawing? {
        let range = source.maxAltitude - source.minAltitude
        guard range > 0, let first = source.samples.first else { return nil }

        func point(for sample: ElevationProfileSample) -> CGPoint {
            CGPoint(
                x: profileRect.minX + sample.distanceRatio * profileRect.width,
                y: profileRect.minY + CGFloat((sample.altitude - source.minAltitude) / range) * profileRect.height
            )
        }

        let fillPath = CGMutablePath()
        let linePath = CGMutablePath()
        let firstPoint = point(for: first)

        fillPath.move(to: CGPoint(x: firstPoint.x, y: profileRect.minY))
        fillPath.addLine(to: firstPoint)
        linePath.move(to: firstPoint)

        for sample in source.samples.dropFirst() {
            let p = point(for: sample)
            fillPath.addLine(to: p)
            linePath.addLine(to: p)
        }

        fillPath.addLine(to: CGPoint(x: profileRect.maxX, y: profileRect.minY))
        fillPath.closeSubpath()

        return RendererElevationDrawing(
            backgroundPath: CGPath(
                roundedRect: profileRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            ),
            fillPath: fillPath,
            linePath: linePath,
            profileRect: profileRect,
            minAltitude: source.minAltitude,
            maxAltitude: source.maxAltitude
        )
    }

    // MARK: - GPS Track (top-right mini-map)

    private func drawGPSTrack(ctx: CGContext, currentPoint: FITDataPoint) {
        guard let drawing = trackDrawing() else { return }

        let style = renderStyle

        // Background: semi-transparent black, 8pt corner radius
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setFillColor(style.mapBackgroundColor)
        ctx.addPath(drawing.backgroundPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Clip to rounded map rect so the polyline never escapes the frame.
        ctx.addPath(drawing.backgroundPath)
        ctx.clip()

        // Outline (black, alpha 0.5, 5pt)
        ctx.addPath(drawing.polylinePath)
        ctx.setStrokeColor(style.trackOutlineColor)
        ctx.setLineWidth(5 * scale)
        ctx.strokePath()

        // Foreground (cyan, 3pt)
        ctx.addPath(drawing.polylinePath)
        ctx.setStrokeColor(style.trackLineColor)
        ctx.setLineWidth(3 * scale)
        ctx.strokePath()

        // Current position dot (red with white stroke) — only when we have a coord.
        if let current = currentPoint.coordinate, CLLocationCoordinate2DIsValid(current) {
            let p = drawing.project(current)
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

    private func trackSource() -> RendererTrackSource? {
        let key = CoordinateSignature(coordinates: trackCoordinates)
        if let cached = trackSourceCache, cached.key == key {
            return cached.source
        }

        let source = Self.makeTrackSource(coordinates: trackCoordinates, key: key)
        trackSourceCache = (key, source)
        trackDrawingCache = nil
        return source
    }

    private func trackDrawing() -> RendererTrackDrawing? {
        guard let source = trackSource() else { return nil }

        let mapRect = self.mapRect()
        let cornerRadius = renderStyle.mapCornerRadius * scale
        let key = RendererTrackDrawingKey(
            sourceKey: source.key,
            mapRect: mapRect,
            scale: scale,
            cornerRadius: cornerRadius
        )
        if let cached = trackDrawingCache, cached.key == key {
            return cached.drawing
        }

        guard let drawing = Self.makeTrackDrawing(
            source: source,
            mapRect: mapRect,
            scale: scale,
            cornerRadius: cornerRadius
        ) else {
            trackDrawingCache = nil
            return nil
        }

        trackDrawingCache = (key, drawing)
        return drawing
    }

    private static func makeTrackSource(
        coordinates: [CLLocationCoordinate2D],
        key: CoordinateSignature
    ) -> RendererTrackSource? {
        var validCoordinates: [CLLocationCoordinate2D] = []
        validCoordinates.reserveCapacity(coordinates.count)

        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude

        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            validCoordinates.append(coordinate)
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
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

        return RendererTrackSource(
            key: key,
            coordinates: validCoordinates,
            minLat: minLat,
            maxLat: maxLat,
            minProjectedLon: minProjectedLon,
            maxProjectedLon: maxProjectedLon,
            lonScale: lonScale
        )
    }

    private static func makeTrackDrawing(
        source: RendererTrackSource,
        mapRect: CGRect,
        scale: CGFloat,
        cornerRadius: CGFloat
    ) -> RendererTrackDrawing? {
        guard let first = source.coordinates.first else { return nil }

        // Preserve aspect ratio inside the map area with an inset.
        let inset = 10 * scale
        let drawRect = mapRect.insetBy(dx: inset, dy: inset)

        // Guard against divide-by-zero when all points share a lat or lon.
        let safeLatRange = source.latRange > 0 ? source.latRange : 1e-9
        let safeLonRange = source.lonRange > 0 ? source.lonRange : 1e-9

        // Fit: compute scale that fits both axes, keeping aspect ratio.
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
                y: originY + CGFloat(coordinate.latitude - source.minLat) * fitScale
            )
        }

        let polyline = CGMutablePath()
        polyline.move(to: project(first))
        for coordinate in source.coordinates.dropFirst() {
            polyline.addLine(to: project(coordinate))
        }

        return RendererTrackDrawing(
            backgroundPath: CGPath(
                roundedRect: mapRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            ),
            polylinePath: polyline,
            originX: originX,
            originY: originY,
            fitScale: fitScale,
            minLat: source.minLat,
            minProjectedLon: source.minProjectedLon,
            lonScale: source.lonScale
        )
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

    private func invalidateTrackCache() {
        trackSourceCache = nil
        trackDrawingCache = nil
    }

    private func invalidateElevationProfileCache() {
        elevationSourceCache = nil
        elevationDrawingCache = nil
    }

    private struct BitmapContextCache {
        let width: Int
        let height: Int
        let context: CGContext
    }

    private struct ElevationProfileSample {
        let distanceRatio: CGFloat
        let altitude: Double
    }

    private struct RendererElevationSource {
        let key: DataPointSignature
        let samples: [ElevationProfileSample]
        let totalDistance: Double
        let minAltitude: Double
        let maxAltitude: Double
    }

    private struct RendererElevationDrawing {
        let backgroundPath: CGPath
        let fillPath: CGPath
        let linePath: CGPath
        let profileRect: CGRect
        let minAltitude: Double
        let maxAltitude: Double

        func y(forAltitude altitude: Double) -> CGFloat {
            profileRect.minY + CGFloat((altitude - minAltitude) / (maxAltitude - minAltitude)) * profileRect.height
        }
    }

    private struct RendererTrackSource {
        let key: CoordinateSignature
        let coordinates: [CLLocationCoordinate2D]
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

    private struct RendererTrackDrawing {
        let backgroundPath: CGPath
        let polylinePath: CGPath
        let originX: CGFloat
        let originY: CGFloat
        let fitScale: CGFloat
        let minLat: Double
        let minProjectedLon: Double
        let lonScale: Double

        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(
                x: originX + CGFloat(coordinate.longitude * lonScale - minProjectedLon) * fitScale,
                y: originY + CGFloat(coordinate.latitude - minLat) * fitScale
            )
        }
    }

    private struct RendererElevationDrawingKey: Hashable {
        let sourceKey: DataPointSignature
        let rect: GeometryRectKey
        let cornerRadius: Int64

        init(sourceKey: DataPointSignature, profileRect: CGRect, cornerRadius: CGFloat) {
            self.sourceKey = sourceKey
            rect = GeometryRectKey(profileRect)
            self.cornerRadius = quantized(cornerRadius, scale: 1_000)
        }
    }

    private struct RendererTrackDrawingKey: Hashable {
        let sourceKey: CoordinateSignature
        let rect: GeometryRectKey
        let scale: Int64
        let cornerRadius: Int64

        init(sourceKey: CoordinateSignature, mapRect: CGRect, scale: CGFloat, cornerRadius: CGFloat) {
            self.sourceKey = sourceKey
            rect = GeometryRectKey(mapRect)
            self.scale = quantized(scale, scale: 1_000_000)
            self.cornerRadius = quantized(cornerRadius, scale: 1_000)
        }
    }

    private struct GeometryRectKey: Hashable {
        let minX: Int64
        let minY: Int64
        let width: Int64
        let height: Int64

        init(_ rect: CGRect) {
            minX = quantized(rect.minX, scale: 1_000)
            minY = quantized(rect.minY, scale: 1_000)
            width = quantized(rect.width, scale: 1_000)
            height = quantized(rect.height, scale: 1_000)
        }
    }

    private struct CoordinateSignature: Hashable {
        let count: Int
        let firstLatitude: Int64
        let firstLongitude: Int64
        let middleLatitude: Int64
        let middleLongitude: Int64
        let lastLatitude: Int64
        let lastLongitude: Int64

        init(coordinates: [CLLocationCoordinate2D]) {
            count = coordinates.count
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

        init(dataPoints: [FITDataPoint]) {
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

    private struct FontCacheKey: Hashable {
        let name: String
        let size: Int64

        init(name: String, size: CGFloat) {
            self.name = name
            self.size = quantized(size, scale: 1_000)
        }
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
        let font = cachedFont(name: fontName, size: fontSize) {
            CTFontCreateWithName(fontName as CFString, fontSize, nil)
        }
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

    private func drawTextOverlays(ctx: CGContext, globalPlaybackTime: TimeInterval) -> Bool {
        var drewOverlay = false
        for textOverlay in textOverlays {
            let opacity = textOverlay.opacity(at: globalPlaybackTime)
            if opacity > 0 {
                drawTextOverlay(ctx: ctx, overlay: textOverlay, opacity: opacity)
                drewOverlay = true
            }
        }
        return drewOverlay
    }

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
        cachedFont(name: "TextOverlay:\(overlay.fontFamily):\(overlay.fontWeight.rawValue)", size: size) {
            let fallback = NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.nsFontWeight)
            let nsFont = NSFontManager.shared.font(
                withFamily: overlay.fontFamily,
                traits: [],
                weight: overlay.fontWeight.nsFontManagerWeight,
                size: size
            ) ?? fallback

            return CTFontCreateWithName(nsFont.fontName as CFString, size, nil)
        }
    }

    private func cachedFont(name: String, size: CGFloat, make: () -> CTFont) -> CTFont {
        let key = FontCacheKey(name: name, size: size)
        if let cached = fontCache[key] {
            return cached
        }

        let font = make()
        fontCache[key] = font
        return font
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
        let fontName = "Helvetica"
        let fontSize = 16 * scale
        let font = cachedFont(name: fontName, size: fontSize) {
            CTFontCreateWithName(fontName as CFString, fontSize, nil)
        }
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

enum OverlayMapPlacement: String, Codable {
    case topLeft
    case topRight
}

enum OverlayHorizontalPosition: Codable {
    case left(CGFloat)
    case right(CGFloat)
    case proportion(CGFloat, offset: CGFloat)

    private enum CodingKeys: String, CodingKey {
        case anchor
        case fraction
        case offset
    }

    private enum Anchor: String, Codable {
        case left
        case right
        case proportion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let anchor = try container.decode(Anchor.self, forKey: .anchor)

        switch anchor {
        case .left:
            self = .left(try container.decodeFiniteCGFloat(forKey: .offset, default: 0))
        case .right:
            self = .right(try container.decodeFiniteCGFloat(forKey: .offset, default: 0))
        case .proportion:
            self = .proportion(
                try container.decodeClampedCGFloat(
                    forKey: .fraction,
                    default: 0.5,
                    range: OverlayThemeStyleClamp.positionFraction
                ),
                offset: try container.decodeFiniteCGFloat(forKey: .offset, default: 0)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .left(let offset):
            try container.encode(Anchor.left, forKey: .anchor)
            try container.encode(offset, forKey: .offset)
        case .right(let offset):
            try container.encode(Anchor.right, forKey: .anchor)
            try container.encode(offset, forKey: .offset)
        case .proportion(let fraction, let offset):
            try container.encode(Anchor.proportion, forKey: .anchor)
            try container.encode(fraction, forKey: .fraction)
            try container.encode(offset, forKey: .offset)
        }
    }

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

enum OverlayVerticalPosition: Codable {
    case top(CGFloat)
    case bottom(CGFloat)
    case proportion(CGFloat, offset: CGFloat)

    private enum CodingKeys: String, CodingKey {
        case anchor
        case fraction
        case offset
    }

    private enum Anchor: String, Codable {
        case top
        case bottom
        case proportion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let anchor = try container.decode(Anchor.self, forKey: .anchor)

        switch anchor {
        case .top:
            self = .top(try container.decodeFiniteCGFloat(forKey: .offset, default: 0))
        case .bottom:
            self = .bottom(try container.decodeFiniteCGFloat(forKey: .offset, default: 0))
        case .proportion:
            self = .proportion(
                try container.decodeClampedCGFloat(
                    forKey: .fraction,
                    default: 0.5,
                    range: OverlayThemeStyleClamp.positionFraction
                ),
                offset: try container.decodeFiniteCGFloat(forKey: .offset, default: 0)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .top(let offset):
            try container.encode(Anchor.top, forKey: .anchor)
            try container.encode(offset, forKey: .offset)
        case .bottom(let offset):
            try container.encode(Anchor.bottom, forKey: .anchor)
            try container.encode(offset, forKey: .offset)
        case .proportion(let fraction, let offset):
            try container.encode(Anchor.proportion, forKey: .anchor)
            try container.encode(fraction, forKey: .fraction)
            try container.encode(offset, forKey: .offset)
        }
    }

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

struct OverlayPresetRenderStyle: Codable {
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

private struct OverlayThemeColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
        case alpha
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: CGColor) {
        let nsColor = NSColor(cgColor: color)?.usingColorSpace(.sRGB) ?? .black
        red = Double(nsColor.redComponent)
        green = Double(nsColor.greenComponent)
        blue = Double(nsColor.blueComponent)
        alpha = Double(nsColor.alphaComponent)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
    }

    var cgColor: CGColor {
        let components = [
            clampedCGFloat(red),
            clampedCGFloat(green),
            clampedCGFloat(blue),
            clampedCGFloat(alpha)
        ]
        return CGColor(colorSpace: Self.sRGBColorSpace, components: components)
            ?? CGColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    private func clampedCGFloat(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}

private enum OverlayThemeStyleClamp {
    static let fontSize: ClosedRange<CGFloat> = 8...300
    static let mapRatio: ClosedRange<CGFloat> = 0.05...0.75
    static let panelWidthScale: ClosedRange<CGFloat> = 0.25...3
    static let positionFraction: ClosedRange<CGFloat> = 0...1
}

private func themeFiniteCGFloat(_ value: CGFloat, default defaultValue: CGFloat) -> CGFloat {
    value.isFinite ? value : defaultValue
}

private func themeClampedCGFloat(_ value: CGFloat, to range: ClosedRange<CGFloat>, default defaultValue: CGFloat) -> CGFloat {
    guard value.isFinite else { return defaultValue }
    return min(max(value, range.lowerBound), range.upperBound)
}

private extension KeyedDecodingContainer {
    func decodeFiniteCGFloat(forKey key: Key, default defaultValue: CGFloat) throws -> CGFloat {
        guard let value = try decodeIfPresent(CGFloat.self, forKey: key) else {
            return defaultValue
        }
        return themeFiniteCGFloat(value, default: defaultValue)
    }

    func decodeClampedCGFloat(
        forKey key: Key,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) throws -> CGFloat {
        guard let value = try decodeIfPresent(CGFloat.self, forKey: key) else {
            return defaultValue
        }
        return themeClampedCGFloat(value, to: range, default: defaultValue)
    }
}

extension OverlayPresetRenderStyle {
    private enum CodingKeys: String, CodingKey {
        case accentColor
        case accentRed
        case shadowColor
        case metricsBackgroundColor
        case panelBackgroundColor
        case mapBackgroundColor
        case elevationColor
        case elevationLineColor
        case elevationFillColor
        case trackOutlineColor
        case trackLineColor
        case mapDotColor
        case labelFontSize
        case valueFontSize
        case distanceFontSize
        case leftXPosition
        case leftStartYPosition
        case rightXPosition
        case rightStartYPosition
        case leftMetricAdvance
        case rightDistanceAdvance
        case rightMetricAdvance
        case metricPanelWidthScale
        case distancePanelWidthScale
        case metricsCornerRadius
        case mapWidthRatio
        case mapHeightRatio
        case mapMargin
        case mapCornerRadius
        case mapPlacement
        case profileGap
        case profileBottomPadding
        case profileCornerRadius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = OverlayPreset.defaultPreset.renderStyle

        accentColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .accentColor)?.cgColor ?? accentColor
        accentRed = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .accentRed)?.cgColor ?? accentRed
        shadowColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .shadowColor)?.cgColor ?? shadowColor
        metricsBackgroundColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .metricsBackgroundColor)?.cgColor ?? metricsBackgroundColor
        panelBackgroundColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .panelBackgroundColor)?.cgColor ?? panelBackgroundColor
        mapBackgroundColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .mapBackgroundColor)?.cgColor ?? mapBackgroundColor
        elevationColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .elevationColor)?.cgColor ?? elevationColor
        elevationLineColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .elevationLineColor)?.cgColor ?? elevationLineColor
        elevationFillColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .elevationFillColor)?.cgColor ?? elevationFillColor
        trackOutlineColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .trackOutlineColor)?.cgColor ?? trackOutlineColor
        trackLineColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .trackLineColor)?.cgColor ?? trackLineColor
        mapDotColor = try container.decodeIfPresent(OverlayThemeColor.self, forKey: .mapDotColor)?.cgColor ?? mapDotColor
        labelFontSize = try container.decodeClampedCGFloat(
            forKey: .labelFontSize,
            default: labelFontSize,
            range: OverlayThemeStyleClamp.fontSize
        )
        valueFontSize = try container.decodeClampedCGFloat(
            forKey: .valueFontSize,
            default: valueFontSize,
            range: OverlayThemeStyleClamp.fontSize
        )
        distanceFontSize = try container.decodeClampedCGFloat(
            forKey: .distanceFontSize,
            default: distanceFontSize,
            range: OverlayThemeStyleClamp.fontSize
        )
        leftXPosition = try container.decodeIfPresent(OverlayHorizontalPosition.self, forKey: .leftXPosition) ?? leftXPosition
        leftStartYPosition = try container.decodeIfPresent(OverlayVerticalPosition.self, forKey: .leftStartYPosition) ?? leftStartYPosition
        rightXPosition = try container.decodeIfPresent(OverlayHorizontalPosition.self, forKey: .rightXPosition) ?? rightXPosition
        rightStartYPosition = try container.decodeIfPresent(OverlayVerticalPosition.self, forKey: .rightStartYPosition) ?? rightStartYPosition
        leftMetricAdvance = try container.decodeFiniteCGFloat(forKey: .leftMetricAdvance, default: leftMetricAdvance)
        rightDistanceAdvance = try container.decodeFiniteCGFloat(forKey: .rightDistanceAdvance, default: rightDistanceAdvance)
        rightMetricAdvance = try container.decodeFiniteCGFloat(forKey: .rightMetricAdvance, default: rightMetricAdvance)
        metricPanelWidthScale = try container.decodeClampedCGFloat(
            forKey: .metricPanelWidthScale,
            default: metricPanelWidthScale,
            range: OverlayThemeStyleClamp.panelWidthScale
        )
        distancePanelWidthScale = try container.decodeClampedCGFloat(
            forKey: .distancePanelWidthScale,
            default: distancePanelWidthScale,
            range: OverlayThemeStyleClamp.panelWidthScale
        )
        metricsCornerRadius = try container.decodeFiniteCGFloat(forKey: .metricsCornerRadius, default: metricsCornerRadius)
        mapWidthRatio = try container.decodeClampedCGFloat(
            forKey: .mapWidthRatio,
            default: mapWidthRatio,
            range: OverlayThemeStyleClamp.mapRatio
        )
        mapHeightRatio = try container.decodeClampedCGFloat(
            forKey: .mapHeightRatio,
            default: mapHeightRatio,
            range: OverlayThemeStyleClamp.mapRatio
        )
        mapMargin = try container.decodeFiniteCGFloat(forKey: .mapMargin, default: mapMargin)
        mapCornerRadius = try container.decodeFiniteCGFloat(forKey: .mapCornerRadius, default: mapCornerRadius)
        mapPlacement = try container.decodeIfPresent(OverlayMapPlacement.self, forKey: .mapPlacement) ?? mapPlacement
        profileGap = try container.decodeFiniteCGFloat(forKey: .profileGap, default: profileGap)
        profileBottomPadding = try container.decodeFiniteCGFloat(forKey: .profileBottomPadding, default: profileBottomPadding)
        profileCornerRadius = try container.decodeFiniteCGFloat(forKey: .profileCornerRadius, default: profileCornerRadius)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(OverlayThemeColor(accentColor), forKey: .accentColor)
        try container.encode(OverlayThemeColor(accentRed), forKey: .accentRed)
        try container.encode(OverlayThemeColor(shadowColor), forKey: .shadowColor)
        try container.encode(OverlayThemeColor(metricsBackgroundColor), forKey: .metricsBackgroundColor)
        try container.encode(OverlayThemeColor(panelBackgroundColor), forKey: .panelBackgroundColor)
        try container.encode(OverlayThemeColor(mapBackgroundColor), forKey: .mapBackgroundColor)
        try container.encode(OverlayThemeColor(elevationColor), forKey: .elevationColor)
        try container.encode(OverlayThemeColor(elevationLineColor), forKey: .elevationLineColor)
        try container.encode(OverlayThemeColor(elevationFillColor), forKey: .elevationFillColor)
        try container.encode(OverlayThemeColor(trackOutlineColor), forKey: .trackOutlineColor)
        try container.encode(OverlayThemeColor(trackLineColor), forKey: .trackLineColor)
        try container.encode(OverlayThemeColor(mapDotColor), forKey: .mapDotColor)
        try container.encode(labelFontSize, forKey: .labelFontSize)
        try container.encode(valueFontSize, forKey: .valueFontSize)
        try container.encode(distanceFontSize, forKey: .distanceFontSize)
        try container.encode(leftXPosition, forKey: .leftXPosition)
        try container.encode(leftStartYPosition, forKey: .leftStartYPosition)
        try container.encode(rightXPosition, forKey: .rightXPosition)
        try container.encode(rightStartYPosition, forKey: .rightStartYPosition)
        try container.encode(leftMetricAdvance, forKey: .leftMetricAdvance)
        try container.encode(rightDistanceAdvance, forKey: .rightDistanceAdvance)
        try container.encode(rightMetricAdvance, forKey: .rightMetricAdvance)
        try container.encode(metricPanelWidthScale, forKey: .metricPanelWidthScale)
        try container.encode(distancePanelWidthScale, forKey: .distancePanelWidthScale)
        try container.encode(metricsCornerRadius, forKey: .metricsCornerRadius)
        try container.encode(mapWidthRatio, forKey: .mapWidthRatio)
        try container.encode(mapHeightRatio, forKey: .mapHeightRatio)
        try container.encode(mapMargin, forKey: .mapMargin)
        try container.encode(mapCornerRadius, forKey: .mapCornerRadius)
        try container.encode(mapPlacement, forKey: .mapPlacement)
        try container.encode(profileGap, forKey: .profileGap)
        try container.encode(profileBottomPadding, forKey: .profileBottomPadding)
        try container.encode(profileCornerRadius, forKey: .profileCornerRadius)
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
