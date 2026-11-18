import AppKit
import SwiftUI
import XCTest
import CoreLocation

final class PreviewOverlayLayoutTests: XCTestCase {
    @MainActor
    func testMultilineTitleSurvivesLetterboxingAndResizing() throws {
        // Exercise both vertical and horizontal letterboxing, including asymmetric placement.
        let cases: [(CGSize, CGRect)] = [
            (CGSize(width: 960, height: 870), CGRect(x: 0, y: 165, width: 960, height: 540)),
            (CGSize(width: 640, height: 700), CGRect(x: 0, y: 170, width: 640, height: 360)),
            (CGSize(width: 1200, height: 540), CGRect(x: 120, y: 0, width: 960, height: 540)),
            (CGSize(width: 960, height: 870), CGRect(x: 0, y: 91, width: 960, height: 540)),
            (CGSize(width: 480, height: 270), CGRect(x: 0, y: 0, width: 480, height: 270))
        ]
        for text in ["Spartan Race Super\nSusono, Japan\n2026", "Spartan Race Super\nSusono, Japan\n2026\nFinish"] {
            let overlay = TextOverlay(text: text, startTime: 0, duration: 10, fontSize: 165)
            for (container, rect) in cases {
                let layer = LiveTextOverlayLayer(
                    overlays: [overlay], playbackTime: 1, size: rect.size, scale: rect.width / 1920
                )
                for backingScale: CGFloat in [1, 2] {
                    let local = try render(layer, size: rect.size, backingScale: backingScale)
                    let glyphRows = try occupiedAxes(local, alphaThreshold: 200).rows
                    XCTAssertEqual(occupiedRuns(glyphRows), text.components(separatedBy: "\n").count)
                    let placed = try render(
                        Color.clear.overlay(alignment: .topLeading) {
                            layer.modifier(PreviewOverlayLayout(videoRect: rect))
                        }, size: container, backingScale: backingScale
                    )
                    let cropped = try XCTUnwrap(placed.cropping(to: rect.applying(CGAffineTransform(scaleX: backingScale, y: backingScale))))
                    XCTAssertTrue(try pixels(cropped) == pixels(local), "Title was clipped at \(rect)")
                }
            }
        }
    }

    @MainActor
    func testClipMovesWithVideoAndDoesNotLeakIntoLetterbox() throws {
        let rect = CGRect(x: 40, y: 80, width: 160, height: 90)
        let image = try render(Color.clear.overlay(alignment: .topLeading) {
            Color.red.padding(-50).modifier(PreviewOverlayLayout(videoRect: rect))
        }, size: CGSize(width: 240, height: 250))
        let data = try pixels(image)
        for y in 0..<image.height {
            for x in 0..<image.width {
                XCTAssertEqual(data[(y * image.width + x) * 4 + 3],
                               rect.contains(CGPoint(x: x, y: y)) ? 255 : 0)
            }
        }
    }

    @MainActor
    func testPreviewTextAndBandBoundsMatchExport() throws {
        for width: CGFloat in [480, 640, 960, 1920] {
            let size = CGSize(width: width, height: width * 9 / 16)
            for text in ["Spartan Race Super\nSusono, Japan\n2026", "Race\nSusono\nJapan\n2026"] {
                for anchor in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.45, y: 0.6)] {
                    let overlay = TextOverlay(text: text, startTime: 0, duration: 10, fontSize: 165,
                                              relativeX: anchor.x, relativeY: anchor.y)
                    let preview = try render(LiveTextOverlayLayer(
                        overlays: [overlay], playbackTime: 1, size: size, scale: width / 1920
                    ), size: size)
                    let settings = OverlaySettings()
                    settings.overlayOpacity = 1
                    let exporter = OverlayRenderer(videoSize: size, settings: settings)
                    exporter.textOverlays = [overlay]
                    let exported = try XCTUnwrap(exporter.renderTextOverlaysOnly(globalPlaybackTime: 1))
                    // Compare each occupied row/column, both for the band and for the
                    // opaque glyphs. This catches lost final lines and placement/size drift.
                    for threshold: UInt8 in [1, 200] {
                        let previewBounds = try occupiedAxes(preview, alphaThreshold: threshold)
                        let exportBounds = try occupiedAxes(exported, alphaThreshold: threshold)
                        // SwiftUI image compositing and the export bitmap can round
                        // antialiased edges to adjacent pixels. Allow one pixel in
                        // BOTH directions for every occupied row/column, not just
                        // the outer bounds; missing lines and large shifts still fail.
                        XCTAssertTrue(axesMatch(previewBounds.rows, exportBounds.rows),
                                      "Rows differ: width=\(width), anchor=\(anchor), alpha=\(threshold)")
                        XCTAssertTrue(axesMatch(previewBounds.columns, exportBounds.columns),
                                      "Columns differ: width=\(width), anchor=\(anchor), alpha=\(threshold)")
                    }
                }
            }
        }
    }

    func testAxisComparisonRejectsMissingLinesAndPositionDrift() {
        let rows = Set(Array(10...30) + Array(50...70) + Array(90...110))
        XCTAssertTrue(axesMatch(rows, Set(rows.map { $0 + 1 })))
        XCTAssertFalse(axesMatch(rows, Set(rows.map { $0 + 2 })))
        XCTAssertFalse(axesMatch(rows, Set(rows.filter { $0 < 90 })))
        XCTAssertFalse(axesMatch(rows, Set(rows.filter { $0 < 105 })))
        XCTAssertFalse(axesMatch([], []))
    }

    private func axesMatch(_ lhs: Set<Int>, _ rhs: Set<Int>) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        func covered(_ source: Set<Int>, by target: Set<Int>) -> Bool {
            source.allSatisfy { target.contains($0) || target.contains($0 - 1) || target.contains($0 + 1) }
        }
        return covered(lhs, by: rhs) && covered(rhs, by: lhs)
    }

    private func occupiedRuns(_ axis: Set<Int>) -> Int {
        axis.filter { !axis.contains($0 - 1) }.count
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize, backingScale: CGFloat = 1) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .environment(\.displayScale, backingScale)
            .frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = backingScale
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func occupiedAxes(_ image: CGImage, alphaThreshold: UInt8) throws -> (rows: Set<Int>, columns: Set<Int>) {
        let data = try pixels(image)
        var rows = Set<Int>()
        var columns = Set<Int>()
        for y in 0..<image.height {
            for x in 0..<image.width where data[(y * image.width + x) * 4 + 3] >= alphaThreshold {
                rows.insert(y)
                columns.insert(x)
            }
        }
        return (rows, columns)
    }
}

final class OverlayDesignLayoutTests: XCTestCase {
    func testFeaturedDesignsUseTheirLayouts() {
        XCTAssertEqual(OverlayPreset.featured, [.broadcast, .minimal, .cards, .defaultPreset])
        XCTAssertEqual(OverlayPreset.broadcast.renderStyle.layout, .broadcast)
        XCTAssertEqual(OverlayPreset.minimal.renderStyle.layout, .minimal)
        XCTAssertEqual(OverlayPreset.cards.renderStyle.layout, .cards)
        XCTAssertEqual(OverlayPreset.defaultPreset.renderStyle.layout, .classic)
        XCTAssertEqual(OverlayPreset.compact.renderStyle.layout, .classic)
    }

    func testThemeFileKeepsLayoutAndOldFilesStayClassic() throws {
        let theme = OverlayTheme(id: "user.cards", displayName: "カード", style: OverlayPreset.cards.renderStyle)
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(OverlayTheme.self, from: data)
        XCTAssertEqual(decoded.style.layout, .cards)

        let legacy = Data(#"{"schemaVersion":1,"id":"user.old","name":"old","style":{"labelFontSize":30}}"#.utf8)
        let legacyTheme = try JSONDecoder().decode(OverlayTheme.self, from: legacy)
        XCTAssertEqual(legacyTheme.style.layout, .classic)
    }

    /// Every card design, with every item turned on, must stay inside the
    /// frame at 720p / 1080p / 4K (nothing touches the outer edge band).
    func testCardDesignsStayInsideFrameWithAllItemsShown() throws {
        let points = Self.makeActivity()
        let current = points[points.count / 2]
        for preset in [OverlayPreset.broadcast, .minimal, .cards] {
            for size in [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160)] {
                let settings = OverlaySettings()
                settings.overlayPreset = preset
                let renderer = OverlayRenderer(videoSize: size, settings: settings)
                renderer.allDataPoints = points
                renderer.trackSegments = [points.compactMap(\.coordinate)]
                let image = try XCTUnwrap(renderer.render(
                    dataPoint: current,
                    elapsedTime: 6_875,
                    activityTime: current.timestamp
                ), "\(preset) \(size)")

                let alpha = try alphaChannel(image)
                let band = Int((12 * size.width / 1920).rounded(.up))
                var drawn = 0
                var onEdge = 0
                for y in 0..<image.height {
                    for x in 0..<image.width where alpha[y * image.width + x] > 0 {
                        drawn += 1
                        if x < band || y < band || x >= image.width - band || y >= image.height - band {
                            onEdge += 1
                        }
                    }
                }
                XCTAssertGreaterThan(drawn, image.width * image.height / 100, "\(preset) \(size) draws almost nothing")
                XCTAssertEqual(onEdge, 0, "\(preset) \(size) reaches the frame edge")
            }
        }
    }

    private func alphaChannel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { data[$0 * 4 + 3] }
    }

    private static func makeActivity() -> [FITDataPoint] {
        let start = Date(timeIntervalSince1970: 1_763_000_000)
        return (0..<1_200).map { i in
            let t = Double(i)
            return FITDataPoint(
                timestamp: start.addingTimeInterval(t * 10),
                coordinate: CLLocationCoordinate2D(latitude: 36.4 + 0.0004 * t, longitude: 140.5 + 0.0002 * sin(t / 40)),
                heartRate: 158,
                speed: 2.6,
                altitude: 20 + 15 * sin(t / 60),
                cadence: 85,
                distance: t * 26,
                grade: 1.2,
                temperature: 12,
                coreTemperature: 38.4,
                skinTemperature: nil
            )
        }
    }
}
