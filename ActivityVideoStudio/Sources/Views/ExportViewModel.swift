import Foundation
import AppKit

/// ViewModel for the export flow.
@MainActor
final class ExportViewModel: ObservableObject {

    enum Resolution: String, CaseIterable {
        case r720p, r1080p, r4k

        var width: Int {
            switch self {
            case .r720p: return 1280
            case .r1080p: return 1920
            case .r4k: return 3840
            }
        }

        var height: Int {
            switch self {
            case .r720p: return 720
            case .r1080p: return 1080
            case .r4k: return 2160
            }
        }
    }

    enum Quality: String, CaseIterable {
        case low, medium, high

        var bitRate: Int {
            switch self {
            case .low: return 5_000_000
            case .medium: return 10_000_000
            case .high: return 20_000_000
            }
        }
    }

    @Published var resolution: Resolution = .r1080p
    @Published var quality: Quality = .high
    @Published var concatenateVideos = true
    @Published var isExporting = false
    @Published var exportComplete = false
    @Published var progress: Double = 0
    @Published var estimatedRemaining: TimeInterval?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var outputURL: URL?

    var videoURLs: [URL] = []
    var timeSync: TimeSync?
    var overlayRenderer: OverlayRenderer?
    var onDismiss: (() -> Void)?

    var videoCount: Int { videoURLs.count }
    var canExport: Bool { !videoURLs.isEmpty && timeSync != nil }

    private var exporter: VideoExporter?

    func startExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "activity_overlay.mp4"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        outputURL = url
        isExporting = true
        exportComplete = false
        errorMessage = nil
        statusMessage = nil
        progress = 0

        let exporter = VideoExporter()
        self.exporter = exporter

        let config = VideoExporter.ExportConfig(
            outputURL: url,
            width: resolution.width,
            height: resolution.height,
            bitRate: quality.bitRate
        )

        guard let timeSync = timeSync, let renderer = overlayRenderer else { return }

        Task {
            do {
                if concatenateVideos && videoURLs.count > 1 {
                    try await exporter.exportConcatenated(
                        videoURLs: videoURLs,
                        timeSync: timeSync,
                        overlayRenderer: renderer,
                        config: config,
                        onStatus: { [weak self] msg in
                            Task { @MainActor in
                                self?.statusMessage = msg
                            }
                        },
                        progress: { [weak self] fraction, remaining in
                            Task { @MainActor in
                                self?.progress = fraction
                                self?.estimatedRemaining = remaining
                            }
                        }
                    )
                } else {
                    try await exporter.exportSingleVideo(
                        videoURL: videoURLs[0],
                        timeSync: timeSync,
                        segmentIndex: 0,
                        overlayRenderer: renderer,
                        config: config
                    ) { [weak self] fraction, remaining in
                        Task { @MainActor in
                            self?.progress = fraction
                            self?.estimatedRemaining = remaining
                        }
                    }
                }
                isExporting = false
                exportComplete = true
            } catch {
                isExporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    func dismiss() {
        onDismiss?()
    }
}
