import AppKit
import SwiftUI
import XCTest

final class PreviewOverlayLayoutTests: XCTestCase {
    @MainActor
    func testMultilineTitleSurvivesLetterboxingAndResizing() throws {
        // The first case cuts through the final line with clip-after-offset.
        let cases: [(CGSize, CGRect)] = [
            (CGSize(width: 960, height: 870), CGRect(x: 0, y: 165, width: 960, height: 540)),
            (CGSize(width: 640, height: 700), CGRect(x: 0, y: 170, width: 640, height: 360)),
            (CGSize(width: 1200, height: 540), CGRect(x: 120, y: 0, width: 960, height: 540)),
            (CGSize(width: 480, height: 270), CGRect(x: 0, y: 0, width: 480, height: 270))
        ]
        for text in ["Spartan Race Super\nSusono, Japan\n2026", "Spartan Race Super\nSusono, Japan\n2026\nFinish"] {
            let overlay = TextOverlay(text: text, startTime: 0, duration: 10, fontSize: 165)
            for (container, rect) in cases {
                let layer = LiveTextOverlayLayer(
                    overlays: [overlay], playbackTime: 1, size: rect.size, scale: rect.width / 1920
                )
                let local = try render(layer, size: rect.size)
                let placed = try render(
                    Color.clear.overlay(alignment: .topLeading) {
                        layer.modifier(PreviewOverlayLayout(videoRect: rect))
                    }, size: container
                )
                let cropped = try XCTUnwrap(placed.cropping(to: rect))
                XCTAssertTrue(try pixels(cropped) == pixels(local), "Title was clipped at \(rect)")
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
                        XCTAssertEqual(previewBounds.rows, exportBounds.rows)
                        XCTAssertEqual(previewBounds.columns, exportBounds.columns)
                    }
                }
            }
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
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
