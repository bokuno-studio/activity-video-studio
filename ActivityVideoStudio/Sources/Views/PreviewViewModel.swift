import Foundation
import AVFoundation
import Combine
import CoreGraphics
import CoreLocation

/// ViewModel for the preview screen. Manages video playback, FIT sync, and overlay.
@MainActor
final class PreviewViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var overlayImage: CGImage?
    @Published var fitLoaded = false
    @Published var videoLoaded = false
    @Published var syncOffset: Double = 0
    @Published var showSettings = false
    @Published var showExport = false
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var trackCoordinates: [CLLocationCoordinate2D] = []
    @Published var statusMessage: String?

    let player = AVPlayer()
    let overlaySettings = OverlaySettings()

    private(set) var timeSync: TimeSync?
    private var overlayRenderer: OverlayRenderer?
    private var timeObserver: Any?
    private var fitDataPoints: [FITDataPoint] = []
    private(set) var videoURLs: [URL] = []
    private var videoMetadatas: [VideoMetadata] = []

    init() {
        setupTimeObserver()
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }

    // MARK: - File loading

    func loadFITFile(url: URL) {
        do {
            let parser = FITParser()
            fitDataPoints = try parser.parse(url: url)
            fitLoaded = !fitDataPoints.isEmpty

            // Extract track coordinates
            trackCoordinates = fitDataPoints.compactMap { $0.coordinate }

            setupTimeSync()
            statusMessage = "FIT: \(fitDataPoints.count) データポイント読み込み完了"
        } catch {
            statusMessage = "FIT 読み込みエラー: \(error.localizedDescription)"
        }
    }

    func loadVideo(url: URL) async {
        let reader = VideoMetadataReader()
        do {
            let metadata = try await reader.read(url: url)
            videoURLs.append(url)
            videoMetadatas.append(metadata)

            // Use first video for preview
            if videoURLs.count == 1 {
                let item = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: item)
                duration = metadata.duration

                let tracks = try await AVURLAsset(url: url).load(.tracks)
                if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                    let size = try await videoTrack.load(.naturalSize)
                    overlayRenderer = OverlayRenderer(videoSize: size, settings: overlaySettings)
                    overlayRenderer?.allDataPoints = fitDataPoints
                }
            }

            videoLoaded = true

            if fitLoaded, metadata.creationDate != nil {
                timeSync?.addVideo(metadata, offsetSeconds: syncOffset)
            }

            statusMessage = "動画読み込み完了 (\(videoURLs.count)本)"
        } catch {
            statusMessage = "動画読み込みエラー: \(error.localizedDescription)"
        }
    }

    // MARK: - Playback controls

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func updateSyncOffset(_ offset: Double) {
        syncOffset = offset
        if let timeSync = timeSync, !timeSync.segments.isEmpty {
            timeSync.updateOffset(segmentIndex: 0, offsetSeconds: offset)
        }
        updateOverlay()
    }

    // MARK: - Export

    func makeExportViewModel() -> ExportViewModel {
        let vm = ExportViewModel()
        vm.videoURLs = videoURLs
        vm.timeSync = timeSync
        vm.overlayRenderer = overlayRenderer
        vm.onDismiss = { [weak self] in
            self?.showExport = false
        }
        return vm
    }

    // MARK: - Private

    private func setupTimeSync() {
        timeSync = TimeSync(dataPoints: fitDataPoints)
        // Re-add existing videos
        for (i, metadata) in videoMetadatas.enumerated() {
            if metadata.creationDate != nil {
                timeSync?.addVideo(metadata, offsetSeconds: i == 0 ? syncOffset : 0)
            }
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = CMTimeGetSeconds(time)
                self.updateOverlay()
            }
        }
    }

    private func updateOverlay() {
        guard let timeSync = timeSync,
              let renderer = overlayRenderer,
              !timeSync.segments.isEmpty else {
            overlayImage = nil
            currentCoordinate = nil
            return
        }

        let segmentIndex = 0
        if let dataPoint = timeSync.dataPoint(segmentIndex: segmentIndex, playbackTime: currentTime),
           let elapsed = timeSync.elapsedTime(segmentIndex: segmentIndex, playbackTime: currentTime) {
            overlayImage = renderer.render(dataPoint: dataPoint, elapsedTime: elapsed)
            currentCoordinate = dataPoint.coordinate
        }
    }
}
