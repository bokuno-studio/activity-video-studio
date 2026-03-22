import SwiftUI
import CoreLocation

/// GPS track overlaid on OpenTopoMap tiles. Copyright-free for YouTube with attribution.
/// Attribution: "© OpenStreetMap contributors, © SRTM, Map style: © OpenTopoMap (CC-BY-SA)"
struct GPSTrackView: View {
    let trackCoordinates: [CLLocationCoordinate2D]
    let currentCoordinate: CLLocationCoordinate2D?

    @StateObject private var tileLoader = TileLoader()

    private let zoomLevel = 14

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard trackCoordinates.count >= 2 else { return }

                let lats = trackCoordinates.map { $0.latitude }
                let lons = trackCoordinates.map { $0.longitude }
                guard let minLat = lats.min(), let maxLat = lats.max(),
                      let minLon = lons.min(), let maxLon = lons.max() else { return }

                let centerLat = (minLat + maxLat) / 2
                let centerLon = (minLon + maxLon) / 2

                // Calculate tile range needed
                let z = zoomLevel
                let centerTileX = lonToTileX(centerLon, z: z)
                let centerTileY = latToTileY(centerLat, z: z)

                let tilesAcross = Int(ceil(size.width / 256)) + 2
                let tilesDown = Int(ceil(size.height / 256)) + 2
                let startTX = Int(centerTileX) - tilesAcross / 2
                let startTY = Int(centerTileY) - tilesDown / 2

                // Pixel offset for fractional tile position
                let centerPixelX = (centerTileX - Double(Int(centerTileX))) * 256
                let centerPixelY = (centerTileY - Double(Int(centerTileY))) * 256
                let offsetX = size.width / 2 - CGFloat(Int(centerTileX) - startTX) * 256 - centerPixelX
                let offsetY = size.height / 2 - CGFloat(Int(centerTileY) - startTY) * 256 - centerPixelY

                // Draw tiles
                for ty in startTY..<(startTY + tilesDown) {
                    for tx in startTX..<(startTX + tilesAcross) {
                        let key = TileKey(x: tx, y: ty, z: z)
                        if let img = tileLoader.tiles[key] {
                            let tileDrawX = offsetX + CGFloat(tx - startTX) * CGFloat(256)
                            let tileDrawY = offsetY + CGFloat(ty - startTY) * CGFloat(256)
                            context.draw(img, in: CGRect(x: tileDrawX, y: tileDrawY, width: CGFloat(256), height: CGFloat(256)))
                        }
                    }
                }

                // Helper: coordinate to pixel position on canvas
                func toPixel(_ coord: CLLocationCoordinate2D) -> CGPoint {
                    let tileX = lonToTileX(coord.longitude, z: z)
                    let tileY = latToTileY(coord.latitude, z: z)
                    let px = offsetX + CGFloat(tileX - Double(startTX)) * 256
                    let py = offsetY + CGFloat(tileY - Double(startTY)) * 256
                    return CGPoint(x: px, y: py)
                }

                // Draw GPS track
                var path = Path()
                let first = toPixel(trackCoordinates[0])
                path.move(to: first)
                for coord in trackCoordinates.dropFirst() {
                    path.addLine(to: toPixel(coord))
                }
                // Track outline for visibility
                context.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 5)
                context.stroke(path, with: .color(.blue), lineWidth: 3)

                // Current position
                if let current = currentCoordinate {
                    let p = toPixel(current)
                    let dotSize: CGFloat = 12
                    let dotRect = CGRect(x: p.x - dotSize/2, y: p.y - dotSize/2, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: dotRect), with: .color(.red))
                    context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 2.5)
                }
            }
            .onAppear { loadTiles(size: geo.size) }
            .onChange(of: trackCoordinates.count) { loadTiles(size: geo.size) }
        }
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            Text("© OpenTopoMap")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .padding(3)
        }
    }

    private func loadTiles(size: CGSize) {
        guard trackCoordinates.count >= 2 else { return }
        let lats = trackCoordinates.map { $0.latitude }
        let lons = trackCoordinates.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let z = zoomLevel

        let centerTileX = Int(lonToTileX(centerLon, z: z))
        let centerTileY = Int(latToTileY(centerLat, z: z))

        let tilesAcross = Int(ceil(size.width / 256)) + 2
        let tilesDown = Int(ceil(size.height / 256)) + 2
        let startTX = centerTileX - tilesAcross / 2
        let startTY = centerTileY - tilesDown / 2

        for ty in startTY..<(startTY + tilesDown) {
            for tx in startTX..<(startTX + tilesAcross) {
                tileLoader.loadTile(x: tx, y: ty, z: z)
            }
        }
    }

    // MARK: - Tile math (Slippy Map)

    private func lonToTileX(_ lon: Double, z: Int) -> Double {
        (lon + 180.0) / 360.0 * Double(1 << z)
    }

    private func latToTileY(_ lat: Double, z: Int) -> Double {
        let latRad = lat * .pi / 180.0
        return (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * Double(1 << z)
    }
}

// MARK: - Tile Loading

struct TileKey: Hashable {
    let x: Int, y: Int, z: Int
}

@MainActor
class TileLoader: ObservableObject {
    @Published var tiles: [TileKey: Image] = [:]
    private var loading: Set<TileKey> = []
    private static let cache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 200_000_000)

    func loadTile(x: Int, y: Int, z: Int) {
        let key = TileKey(x: x, y: y, z: z)
        guard tiles[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)

        let subdomain = ["a", "b", "c"][(x + y) % 3]
        let urlStr = "https://\(subdomain).tile.opentopomap.org/\(z)/\(x)/\(y).png"
        guard let url = URL(string: urlStr) else { return }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let nsImage = NSImage(data: data) {
                    tiles[key] = Image(nsImage: nsImage)
                }
            } catch {
                // Silently fail - tile just won't show
            }
            loading.remove(key)
        }
    }
}
