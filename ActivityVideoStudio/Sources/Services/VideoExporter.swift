import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import AppKit
import OSLog

private let exportLogger = Logger(subsystem: "com.avs", category: "Export")

/// Write to /tmp/avs_export.log (append) + stderr for live tail.
private func exportLog(_ msg: String) {
    let line = "[Export] \(msg)\n"
    if let data = line.data(using: .utf8) {
        let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        }
        FileHandle.standardError.write(data)
    }
    exportLogger.info("\(msg)")
}

// MARK: - VideoExporter

/// Exports video with overlay composited using AVVideoComposition + AVAssetExportSession.
///
/// ## macOS 26 note
/// `AVMutableVideoComposition` + `customVideoCompositorClass` is deprecated in macOS 26 and
/// the custom compositor is silently bypassed on that OS. We use the
/// `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` closure API instead, which is
/// guaranteed to be called for every frame on all macOS versions.
final class VideoExporter {

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
    }

    typealias ProgressCallback = @Sendable (Double, TimeInterval?) -> Void
    typealias StatusCallback   = @Sendable (String) -> Void

    private var isCancelled = false
    private var activeExportSession: AVAssetExportSession?

    func cancel() {
        isCancelled = true
        activeExportSession?.cancelExport()
    }

    // MARK: - Single Video Export

    func exportSingleVideo(
        videoURL: URL,
        timeSync: TimeSync,
        segmentIndex: Int,
        trimSettings: TrimSettings = TrimSettings(),
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        progress: @escaping ProgressCallback
    ) async throws {
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

        let videoComposition = AVVideoComposition(asset: composition) { [weak capturedRenderer] request in
            let t = CMTimeGetSeconds(request.compositionTime)

            guard let renderer = capturedRenderer,
                  let dp       = capturedTimeSync.dataPoint(segmentIndex: capturedSegIdx, playbackTime: t),
                  let elapsed  = capturedTimeSync.elapsedTime(segmentIndex: capturedSegIdx, playbackTime: t) else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }

            autoreleasepool {
                if let overlayImage = renderer.render(
                    dataPoint: dp,
                    elapsedTime: elapsed,
                    globalPlaybackTime: t + capturedTrimSettings.startTrim
                ) {
                    let overlayCI  = CIImage(cgImage: overlayImage)
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
        activeExportSession = exportSession
        defer { activeExportSession = nil }

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

        await exportSession.export()
        progressTask.cancel()

        exportLog("export finished: status=\(exportSession.status.rawValue) error=\(exportSession.error?.localizedDescription ?? "none")")

        if isCancelled || exportSession.status == .cancelled {
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

        // Phase 2: export each segment to temp file
        var tempURLs: [URL] = []
        defer { tempURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        var completedDuration = 0.0
        for (segIdx, url) in videoURLs.enumerated() {
            if isCancelled { throw ExportError.cancelled }
            onStatus("動画 \(segIdx + 1) / \(videoURLs.count) を処理中...")

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            var segConfig = config
            segConfig.outputURL = tempURL

            let baseFraction = completedDuration / totalDuration
            let segWeight    = segmentDurations[segIdx] / totalDuration

            try await exportSingleVideo(
                videoURL: url, timeSync: timeSync, segmentIndex: segIdx,
                trimSettings: segIdx < trimSettings.count ? trimSettings[segIdx] : TrimSettings(),
                overlayRenderer: overlayRenderer, config: segConfig
            ) { fraction, remaining in
                progress(min(baseFraction + fraction * segWeight, 0.99), remaining)
            }

            tempURLs.append(tempURL)
            completedDuration += segmentDurations[segIdx]
        }

        // Phase 3: passthrough concat (no re-encode)
        if isCancelled { throw ExportError.cancelled }
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
        activeExportSession = concatSession
        defer { activeExportSession = nil }

        await concatSession.export()
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
