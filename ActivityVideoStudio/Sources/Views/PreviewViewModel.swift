import Foundation
import AVFoundation
import Combine
import CoreGraphics
import CoreLocation

/// Append a line to /tmp/avs_export.log and stderr. Nonisolated so @Sendable closures can call it.
func autoExportLog(_ msg: String) {
    let line = msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")
    if let fh = try? FileHandle(forWritingTo: logURL) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    }
    FileHandle.standardError.write(data)
}

/// ViewModel for the preview screen. Manages video playback, FIT sync, and overlay.
@MainActor
final class PreviewViewModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var isSeeking = false
    @Published var duration: TimeInterval = 0
    @Published var overlayImage: CGImage?
    @Published var fitLoaded = false
    @Published var videoLoaded = false
    @Published var syncOffset: Double = 0
    @Published var showSettings = false
    @Published var showExport = false
    @Published var showYouTube = false
    @Published var showFileList = false
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var trackCoordinates: [CLLocationCoordinate2D] = []
    @Published var statusMessage: String?
    @Published var textOverlays: [TextOverlay] = []
    @Published var trimSettings: [TrimSettings] = []
    @Published var playbackRate: Float = 1.0
    @Published var chapterMarkers: [ChapterMarker] = []
    @Published var exportPreviewImage: CGImage?

    let player = AVPlayer()
    let overlaySettings = OverlaySettings()

    private(set) var timeSync: TimeSync?
    private var overlayRenderer: OverlayRenderer?
    private var timeObserver: Any?
    private(set) var fitDataPoints: [FITDataPoint] = []
    private(set) var fitURL: URL?
    private(set) var videoURLs: [URL] = []
    private(set) var videoMetadatas: [VideoMetadata] = []

    /// Durations of individual video segments, for mapping playback time to segment.
    private var segmentDurations: [TimeInterval] = []

    init() {
        setupTimeObserver()
        #if DEBUG
        Task { await autoLoadDebugFiles() }
        #endif
    }

    #if DEBUG
    /// Auto-load files from command-line arguments or environment for faster debugging.
    /// Usage: --fit /path/to.fit --video /path/to.mp4 --video /path/to2.mp4
    ///        --trim-start 0 --trim-end 0 --text "Overlay text"
    ///        --export-to /path/output.mp4   (optional: auto-start export without save panel)
    private func autoLoadDebugFiles() async {
        let args = ProcessInfo.processInfo.arguments
        var fitPath: String?
        var videoPaths: [String] = []
        var exportPath: String?
        var trimStart: TimeInterval = 0
        var trimEnd: TimeInterval = 0
        var overlayText: String?
        var overlayPos: TextOverlay.Position = .center
        var overlayFontSize: CGFloat = 48

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--fit":
                if i + 1 < args.count { fitPath = args[i + 1]; i += 1 }
            case "--video":
                if i + 1 < args.count { videoPaths.append(args[i + 1]); i += 1 }
            case "--trim-start":
                if i + 1 < args.count, let value = TimeInterval(args[i + 1]) {
                    trimStart = value
                    i += 1
                }
            case "--trim-end":
                if i + 1 < args.count, let value = TimeInterval(args[i + 1]) {
                    trimEnd = value
                    i += 1
                }
            case "--text":
                if i + 1 < args.count { overlayText = args[i + 1]; i += 1 }
            case "--text-pos":
                if i + 1 < args.count {
                    switch args[i + 1] {
                    case "topCenter": overlayPos = .topCenter
                    case "center": overlayPos = .center
                    case "bottomCenter": overlayPos = .bottomCenter
                    default: break
                    }
                    i += 1
                }
            case "--text-size":
                if i + 1 < args.count, let value = Double(args[i + 1]) {
                    overlayFontSize = CGFloat(value)
                    i += 1
                }
            case "--export-to":
                if i + 1 < args.count { exportPath = args[i + 1]; i += 1 }
            default: break
            }
            i += 1
        }

        if let fp = fitPath {
            loadFITFile(url: URL(fileURLWithPath: fp))
        }
        for vp in videoPaths {
            await loadVideo(url: URL(fileURLWithPath: vp))
        }

        let cliTrimSettings = TrimSettings(startTrim: trimStart, endTrim: trimEnd)
        if trimSettings.isEmpty {
            trimSettings = [cliTrimSettings]
        } else {
            trimSettings = trimSettings.indices.map { _ in cliTrimSettings }
        }

        if let overlayText, !overlayText.isEmpty {
            var overlay = TextOverlay(text: overlayText, startTime: 0, duration: 9999)
            overlay.position = overlayPos
            overlay.fontSize = overlayFontSize
            textOverlays = [overlay]
            overlayRenderer?.textOverlays = [overlay]
        }

        if let ep = exportPath {
            await autoExport(to: URL(fileURLWithPath: ep))
        }
    }

    /// Headless export for CLI testing — bypasses NSSavePanel.
    private func autoExport(to outputURL: URL) async {
        let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")
        // Truncate log on start
        try? "".write(to: logURL, atomically: true, encoding: .utf8)

        guard videoLoaded, fitLoaded,
              let timeSync = timeSync,
              let renderer = overlayRenderer else {
            autoExportLog("[AutoExport] Not ready: videoLoaded=\(videoLoaded) fitLoaded=\(fitLoaded)")
            return
        }

        autoExportLog("[AutoExport] Starting export to \(outputURL.path)")
        let exporter = VideoExporter()
        let config = VideoExporter.ExportConfig(outputURL: outputURL)
        do {
            if videoURLs.count > 1 {
                try await exporter.exportConcatenated(
                    videoURLs: videoURLs,
                    trimSettings: trimSettings,
                    timeSync: timeSync,
                    overlayRenderer: renderer,
                    config: config,
                    onStatus: { autoExportLog("[AutoExport] \($0)") },
                    progress: { fraction, _ in
                        autoExportLog("[AutoExport] progress: \(Int(fraction * 100))%")
                    }
                )
            } else {
                try await exporter.exportSingleVideo(
                    videoURL: videoURLs[0],
                    timeSync: timeSync,
                    segmentIndex: 0,
                    trimSettings: trimSettings.first ?? TrimSettings(),
                    overlayRenderer: renderer,
                    config: config,
                    progress: { fraction, _ in
                        autoExportLog("[AutoExport] progress: \(Int(fraction * 100))%")
                    }
                )
            }
            autoExportLog("[AutoExport] DONE ✓ \(outputURL.path)")
        } catch {
            autoExportLog("[AutoExport] FAILED: \(error.localizedDescription)")
        }
    }
    #endif

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }

    // MARK: - File loading

    func loadFITFile(url: URL) {
        do {
            let parser = FITParser()
            let result = try parser.parse(url: url)
            fitDataPoints = result.dataPoints
            fitLoaded = !fitDataPoints.isEmpty
            fitURL = url

            // Apply HR zones from FIT
            if let zoneConfig = result.hrZoneConfig {
                overlaySettings.z1Max = zoneConfig.z1Max
                overlaySettings.z2Max = zoneConfig.z2Max
                overlaySettings.z3Max = zoneConfig.z3Max
                overlaySettings.z4Max = zoneConfig.z4Max
                statusMessage = "FIT: \(fitDataPoints.count) データポイント, HR Zone: max \(zoneConfig.maxHeartRate)bpm"
            }

            trackCoordinates = fitDataPoints.compactMap { $0.coordinate }

            setupTimeSync()

            // Update renderer if already exists
            if let renderer = overlayRenderer {
                renderer.allDataPoints = fitDataPoints
                renderer.trackCoordinates = trackCoordinates
                renderer.buildElevationGainCache()
            }

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

            trimSettings.append(TrimSettings())

            // Sort all videos by creationDate
            sortVideosByCreationDate()

            videoLoaded = true

            // Rebuild timeSync with sorted order
            setupTimeSync()

            // Build combined player item
            await rebuildComposition()

            var msg = "動画読み込み完了 (\(videoURLs.count)本, 合計 \(formatDuration(duration)))"
            // Show FIT offset info
            if let ts = timeSync, let firstSeg = ts.segments.first,
               let fitStart = ts.activityStartTime {
                let offset = fitStart.timeIntervalSince(firstSeg.fitStartTime)
                if offset > 0 {
                    msg += " | FIT記録開始: \(formatDuration(offset))後"
                }
            }
            statusMessage = msg
        } catch {
            statusMessage = "動画読み込みエラー: \(error.localizedDescription)"
        }
    }

    /// Sort videos chronologically.
    /// GoPro chaptered files share the same creationDate, so use filename as tiebreaker.
    /// GoPro naming: GXnnXXXX.MP4 where nn = chapter number.
    private func sortVideosByCreationDate() {
        let indices = videoURLs.indices.sorted { a, b in
            let dateA = videoMetadatas[a].creationDate ?? .distantPast
            let dateB = videoMetadatas[b].creationDate ?? .distantPast
            if dateA != dateB { return dateA < dateB }
            return videoURLs[a].lastPathComponent < videoURLs[b].lastPathComponent
        }
        videoURLs = indices.map { videoURLs[$0] }
        videoMetadatas = indices.map { videoMetadatas[$0] }
        trimSettings = indices.map { trimSettings[$0] }
        segmentDurations = videoMetadatas.map { $0.duration }
    }

    /// Remove a video at the given index.
    func removeVideo(at index: Int) {
        guard index < videoURLs.count else { return }
        videoURLs.remove(at: index)
        videoMetadatas.remove(at: index)
        trimSettings.remove(at: index)
        segmentDurations = videoMetadatas.map { $0.duration }
        setupTimeSync()
        Task { await rebuildComposition() }
    }

    // MARK: - Composition

    /// Build or rebuild AVMutableComposition from all loaded videos.
    private func rebuildComposition() async {
        do {
            if videoURLs.count == 1 {
                // Single video: play directly
                let url = videoURLs[0]
                let item = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: item)
                duration = segmentDurations[0]

                let tracks = try await AVURLAsset(url: url).load(.tracks)
                if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                    let size = try await videoTrack.load(.naturalSize)
                    overlayRenderer = OverlayRenderer(videoSize: size, settings: overlaySettings)
                    overlayRenderer?.allDataPoints = fitDataPoints
                    overlayRenderer?.trackCoordinates = trackCoordinates
                    overlayRenderer?.buildElevationGainCache()
                }
            } else {
                // Multiple videos: compose into one timeline
                let composition = AVMutableComposition()
                let videoCompositionTrack = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                )
                let audioCompositionTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                )

                var insertTime = CMTime.zero
                var firstVideoSize: CGSize?

                for url in videoURLs {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.load(.tracks)
                    let assetDuration = try await asset.load(.duration)
                    let timeRange = CMTimeRange(start: .zero, duration: assetDuration)

                    if let vTrack = tracks.first(where: { $0.mediaType == .video }) {
                        try videoCompositionTrack?.insertTimeRange(timeRange, of: vTrack, at: insertTime)
                        if firstVideoSize == nil {
                            firstVideoSize = try await vTrack.load(.naturalSize)
                        }
                    }
                    if let aTrack = tracks.first(where: { $0.mediaType == .audio }) {
                        try audioCompositionTrack?.insertTimeRange(timeRange, of: aTrack, at: insertTime)
                    }
                    insertTime = CMTimeAdd(insertTime, assetDuration)
                }

                let item = AVPlayerItem(asset: composition)
                player.replaceCurrentItem(with: item)
                duration = CMTimeGetSeconds(insertTime)

                if let size = firstVideoSize {
                    overlayRenderer = OverlayRenderer(videoSize: size, settings: overlaySettings)
                    overlayRenderer?.allDataPoints = fitDataPoints
                    overlayRenderer?.trackCoordinates = trackCoordinates
                    overlayRenderer?.buildElevationGainCache()
                }
            }
        } catch {
            statusMessage = "動画結合エラー: \(error.localizedDescription)"
        }
    }

    // MARK: - Playback controls

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.rate = playbackRate
        }
        isPlaying.toggle()
    }

    func beginSeeking() {
        isSeeking = true
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        isSeeking = false
        updateOverlay()
    }

    func seekToTrimmedTime(_ time: TimeInterval) {
        seek(to: absoluteTime(forTrimmed: time))
    }

    func skipForward(_ seconds: TimeInterval = 5) {
        let target = min(currentTime + seconds, duration)
        seek(to: target)
    }

    func skipBackward(_ seconds: TimeInterval = 5) {
        let target = max(currentTime - seconds, 0)
        seek(to: target)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.rate = isPlaying ? rate : 0
    }

    func cyclePlaybackRate() {
        let rates: [Float] = [0.5, 1.0, 2.0, 4.0, 8.0, 10.0]
        if let idx = rates.firstIndex(of: playbackRate) {
            setPlaybackRate(rates[(idx + 1) % rates.count])
        } else {
            setPlaybackRate(1.0)
        }
    }

    /// Seek to the start of trimmed content.
    func seekToTrimStart() {
        let startTrim = trimSettings.first?.startTrim ?? 0
        seek(to: startTrim)
    }

    func updateSyncOffset(_ offset: Double) {
        syncOffset = offset
        if let timeSync = timeSync, !timeSync.segments.isEmpty {
            timeSync.updateOffset(segmentIndex: 0, offsetSeconds: offset)
        }
        updateOverlay()
    }

    // MARK: - Chapter markers

    func addChapterMarker() {
        let marker = ChapterMarker(time: currentTime)
        chapterMarkers.append(marker)
        chapterMarkers.sort { $0.time < $1.time }
        statusMessage = "チャプターマーカー追加: \(formatDuration(trimmedTime(for: marker.time)))"
    }

    func removeChapterMarker(id: UUID) {
        chapterMarkers.removeAll { $0.id == id }
    }

    func seekToMarker(_ marker: ChapterMarker) {
        seek(to: marker.time)
    }

    /// Generate chapter list text for YouTube description.
    func generateChapterList() -> String {
        var lines: [String] = []
        // Always start with 0:00
        if chapterMarkers.isEmpty || trimmedTime(for: chapterMarkers.first?.time ?? 1) > 0 {
            lines.append("0:00 スタート")
        }
        for marker in chapterMarkers {
            let timeStr = formatChapterTime(trimmedTime(for: marker.time))
            let label = marker.label.isEmpty ? "チャプター" : marker.label
            lines.append("\(timeStr) \(label)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatChapterTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Export preview

    func generateExportPreview() {
        guard let renderer = overlayRenderer,
              let timeSync = timeSync,
              !timeSync.segments.isEmpty else { return }

        let (segmentIndex, segmentPlaybackTime) = resolveSegment(globalTime: currentTime)

        if let dataPoint = timeSync.dataPoint(segmentIndex: segmentIndex, playbackTime: segmentPlaybackTime),
           let elapsed = timeSync.elapsedTime(segmentIndex: segmentIndex, playbackTime: segmentPlaybackTime) {
            exportPreviewImage = renderer.render(dataPoint: dataPoint, elapsedTime: elapsed, globalPlaybackTime: trimmedPlaybackTime())
        }
    }

    // MARK: - Export

    func makeExportViewModel() -> ExportViewModel {
        let vm = ExportViewModel()
        vm.videoURLs = videoURLs
        vm.trimSettings = trimSettings
        vm.timeSync = timeSync
        overlayRenderer?.textOverlays = textOverlays
        overlayRenderer?.trackCoordinates = trackCoordinates
        vm.overlayRenderer = overlayRenderer
        vm.onDismiss = { [weak self] in
            self?.showExport = false
        }
        return vm
    }

    // MARK: - Private

    private func setupTimeSync() {
        timeSync = TimeSync(dataPoints: fitDataPoints)

        // For GoPro chaptered files: all chapters share the same creationDate.
        // Each subsequent chapter's real start = creationDate + sum of preceding durations.
        var cumulativeOffset: TimeInterval = 0
        for (i, metadata) in videoMetadatas.enumerated() {
            guard metadata.creationDate != nil else { continue }

            // Create a metadata with adjusted creationDate for chaptered files
            let adjustedMetadata = VideoMetadata(
                url: metadata.url,
                creationDate: metadata.creationDate?.addingTimeInterval(cumulativeOffset),
                duration: metadata.duration
            )
            timeSync?.addVideo(adjustedMetadata, offsetSeconds: i == 0 ? syncOffset : 0)
            cumulativeOffset += metadata.duration
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self, !self.isSeeking else { return }
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

        // Map combined playback time to the correct segment
        let (segmentIndex, segmentPlaybackTime) = resolveSegment(globalTime: currentTime)

        if let dataPoint = timeSync.dataPoint(segmentIndex: segmentIndex, playbackTime: segmentPlaybackTime),
           let elapsed = timeSync.elapsedTime(segmentIndex: segmentIndex, playbackTime: segmentPlaybackTime) {
            // Check if FIT recording is active (elapsed > 0 means past FIT start)
            renderer.fitRecordingActive = elapsed >= 0 && (dataPoint.distance ?? 0) > 0
            renderer.textOverlays = textOverlays
            overlayImage = renderer.render(dataPoint: dataPoint, elapsedTime: elapsed, globalPlaybackTime: trimmedPlaybackTime())
            currentCoordinate = dataPoint.coordinate
        }
    }

    /// Convert combined timeline position to (segmentIndex, timeWithinSegment).
    private func resolveSegment(globalTime: TimeInterval) -> (Int, TimeInterval) {
        var remaining = globalTime
        for (i, dur) in segmentDurations.enumerated() {
            if remaining <= dur || i == segmentDurations.count - 1 {
                return (min(i, (timeSync?.segments.count ?? 1) - 1), remaining)
            }
            remaining -= dur
        }
        return (0, globalTime)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Trim helpers

    struct TrimRange {
        let startFrac: CGFloat  // fraction of total duration trimmed from start
        let endFrac: CGFloat    // fraction of total duration trimmed from end
    }

    /// Get trim ranges mapped to the combined timeline for seekbar display.
    func trimRangesForSeekbar() -> [TrimRange] {
        guard duration > 0 else { return [] }

        var cumulativeStart: TimeInterval = 0
        var ranges: [TrimRange] = []

        // Combine all segments into one range for the full timeline
        var totalStartTrim: TimeInterval = 0
        var totalEndTrim: TimeInterval = 0

        for (i, dur) in segmentDurations.enumerated() {
            if i < trimSettings.count {
                if i == 0 {
                    totalStartTrim = trimSettings[i].startTrim
                }
                if i == segmentDurations.count - 1 {
                    totalEndTrim = trimSettings[i].endTrim
                }
            }
        }

        return [TrimRange(
            startFrac: CGFloat(totalStartTrim / duration),
            endFrac: CGFloat(totalEndTrim / duration)
        )]
    }

    /// Total duration after trimming.
    func trimmedTotalDuration() -> TimeInterval {
        zip(segmentDurations, trimSettings).reduce(0) { sum, pair in
            sum + pair.1.trimmedDuration(original: pair.0)
        }
    }

    /// Convert current playback time to trimmed time (time after trim start).
    func trimmedPlaybackTime() -> TimeInterval {
        trimmedTime(for: currentTime)
    }

    /// Convert a trimmed/exported timeline position back to the absolute combined timeline.
    func absoluteTime(forTrimmed trimmedTime: TimeInterval) -> TimeInterval {
        guard !segmentDurations.isEmpty else { return max(0, trimmedTime) }

        let clampedTrimmedTime = min(max(trimmedTime, 0), trimmedTotalDuration())
        var absoluteCursor: TimeInterval = 0
        var trimmedCursor: TimeInterval = 0

        for (index, duration) in segmentDurations.enumerated() {
            let trim = index < trimSettings.count ? trimSettings[index] : TrimSettings()
            let trimmedDuration = trim.trimmedDuration(original: duration)
            let segmentAbsoluteStart = absoluteCursor

            if clampedTrimmedTime <= trimmedCursor + trimmedDuration || index == segmentDurations.count - 1 {
                let localTrimmedTime = min(max(clampedTrimmedTime - trimmedCursor, 0), trimmedDuration)
                return segmentAbsoluteStart + trim.startTrim + localTrimmedTime
            }

            trimmedCursor += trimmedDuration
            absoluteCursor += duration
        }

        return absoluteCursor
    }

    /// Convert an absolute combined-timeline position to the trimmed/exported timeline.
    func trimmedTime(for absoluteTime: TimeInterval) -> TimeInterval {
        guard !segmentDurations.isEmpty else { return max(0, absoluteTime) }

        var absoluteCursor: TimeInterval = 0
        var trimmedCursor: TimeInterval = 0

        for (index, duration) in segmentDurations.enumerated() {
            let trim = index < trimSettings.count ? trimSettings[index] : TrimSettings()
            let segmentStart = absoluteCursor
            let segmentEnd = segmentStart + duration

            if absoluteTime <= segmentEnd || index == segmentDurations.count - 1 {
                let clampedLocalTime = min(max(absoluteTime - segmentStart, 0), duration)
                return trimmedCursor + min(max(clampedLocalTime - trim.startTrim, 0), trim.trimmedDuration(original: duration))
            }

            trimmedCursor += trim.trimmedDuration(original: duration)
            absoluteCursor = segmentEnd
        }

        return trimmedCursor
    }
}
