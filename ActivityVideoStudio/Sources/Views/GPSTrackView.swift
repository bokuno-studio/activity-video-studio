import SwiftUI
import CoreLocation

/// Lightweight GPS track mini-map for the preview screen.
/// Intentionally mirrors `OverlayRenderer.drawGPSTrack` so preview and export match
/// pixel-for-pixel (aside from resolution). No tile loading, no network access.
struct GPSTrackView: View {
    let trackCoordinates: [CLLocationCoordinate2D]
    let currentCoordinate: CLLocationCoordinate2D?

    var body: some View {
        Canvas { context, size in
            guard trackCoordinates.count >= 2 else { return }

            // Bounding box over the track.
            let lats = trackCoordinates.map { $0.latitude }
            let lons = trackCoordinates.map { $0.longitude }
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }

            let latRange = maxLat - minLat
            let lonRange = maxLon - minLon
            guard latRange > 0 || lonRange > 0 else { return }

            // Preserve aspect ratio inside the canvas with an inset.
            let inset: CGFloat = 10
            let drawRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                .insetBy(dx: inset, dy: inset)

            let safeLatRange = max(latRange, 1e-9)
            let safeLonRange = max(lonRange, 1e-9)
            let sx = drawRect.width / CGFloat(safeLonRange)
            let sy = drawRect.height / CGFloat(safeLatRange)
            let fitScale = min(sx, sy)
            let usedWidth = CGFloat(safeLonRange) * fitScale
            let usedHeight = CGFloat(safeLatRange) * fitScale
            let originX = drawRect.midX - usedWidth / 2
            let originY = drawRect.midY - usedHeight / 2

            // SwiftUI Canvas has y=top-down, so latitudes (north=up) map by inverting.
            func project(_ coord: CLLocationCoordinate2D) -> CGPoint {
                let x = originX + CGFloat(coord.longitude - minLon) * fitScale
                let y = originY + CGFloat(maxLat - coord.latitude) * fitScale
                return CGPoint(x: x, y: y)
            }

            // Polyline
            var path = Path()
            path.move(to: project(trackCoordinates[0]))
            for coord in trackCoordinates.dropFirst() {
                path.addLine(to: project(coord))
            }
            context.stroke(path, with: .color(.black.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(Color(red: 0.0, green: 0.88, blue: 0.98)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            // Current position dot
            if let current = currentCoordinate {
                let p = project(current)
                let dot: CGFloat = 12
                let dotRect = CGRect(x: p.x - dot/2, y: p.y - dot/2, width: dot, height: dot)
                context.fill(Path(ellipseIn: dotRect),
                             with: .color(Color(red: 1.0, green: 0.2, blue: 0.15)))
                context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 2.5)
            }
        }
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
