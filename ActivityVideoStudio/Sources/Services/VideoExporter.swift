import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import AppKit
import OSLog

private let exportLogger = Logger(subsystem: "com.avs", category: "Export")

/// Log export progress; DEBUG builds also mirror to /tmp/avs_export.log for CLI runs.
private func exportLog(_ msg: String) {
    #if DEBUG
    let line = "[Export] \(msg)\n"
    if let data = line.data(using: .utf8) {
        let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        }
        FileHandle.standardError.write(data)
    }
    #endif
    exportLogger.info("\(msg)")
}

private func locked<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
}

private extension TextOverlay {
    func isOpacityAnimating(at time: TimeInterval) -> Bool {
        let relativeTime = time - startTime
        guard relativeTime >= 0, relativeTime <= duration else { return false }

        if fadeInDuration > 0, relativeTime < fadeInDuration {
            return true
        }

        if fadeOutDuration > 0 {
            let fadeOutStart = duration - fadeOutDuration
            return relativeTime > fadeOutStart
        }

        return false
    }
}

// MARK: - VideoExporter

/// Exports video with overlay composited using AVVideoComposition + AVAssetExportSession.
///
/// ## macOS 26 note
/// `AVMutableVideoComposition` + `customVideoCompositorClass` is deprecated in macOS 26 and
/// the custom compositor is silently bypassed on that OS. We use the
/// `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` closure API instead, which is
/// guaranteed to be called for every frame on all macOS versions.
final class VideoExporter: @unchecked Sendable {

    enum ExportError: Error, LocalizedError {
        case noVideos
        case cannotCreateWriter
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideos:             return "エクスポートする動画がありません"
            case .cannotCreateWriter:   return "エクスポートセッションを作成できませんでした"
            case .exportFailed(let m):  return "エクスポート失敗: \(m)"
            case .cancelled:            return "エクスポートがキャンセルされました"
            }
        }
    }

    struct ExportConfig {
        var outputURL: URL
        var width: Int  = 1920
        var height: Int = 1080
        var bitRate: Int = 10_000_000   // informational; preset controls actual quality
        var frameRate: Int = 30
        var overlayCacheQuantum: TimeInterval = 0.25
    }

    typealias ProgressCallback = @Sendable (Double, TimeInterval?) -> Void
    typealias StatusCallback   = @Sendable (String) -> Void

    private struct OverlayCacheKey: Equatable {
        let sourceBucket: Int64
        let playbackBucket: Int64
    }

    private final class OverlayFrameCache: @unchecked Sendable {
        private struct Entry {
            let key: OverlayCacheKey
            let cgImage: CGImage
            let ciImage: CIImage
        }

        private let lock = NSLock()
        private let baseQuantum: TimeInterval
        private let frameQuantum: TimeInterval
        private let textOverlays: [TextOverlay]
        private var entry: Entry?

        init(quantum: TimeInterval, frameRate: Int, textOverlays: [TextOverlay]) {
            baseQuantum = Swift.max(quantum, 1.0 / 60.0)
            frameQuantum = 1.0 / TimeInterval(Swift.max(frameRate, 1))
            self.textOverlays = textOverlays
        }

        func image(
            sourceVideoTime: TimeInterval,
            dataPoint: FITDataPoint,
            elapsedTime: TimeInterval,
            globalPlaybackTime: TimeInterval,
            renderer: OverlayRenderer
        ) -> CIImage? {
            let key = cacheKey(sourceVideoTime: sourceVideoTime, globalPlaybackTime: globalPlaybackTime)
            if let cached = locked(lock, { entry }), cached.key == key {
                return cached.ciImage
            }

            guard let cgImage = renderer.render(
                dataPoint: dataPoint,
                elapsedTime: elapsedTime,
                globalPlaybackTime: globalPlaybackTime
            ) else {
                return nil
            }

            let ciImage = CIImage(cgImage: cgImage)
            locked(lock) {
                entry = Entry(key: key, cgImage: cgImage, ciImage: ciImage)
            }
            return ciImage
        }

        private func cacheKey(sourceVideoTime: TimeInterval, globalPlaybackTime: TimeInterval) -> OverlayCacheKey {
            let playbackQuantum = textOverlays.contains { $0.isOpacityAnimating(at: globalPlaybackTime) }
                ? Swift.min(baseQuantum, frameQuantum)
                : baseQuantum

            return OverlayCacheKey(
                sourceBucket: Self.bucket(for: sourceVideoTime, quantum: baseQuantum),
                playbackBucket: Self.bucket(for: globalPlaybackTime, quantum: playbackQuantum)
            )
        }

        private static func bucket(for time: TimeInterval, quantum: TimeInterval) -> Int64 {
            Int64(floor(time / quantum))
        }
    }

    private final class ConcatenatedProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let weights: [Double]
        private let start = Date()
        private var fractions: [Double]

        init(segmentDurations: [Double], totalDuration: Double) {
            weights = segmentDurations.map { $0 / totalDuration }
            fractions = Array(repeating: 0, count: segmentDurations.count)
        }

        func update(segmentIndex: Int, fraction: Double, progress: ProgressCallback) {
            let (overall, estimated) = locked(lock) { () -> (Double, TimeInterval?) in
                guard fractions.indices.contains(segmentIndex) else { return (0, nil) }
                let clipped = Swift.min(Swift.max(fraction, 0), 1)
                fractions[segmentIndex] = Swift.max(fractions[segmentIndex], clipped)

                let weightedProgress = zip(fractions, weights).reduce(0.0) { partial, item in
                    partial + item.0 * item.1
                }
                let elapsed = Date().timeIntervalSince(start)
                let remaining = weightedProgress > 0.01 ? elapsed / weightedProgress - elapsed : nil
                return (Swift.min(weightedProgress, 0.99), remaining)
            }
            progress(overall, estimated)
        }
    }

    private var isCancelled = false
    private var activeExportSessions: [ObjectIdentifier: AVAssetExportSession] = [:]
    private let stateLock = NSLock()

    func cancel() {
        let sessions = locked(stateLock) { () -> [AVAssetExportSession] in
            isCancelled = true
            return Array(activeExportSessions.values)
        }
        sessions.forEach { $0.cancelExport() }
    }

    private var cancellationRequested: Bool {
        locked(stateLock) { isCancelled }
    }

    private func registerExportSession(_ session: AVAssetExportSession) {
        let shouldCancel = locked(stateLock) { () -> Bool in
            activeExportSessions[ObjectIdentifier(session)] = session
            return isCancelled
        }
        if shouldCancel {
            session.cancelExport()
        }
    }

    private func unregisterExportSession(_ session: AVAssetExportSession) {
        locked(stateLock) {
            activeExportSessions.removeValue(forKey: ObjectIdentifier(session))
        }
    }

    private func cancelActiveExportSessions() {
        let sessions = locked(stateLock) { Array(activeExportSessions.values) }
        sessions.forEach { $0.cancelExport() }
    }

    private static func maxConcurrentSegmentExports(segmentCount: Int) -> Int {
        let cores = Swift.max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let processorLimit = cores >= 8 ? 4 : Swift.max(1, cores / 2)
        return Swift.max(1, Swift.min(segmentCount, processorLimit))
    }

    // MARK: - Single Video Export

    func exportSingleVideo(
        videoURL: URL,
        timeSync: TimeSync,
        segmentIndex: Int,
        trimSettings: TrimSettings = TrimSettings(),
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        outputTimeOffset: TimeInterval = 0,
        progress: @escaping ProgressCallback
    ) async throws {
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        exportLog("START seg=\(segmentIndex) url=\(videoURL.lastPathComponent)")

        let asset    = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let tracks   = try await asset.load(.tracks)

        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw ExportError.noVideos
        }
        let audioTrack   = tracks.first(where: { $0.mediaType == .audio })
        let totalSeconds = CMTimeGetSeconds(duration)
        exportLog("asset loaded: \(String(format: "%.1f", totalSeconds))s hasAudio=\(audioTrack != nil)")

        // Build a mutable composition to attach a videoComposition
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.cannotCreateWriter }

        let startTime = CMTime(seconds: trimSettings.startTrim, preferredTimescale: 600)
        let endTrim = CMTime(seconds: trimSettings.endTrim, preferredTimescale: 600)
        let trimmedDuration = CMTimeSubtract(duration, CMTimeAdd(startTime, endTrim))
        let timeRange = CMTimeRange(start: startTime, duration: trimmedDuration)
        try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        if let audioTrack,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        // Per-frame overlay compositing.
        // AVVideoComposition(asset:applyingCIFiltersWithHandler:) invokes the closure for every
        // frame — unlike customVideoCompositorClass which is silently bypassed on macOS 26.
        let capturedTimeSync = timeSync
        let capturedRenderer = overlayRenderer
        let capturedSegIdx   = segmentIndex
        let capturedTrimSettings = trimSettings
        let capturedOutputOffset = outputTimeOffset
        let overlayCache = OverlayFrameCache(
            quantum: config.overlayCacheQuantum,
            frameRate: config.frameRate,
            textOverlays: overlayRenderer.textOverlays
        )

        let videoComposition = AVVideoComposition(asset: composition) { [weak capturedRenderer] request in
            let t = CMTimeGetSeconds(request.compositionTime)
            // TimeSync expects source-video playback time (== `t + startTrim`),
            // because segment.fitStartTime maps to the untrimmed video start.
            let sourceVideoTime = t + capturedTrimSettings.startTrim
            let globalPlaybackTime = capturedOutputOffset + t

            guard let renderer = capturedRenderer,
                  let dp       = capturedTimeSync.dataPoint(segmentIndex: capturedSegIdx, playbackTime: sourceVideoTime),
                  let elapsed  = capturedTimeSync.elapsedTime(segmentIndex: capturedSegIdx, playbackTime: sourceVideoTime) else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }

            autoreleasepool {
                if let overlayCI = overlayCache.image(
                    sourceVideoTime: sourceVideoTime,
                    dataPoint: dp,
                    elapsedTime: elapsed,
                    globalPlaybackTime: globalPlaybackTime,
                    renderer: renderer
                ) {
                    let composited = overlayCI.composited(over: request.sourceImage)
                                              .cropped(to: request.sourceImage.extent)
                    request.finish(with: composited, context: nil)
                } else {
                    request.finish(with: request.sourceImage, context: nil)
                }
            }
        }

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }

        let preset = Self.exportPreset(for: config)
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.cannotCreateWriter
        }
        exportSession.videoComposition        = videoComposition
        exportSession.outputURL               = config.outputURL
        exportSession.outputFileType          = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        registerExportSession(exportSession)
        defer { unregisterExportSession(exportSession) }

        exportLog("starting AVAssetExportSession (preset=\(preset))...")

        let exportStart = Date()
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let fraction = Double(exportSession.progress)
                let elapsed  = Date().timeIntervalSince(exportStart)
                let estimated: TimeInterval? = fraction > 0.01 ? elapsed / fraction - elapsed : nil
                progress(fraction, estimated)
            }
        }

        await withTaskCancellationHandler {
            await exportSession.export()
        } onCancel: {
            exportSession.cancelExport()
        }
        progressTask.cancel()

        if let err = exportSession.error as NSError? {
            exportLog("export finished: status=\(exportSession.status.rawValue) error domain=\(err.domain) code=\(err.code) desc=\(err.localizedDescription) userInfo=\(err.userInfo)")
        } else {
            exportLog("export finished: status=\(exportSession.status.rawValue) error=none")
        }

        if cancellationRequested || Task.isCancelled || exportSession.status == .cancelled {
            throw ExportError.cancelled
        }
        guard exportSession.status == .completed else {
            throw ExportError.exportFailed(
                exportSession.error?.localizedDescription ?? "エクスポート失敗"
            )
        }

        progress(1.0, 0)
        exportLog("DONE seg=\(segmentIndex)")
    }

    // MARK: - Concatenated Export

    /// Export each segment individually (with correct overlay), then passthrough-concat.
    func exportConcatenated(
        videoURLs: [URL],
        trimSettings: [TrimSettings] = [],
        timeSync: TimeSync,
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        onStatus: @escaping StatusCallback = { _ in },
        progress: @escaping ProgressCallback
    ) async throws {
        guard !videoURLs.isEmpty else { throw ExportError.noVideos }

        if videoURLs.count == 1 {
            try await exportSingleVideo(
                videoURL: videoURLs[0], timeSync: timeSync, segmentIndex: 0,
                trimSettings: trimSettings.first ?? TrimSettings(),
                overlayRenderer: overlayRenderer, config: config, progress: progress)
            return
        }

        // Phase 1: pre-load durations
        var segmentDurations: [Double] = []
        for (segIdx, url) in videoURLs.enumerated() {
            let dur = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
            let trim = segIdx < trimSettings.count ? trimSettings[segIdx] : TrimSettings()
            segmentDurations.append(max(trim.trimmedDuration(original: dur), 0.001))
        }
        let totalDuration = segmentDurations.reduce(0, +)

        // Phase 2: export each segment to temp file.
        // Keep intermediates next to the final output so large exports stay on
        // the user-selected volume instead of filling the system drive.
        let tempDir = config.outputURL.deletingLastPathComponent()
        let tempURLs = videoURLs.map { _ in
            tempDir
                .appendingPathComponent(".avs_tmp_" + UUID().uuidString)
                .appendingPathExtension("mp4")
        }
        defer { tempURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        var outputOffsets = Array(repeating: 0.0, count: videoURLs.count)
        var runningOffset = 0.0
        for idx in videoURLs.indices {
            outputOffsets[idx] = runningOffset
            runningOffset += segmentDurations[idx]
        }

        let progressAggregator = ConcatenatedProgress(
            segmentDurations: segmentDurations,
            totalDuration: totalDuration
        )
        let maxConcurrentExports = Self.maxConcurrentSegmentExports(segmentCount: videoURLs.count)
        exportLog("exporting \(videoURLs.count) segments with concurrency=\(maxConcurrentExports)")

        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextSegmentIndex = 0

            func enqueueNextSegment() throws {
                if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
                guard nextSegmentIndex < videoURLs.count else { return }

                let segIdx = nextSegmentIndex
                nextSegmentIndex += 1

                onStatus("動画 \(segIdx + 1) / \(videoURLs.count) を書き出し中...")

                let url = videoURLs[segIdx]
                let trim = segIdx < trimSettings.count ? trimSettings[segIdx] : TrimSettings()
                let tempURL = tempURLs[segIdx]
                let outputOffset = outputOffsets[segIdx]
                let segmentRenderer = overlayRenderer.makeExportCopy()
                var segConfig = config
                segConfig.outputURL = tempURL

                group.addTask {
                    if self.cancellationRequested || Task.isCancelled { throw ExportError.cancelled }

                    try await self.exportSingleVideo(
                        videoURL: url,
                        timeSync: timeSync,
                        segmentIndex: segIdx,
                        trimSettings: trim,
                        overlayRenderer: segmentRenderer,
                        config: segConfig,
                        outputTimeOffset: outputOffset
                    ) { fraction, _ in
                        progressAggregator.update(
                            segmentIndex: segIdx,
                            fraction: fraction,
                            progress: progress
                        )
                    }

                    return segIdx
                }
            }

            for _ in 0..<maxConcurrentExports {
                try enqueueNextSegment()
            }

            do {
                while let _ = try await group.next() {
                    try enqueueNextSegment()
                }
            } catch {
                group.cancelAll()
                cancelActiveExportSessions()
                throw error
            }
        }

        // Phase 3: passthrough concat (no re-encode)
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        onStatus("動画を結合中...")

        let concatComp = AVMutableComposition()
        guard let vcTrack = concatComp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.cannotCreateWriter }
        let acTrack = concatComp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        for tempURL in tempURLs {
            let a = AVURLAsset(url: tempURL)
            let d = try await a.load(.duration)
            let r = CMTimeRange(start: .zero, duration: d)
            let t = try await a.load(.tracks)
            if let vt = t.first(where: { $0.mediaType == .video }) { try vcTrack.insertTimeRange(r, of: vt, at: insertTime) }
            if let at = t.first(where: { $0.mediaType == .audio }) { try? acTrack?.insertTimeRange(r, of: at, at: insertTime) }
            insertTime = CMTimeAdd(insertTime, d)
        }

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }

        guard let concatSession = AVAssetExportSession(
            asset: concatComp, presetName: AVAssetExportPresetPassthrough
        ) else { throw ExportError.cannotCreateWriter }
        concatSession.outputURL      = config.outputURL
        concatSession.outputFileType = .mp4
        registerExportSession(concatSession)
        defer { unregisterExportSession(concatSession) }

        await withTaskCancellationHandler {
            await concatSession.export()
        } onCancel: {
            concatSession.cancelExport()
        }
        if cancellationRequested || Task.isCancelled || concatSession.status == .cancelled {
            throw ExportError.cancelled
        }
        guard concatSession.status == .completed else {
            throw ExportError.exportFailed(
                concatSession.error?.localizedDescription ?? "結合に失敗しました")
        }
        progress(1.0, 0)
    }

    // MARK: - Helpers

    private static func exportPreset(for config: ExportConfig) -> String {
        if config.width >= 3840 { return AVAssetExportPreset3840x2160 }
        if config.width >= 1920 { return AVAssetExportPreset1920x1080 }
        return AVAssetExportPreset1280x720
    }
}
