import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import AppKit
import OSLog
import VideoToolbox

private let exportLogger = Logger(subsystem: "com.avs", category: "Export")
private let finalConcatenationProgressStart = 0.99
private let finalConcatenationProgressSpan = 1.0 - finalConcatenationProgressStart
private let finalVideoOnlyConcatenationProgressStart = 0.99
private let finalVideoOnlyConcatenationProgressSpan = 0.005
private let finalAudioMuxProgressStart = 0.995
private let finalAudioMuxProgressSpan = 1.0 - finalAudioMuxProgressStart
private let concatenationProgressPollInterval: UInt64 = 250_000_000

/// Log export progress; DEBUG builds also mirror to /tmp/avs_export.log for CLI runs.
private func exportLog(_ msg: String) {
    #if DEBUG
    let line = "[Export] \(msg)\n"
    if let data = line.data(using: .utf8) {
        let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
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

// MARK: - VideoExporter

/// Exports video with overlay composited using AVVideoComposition + AVAssetWriter.
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
        case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideos:             return "エクスポートする動画がありません"
            case .cannotCreateWriter:   return "エクスポート処理を作成できませんでした"
            case .exportFailed(let m):  return "エクスポート失敗: \(m)"
            case .insufficientDiskSpace:
                return "保存先の空き容量が不足しています"
            case .cancelled:            return "エクスポートがキャンセルされました"
            }
        }

        var failureReason: String? {
            switch self {
            case let .insufficientDiskSpace(requiredBytes, availableBytes):
                return "必要な空き容量: \(VideoExporter.formatByteCount(requiredBytes))\n利用可能な空き容量: \(VideoExporter.formatByteCount(availableBytes))"
            default:
                return nil
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .insufficientDiskSpace:
                return "保存先の空き容量を増やすか、別の保存先を選択してから再試行してください。"
            default:
                return nil
            }
        }
    }

    struct ExportConfig {
        var outputURL: URL
        var width: Int  = 1920
        var height: Int = 1080
        var bitRate: Int = 10_000_000
        var frameRate: Int = 30
        var overlayCacheQuantum: TimeInterval = 0.25
    }

    typealias ProgressCallback = @Sendable (Double, TimeInterval?) -> Void
    typealias StatusCallback   = @Sendable (String) -> Void

    private struct OverlayCacheKey: Equatable {
        let contentKind: OverlayCacheContentKind
        let sourceBucket: Int64
        let playbackBucket: Int64
        let recordingState: FITRecordingState
        let textVisibility: [Bool]
    }

    private enum OverlayCacheContentKind: Equatable {
        case full
        case textOnly
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

        init(quantum: TimeInterval, sourceFrameRate: TimeInterval, textOverlays: [TextOverlay]) {
            baseQuantum = Swift.max(quantum, 1.0 / 60.0)
            let fps = sourceFrameRate.isFinite ? sourceFrameRate : 0
            frameQuantum = 1.0 / Swift.max(fps, 1)
            self.textOverlays = textOverlays
        }

        func image(
            sourceVideoTime: TimeInterval,
            dataPoint: FITDataPoint,
            elapsedTime: TimeInterval,
            globalPlaybackTime: TimeInterval,
            recordingState: FITRecordingState,
            renderer: OverlayRenderer
        ) -> CIImage? {
            let key = cacheKey(
                sourceVideoTime: sourceVideoTime,
                globalPlaybackTime: globalPlaybackTime,
                recordingState: recordingState
            )
            if let cached = locked(lock, { entry }), cached.key == key {
                return cached.ciImage
            }

            return locked(lock) {
                if let cached = entry, cached.key == key {
                    return cached.ciImage
                }

                guard let cgImage = renderer.render(
                    dataPoint: dataPoint,
                    elapsedTime: elapsedTime,
                    globalPlaybackTime: globalPlaybackTime,
                    recordingState: recordingState
                ) else {
                    return nil
                }

                let ciImage = CIImage(cgImage: cgImage)
                entry = Entry(key: key, cgImage: cgImage, ciImage: ciImage)
                return ciImage
            }
        }

        func textOnlyImage(
            globalPlaybackTime: TimeInterval,
            renderer: OverlayRenderer
        ) -> CIImage? {
            let key = textOnlyCacheKey(globalPlaybackTime: globalPlaybackTime)
            if let cached = locked(lock, { entry }), cached.key == key {
                return cached.ciImage
            }

            return locked(lock) {
                if let cached = entry, cached.key == key {
                    return cached.ciImage
                }

                guard let cgImage = renderer.renderTextOverlaysOnly(globalPlaybackTime: globalPlaybackTime) else {
                    return nil
                }

                let ciImage = CIImage(cgImage: cgImage)
                entry = Entry(key: key, cgImage: cgImage, ciImage: ciImage)
                return ciImage
            }
        }

        private func cacheKey(
            sourceVideoTime: TimeInterval,
            globalPlaybackTime: TimeInterval,
            recordingState: FITRecordingState
        ) -> OverlayCacheKey {
            let playbackQuantum = textOverlays.contains { $0.isOpacityAnimating(at: globalPlaybackTime) }
                ? Swift.min(baseQuantum, frameQuantum)
                : baseQuantum

            return OverlayCacheKey(
                contentKind: .full,
                sourceBucket: Self.bucket(for: sourceVideoTime, quantum: baseQuantum),
                playbackBucket: Self.bucket(for: globalPlaybackTime, quantum: playbackQuantum),
                recordingState: recordingState,
                textVisibility: textVisibility(at: globalPlaybackTime)
            )
        }

        private func textOnlyCacheKey(globalPlaybackTime: TimeInterval) -> OverlayCacheKey {
            let playbackQuantum = textOverlays.contains { $0.isOpacityAnimating(at: globalPlaybackTime) }
                ? Swift.min(baseQuantum, frameQuantum)
                : baseQuantum

            return OverlayCacheKey(
                contentKind: .textOnly,
                sourceBucket: 0,
                playbackBucket: Self.bucket(for: globalPlaybackTime, quantum: playbackQuantum),
                recordingState: .waitingForStart,
                textVisibility: textVisibility(at: globalPlaybackTime)
            )
        }

        private func textVisibility(at globalPlaybackTime: TimeInterval) -> [Bool] {
            textOverlays.map { $0.isVisible(at: globalPlaybackTime) }
        }

        private static func bucket(for time: TimeInterval, quantum: TimeInterval) -> Int64 {
            Int64(floor(time / quantum))
        }
    }

    private final class OverlayRendererHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var renderer: OverlayRenderer?

        func set(_ renderer: OverlayRenderer) {
            locked(lock) {
                self.renderer = renderer
            }
        }

        func get() -> OverlayRenderer? {
            locked(lock) {
                renderer
            }
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
                return (Swift.min(weightedProgress, finalConcatenationProgressStart), remaining)
            }
            progress(overall, estimated)
        }
    }

    private struct SourceExportRange: Sendable {
        let sourceStartValue: CMTimeValue
        let sourceDurationValue: CMTimeValue
        let sourceTimescale: CMTimeScale
        let outputStartValue: CMTimeValue
        let outputStartTimescale: CMTimeScale

        init(
            sourceStartFrame: Int64,
            frameCount: Int64,
            sourceFrameDuration: CMTime,
            outputStart: CMTime
        ) {
            sourceStartValue = sourceFrameDuration.value * sourceStartFrame
            sourceDurationValue = sourceFrameDuration.value * frameCount
            sourceTimescale = sourceFrameDuration.timescale
            outputStartValue = outputStart.value
            outputStartTimescale = outputStart.timescale
        }

        init(sourceStart: CMTime, sourceDuration: CMTime, outputStart: CMTime) {
            let normalizedDuration = CMTimeConvertScale(
                sourceDuration,
                timescale: sourceStart.timescale,
                method: .roundHalfAwayFromZero
            )
            sourceStartValue = sourceStart.value
            sourceDurationValue = normalizedDuration.value
            sourceTimescale = sourceStart.timescale
            outputStartValue = outputStart.value
            outputStartTimescale = outputStart.timescale
        }

        var sourceStart: CMTime {
            CMTime(value: sourceStartValue, timescale: sourceTimescale)
        }

        var sourceDuration: CMTime {
            CMTime(value: sourceDurationValue, timescale: sourceTimescale)
        }

        var sourceEnd: CMTime {
            CMTimeAdd(sourceStart, sourceDuration)
        }

        var sourceTimeRange: CMTimeRange {
            CMTimeRange(start: sourceStart, duration: sourceDuration)
        }

        var outputStart: CMTime {
            CMTime(value: outputStartValue, timescale: outputStartTimescale)
        }

        var outputEnd: CMTime {
            CMTimeAdd(outputStart, sourceDuration)
        }

        var sourceStartTime: TimeInterval {
            CMTimeGetSeconds(sourceStart)
        }

        var outputStartTime: TimeInterval {
            CMTimeGetSeconds(outputStart)
        }

        var duration: TimeInterval {
            CMTimeGetSeconds(sourceDuration)
        }
    }

    private struct SourceAudioExportRange: Sendable {
        let videoURL: URL
        let range: SourceExportRange
    }

    private struct TimeRangeExportJob: Sendable {
        let videoURL: URL
        let segmentIndex: Int
        let range: SourceExportRange
        let tempURL: URL
        let statusMessage: String
    }

    private struct SourceColorProperties {
        let primaries: String
        let transferFunction: String
        let yCbCrMatrix: String

        var videoSettings: [String: String] {
            [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transferFunction,
                AVVideoYCbCrMatrixKey: yCbCrMatrix
            ]
        }

        var isHDR: Bool {
            transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ||
            transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        }

        static let defaultHLG = SourceColorProperties(
            primaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
            yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020
        )
    }

    private struct SourceVideoProperties {
        let formatDescription: CMFormatDescription?
        let colorProperties: SourceColorProperties?
        let is10Bit: Bool

        var isHDR: Bool {
            colorProperties?.isHDR == true
        }

        var requiresHEVCMain10: Bool {
            is10Bit || isHDR
        }

        var writerColorProperties: SourceColorProperties? {
            if let colorProperties { return colorProperties }
            return isHDR ? .defaultHLG : nil
        }
    }

    private struct SourceAudioProperties {
        let formatDescription: CMFormatDescription?
        let sampleRate: Double?
        let channelCount: Int?

        static let none = SourceAudioProperties(
            formatDescription: nil,
            sampleRate: nil,
            channelCount: nil
        )
    }

    private struct WriterOutputSettings {
        let videoSettings: [String: Any]
        let audioSettings: [String: Any]?
        let videoReaderSettings: [String: Any]
        let codec: AVVideoCodecType
    }

    private var isCancelled = false
    private var activeExportSessions: [ObjectIdentifier: AVAssetExportSession] = [:]
    private var activeAssetReaders: [ObjectIdentifier: AVAssetReader] = [:]
    private let stateLock = NSLock()

    func cancel() {
        let active = locked(stateLock) { () -> ([AVAssetExportSession], [AVAssetReader]) in
            isCancelled = true
            return (Array(activeExportSessions.values), Array(activeAssetReaders.values))
        }
        active.0.forEach { $0.cancelExport() }
        active.1.forEach { $0.cancelReading() }
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
        _ = locked(stateLock) {
            activeExportSessions.removeValue(forKey: ObjectIdentifier(session))
        }
    }

    private func registerAssetReader(_ reader: AVAssetReader) {
        let shouldCancel = locked(stateLock) { () -> Bool in
            activeAssetReaders[ObjectIdentifier(reader)] = reader
            return isCancelled
        }
        if shouldCancel {
            reader.cancelReading()
        }
    }

    private func unregisterAssetReader(_ reader: AVAssetReader) {
        _ = locked(stateLock) {
            activeAssetReaders.removeValue(forKey: ObjectIdentifier(reader))
        }
    }

    private func cancelActiveExportSessions() {
        let sessions = locked(stateLock) { Array(activeExportSessions.values) }
        sessions.forEach { $0.cancelExport() }
    }

    private func cancelActiveAssetReaders() {
        let readers = locked(stateLock) { Array(activeAssetReaders.values) }
        readers.forEach { $0.cancelReading() }
    }

    private static let minimumInternalChunkDuration: TimeInterval = 120
    private static let minimumExportableDuration: TimeInterval = 0.05
    private static let temporaryExportFilePrefix = ".avs_tmp_"
    private static let abandonedTemporaryFileAge: TimeInterval = 24 * 60 * 60
    private static let estimatedAudioBitRate = 192_000
    private static let fallbackFrameDurationTimescale: CMTimeScale = 600_000

    private static func adaptiveExportConcurrencyLimit() -> Int {
        let cores = Swift.max(ProcessInfo.processInfo.activeProcessorCount, 1)

        // Each export job still uses the hardware media encoder, so throughput does not scale
        // linearly with CPU cores. Keep low-core machines conservative and cap high-core
        // machines at a value that can be tuned upward after device-specific measurements.
        if cores <= 4 {
            return Swift.max(1, cores / 2)
        }
        return Swift.min(8, Swift.max(4, cores / 3))
    }

    private static func maxConcurrentSegmentExports(segmentCount: Int) -> Int {
        Swift.max(1, Swift.min(segmentCount, adaptiveExportConcurrencyLimit()))
    }

    private static func sourceExportRanges(
        sourceStartTime: TimeInterval,
        trimmedDuration: TimeInterval,
        outputTimeOffset: CMTime,
        maxChunkCount: Int,
        sourceFrameDuration: CMTime
    ) -> [SourceExportRange] {
        let requestedDuration = Swift.max(trimmedDuration, 0)
        guard requestedDuration >= minimumExportableDuration else { return [] }

        let frameDurationSeconds = CMTimeGetSeconds(sourceFrameDuration)
        guard frameDurationSeconds.isFinite, frameDurationSeconds > 0 else { return [] }

        let requestedStart = Swift.max(sourceStartTime, 0)
        let requestedEnd = requestedStart + requestedDuration
        let startFrame = Swift.max(
            0,
            frameIndex(
                at: requestedStart,
                frameDurationSeconds: frameDurationSeconds,
                rounding: .up
            )
        )
        let endFrame = Swift.max(
            startFrame,
            frameIndex(
                at: requestedEnd,
                frameDurationSeconds: frameDurationSeconds,
                rounding: .down
            )
        )
        let totalFrameCount = endFrame - startFrame
        guard totalFrameCount > 0 else { return [] }

        let alignedDuration = Double(totalFrameCount) * frameDurationSeconds
        guard alignedDuration >= minimumExportableDuration else { return [] }

        let chunkLimit = Swift.max(maxChunkCount, 1)
        let chunksAllowedByDuration = Swift.max(1, Int(alignedDuration / minimumInternalChunkDuration))
        let chunksAllowedByFrames = totalFrameCount > Int64(Int.max)
            ? Int.max
            : Swift.max(1, Int(totalFrameCount))
        let chunkCount = Swift.min(chunkLimit, chunksAllowedByDuration, chunksAllowedByFrames)

        guard chunkCount > 1 else {
            return [SourceExportRange(
                sourceStartFrame: startFrame,
                frameCount: totalFrameCount,
                sourceFrameDuration: sourceFrameDuration,
                outputStart: outputTimeOffset
            )]
        }

        let baseFrameCount = totalFrameCount / Int64(chunkCount)
        let remainderFrames = totalFrameCount % Int64(chunkCount)
        var nextSourceStartFrame = startFrame
        var nextOutputStart = outputTimeOffset
        var ranges: [SourceExportRange] = []
        ranges.reserveCapacity(chunkCount)

        for chunkIndex in 0..<chunkCount {
            let chunkFrameCount = baseFrameCount + (Int64(chunkIndex) < remainderFrames ? 1 : 0)
            let range = SourceExportRange(
                sourceStartFrame: nextSourceStartFrame,
                frameCount: chunkFrameCount,
                sourceFrameDuration: sourceFrameDuration,
                outputStart: nextOutputStart
            )
            ranges.append(range)
            nextSourceStartFrame += chunkFrameCount
            nextOutputStart = range.outputEnd
        }

        return ranges
    }

    private static func frameIndex(
        at seconds: TimeInterval,
        frameDurationSeconds: TimeInterval,
        rounding: FloatingPointRoundingRule
    ) -> Int64 {
        let rawFrame = seconds / frameDurationSeconds
        let tolerance = 1e-7
        switch rounding {
        case .up:
            return Int64(ceil(rawFrame - tolerance))
        case .down:
            return Int64(floor(rawFrame + tolerance))
        default:
            return Int64(rawFrame.rounded(rounding))
        }
    }

    private static func outputTimeOffset(_ seconds: TimeInterval) -> CMTime {
        CMTime(
            seconds: Swift.max(seconds, 0),
            preferredTimescale: fallbackFrameDurationTimescale
        )
    }

    private static func mergedAudioExportRanges(
        videoURL: URL,
        ranges: [SourceExportRange]
    ) -> [SourceAudioExportRange] {
        guard let first = ranges.first, let last = ranges.last else { return [] }
        let duration = CMTimeSubtract(last.sourceEnd, first.sourceStart)
        guard CMTimeGetSeconds(duration) > 0 else { return [] }
        return [
            SourceAudioExportRange(
                videoURL: videoURL,
                range: SourceExportRange(
                    sourceStart: first.sourceStart,
                    sourceDuration: duration,
                    outputStart: first.outputStart
                )
            )
        ]
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
        onStatus: @escaping StatusCallback = { _ in },
        progress: @escaping ProgressCallback
    ) async throws {
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        Self.cleanUpAbandonedTemporaryFiles(in: config.outputURL.deletingLastPathComponent())

        let timeSyncSnapshot = await timeSync.makeExportCopy()
        let asset = AVURLAsset(url: videoURL)
        let assetDuration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw ExportError.noVideos
        }
        let sourceFrameDuration = await Self.sourceFrameDuration(
            for: videoTrack,
            fallback: TimeInterval(config.frameRate)
        )
        let totalSeconds = CMTimeGetSeconds(assetDuration)
        let trimmedDuration = trimSettings.trimmedDuration(original: totalSeconds)
        let ranges = Self.sourceExportRanges(
            sourceStartTime: trimSettings.startTrim,
            trimmedDuration: trimmedDuration,
            outputTimeOffset: Self.outputTimeOffset(outputTimeOffset),
            maxChunkCount: Self.adaptiveExportConcurrencyLimit(),
            sourceFrameDuration: sourceFrameDuration
        )
        guard !ranges.isEmpty else {
            throw ExportError.exportFailed("カットの結果、書き出せる映像がありません")
        }
        try Self.checkAvailableCapacity(
            for: config.outputURL,
            estimatedOutputBytes: Self.estimatedOutputBytes(
                duration: ranges.reduce(0) { $0 + $1.duration },
                config: config
            )
        )

        if ranges.count > 1 {
            try await exportSingleVideoInRanges(
                videoURL: videoURL,
                timeSync: timeSyncSnapshot,
                segmentIndex: segmentIndex,
                ranges: ranges,
                overlayRenderer: overlayRenderer,
                config: config,
                onStatus: onStatus,
                progress: progress
            )
        } else if let range = ranges.first {
            try await exportSingleVideoRange(
                videoURL: videoURL,
                timeSync: timeSyncSnapshot,
                segmentIndex: segmentIndex,
                sourceRange: range,
                includeAudio: true,
                overlayRenderer: overlayRenderer,
                config: config,
                progress: progress
            )
        }
    }

    private func exportSingleVideoRange(
        videoURL: URL,
        timeSync: TimeSync.ExportSnapshot,
        segmentIndex: Int,
        sourceRange: SourceExportRange,
        includeAudio: Bool,
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        progress: @escaping ProgressCallback
    ) async throws {
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        let sourceStartTime = sourceRange.sourceStartTime
        let duration = sourceRange.duration
        let outputTimeOffset = sourceRange.outputStartTime
        exportLog(
            "START seg=\(segmentIndex) url=\(videoURL.lastPathComponent) " +
            "sourceStart=\(String(format: "%.1f", sourceStartTime))s " +
            "duration=\(String(format: "%.1f", duration))s " +
            "audio=\(includeAudio)"
        )

        let asset    = AVURLAsset(url: videoURL)
        let assetDuration = try await asset.load(.duration)
        let tracks   = try await asset.load(.tracks)

        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw ExportError.noVideos
        }
        let audioTrack = includeAudio ? tracks.first(where: { $0.mediaType == .audio }) : nil
        let sourceFrameRate = await Self.sourceFrameRate(
            for: videoTrack,
            fallback: TimeInterval(config.frameRate)
        )
        let totalSeconds = CMTimeGetSeconds(assetDuration)
        exportLog("asset loaded: \(String(format: "%.1f", totalSeconds))s hasAudio=\(audioTrack != nil)")

        let clampedSourceStart = Swift.max(sourceStartTime, 0)
        let availableDuration = Swift.max(totalSeconds - clampedSourceStart, 0)
        let exportDuration = Swift.min(duration, availableDuration)
        guard exportDuration >= Self.minimumExportableDuration else {
            throw ExportError.exportFailed("書き出す時間範囲が空です")
        }

        // Build a mutable composition to attach a videoComposition
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.cannotCreateWriter }

        let boundedDuration = CMTimeCompare(sourceRange.sourceDuration, CMTime(seconds: exportDuration, preferredTimescale: sourceRange.sourceTimescale)) <= 0
            ? sourceRange.sourceDuration
            : CMTime(seconds: exportDuration, preferredTimescale: sourceRange.sourceTimescale)
        let timeRange = CMTimeRange(start: sourceRange.sourceStart, duration: boundedDuration)
        let rangeDuration = timeRange.duration
        compVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
        try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        let compAudioTrack: AVMutableCompositionTrack?
        if let audioTrack {
            let audioTrackTimeRange = try await audioTrack.load(.timeRange)
            if let audioInsertion = Self.clampedAudioInsertion(
                requestedRange: timeRange,
                audioTrackTimeRange: audioTrackTimeRange,
                destinationStart: .zero
            ) {
                guard let audioCompositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw ExportError.exportFailed("音声トラックを出力に追加できませんでした")
                }

                do {
                    try audioCompositionTrack.insertTimeRange(
                        audioInsertion.range,
                        of: audioTrack,
                        at: audioInsertion.start
                    )
                } catch {
                    throw ExportError.exportFailed(Self.audioTransferFailureMessage(error: error))
                }
                compAudioTrack = audioCompositionTrack
            } else {
                compAudioTrack = nil
            }
        } else {
            compAudioTrack = nil
        }

        // Per-frame overlay compositing.
        // AVVideoComposition(asset:applyingCIFiltersWithHandler:) invokes the closure for every
        // frame — unlike customVideoCompositorClass which is silently bypassed on macOS 26.
        let capturedTimeSync = timeSync
        let rendererHolder = OverlayRendererHolder()
        let capturedSegIdx   = segmentIndex
        let capturedSourceStart = clampedSourceStart
        let capturedOutputOffset = outputTimeOffset
        let overlayCache = OverlayFrameCache(
            quantum: config.overlayCacheQuantum,
            sourceFrameRate: sourceFrameRate,
            textOverlays: overlayRenderer.textOverlays
        )

        let videoComposition = AVVideoComposition(asset: composition) { [rendererHolder] request in
            let t = CMTimeGetSeconds(request.compositionTime)
            // TimeSync expects playback time within the source segment. For split ranges,
            // that is the subrange source start plus the local composition time.
            let sourceVideoTime = capturedSourceStart + t
            let globalPlaybackTime = capturedOutputOffset + t

            guard let renderer = rendererHolder.get() else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            let dp = capturedTimeSync.dataPoint(segmentIndex: capturedSegIdx, playbackTime: sourceVideoTime)
            let elapsed = capturedTimeSync.elapsedTime(segmentIndex: capturedSegIdx, playbackTime: sourceVideoTime)

            guard let dp, let elapsed else {
                guard !renderer.textOverlays.isEmpty else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }

                autoreleasepool {
                    if let overlayCI = overlayCache.textOnlyImage(
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
                return
            }

            autoreleasepool {
                let recordingState = capturedTimeSync.recordingState(segmentIndex: capturedSegIdx, playbackTime: sourceVideoTime)
                let displayedDataPoint = recordingState == .noRecording ? dp.withoutLiveMetrics() : dp
                if let overlayCI = overlayCache.image(
                    sourceVideoTime: sourceVideoTime,
                    dataPoint: displayedDataPoint,
                    elapsedTime: elapsed,
                    globalPlaybackTime: globalPlaybackTime,
                    recordingState: recordingState,
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
        let overlayRenderSize = Self.validOverlayRenderSize(
            videoComposition.renderSize,
            fallback: overlayRenderer.videoSize
        )
        rendererHolder.set(overlayRenderer.makeExportCopy(videoSize: overlayRenderSize))
        exportLog(
            "overlay renderSize=\(Self.formatSize(overlayRenderSize)) " +
            "sourceRendererSize=\(Self.formatSize(overlayRenderer.videoSize)) " +
            "outputConfig=\(config.width)x\(config.height)"
        )

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }

        let sourceVideoProperties = await Self.sourceVideoProperties(for: videoTrack)
        let sourceAudioProperties = await Self.sourceAudioProperties(for: audioTrack)
        do {
            try await exportCompositionWithWriter(
                composition: composition,
                videoComposition: videoComposition,
                videoTrack: compVideoTrack,
                audioTrack: compAudioTrack,
                sourceVideoProperties: sourceVideoProperties,
                sourceAudioProperties: sourceAudioProperties,
                duration: rangeDuration,
                config: config,
                sourceFrameRate: sourceFrameRate,
                progress: progress
            )
        } catch {
            Self.removePartialOutputIfNeeded(at: config.outputURL)
            throw error
        }

        progress(1.0, 0)
        exportLog("DONE seg=\(segmentIndex)")
    }

    private static func sourceFrameRate(for track: AVAssetTrack, fallback: TimeInterval) async -> TimeInterval {
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)).map { TimeInterval($0) } ?? 0
        if nominalFrameRate.isFinite, nominalFrameRate > 0 {
            return nominalFrameRate
        }
        return fallback.isFinite && fallback > 0 ? fallback : 30
    }

    private static func sourceFrameDuration(for track: AVAssetTrack, fallback: TimeInterval) async -> CMTime {
        if let minFrameDuration = try? await track.load(.minFrameDuration) {
            let seconds = CMTimeGetSeconds(minFrameDuration)
            if seconds.isFinite, seconds > 0, minFrameDuration.value > 0, minFrameDuration.timescale > 0 {
                return minFrameDuration
            }
        }

        let frameRate = await sourceFrameRate(for: track, fallback: fallback)
        let fps = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        return CMTime(
            seconds: 1.0 / fps,
            preferredTimescale: fallbackFrameDurationTimescale
        )
    }

    private func exportCompositionWithWriter(
        composition: AVAsset,
        videoComposition: AVVideoComposition,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        sourceVideoProperties: SourceVideoProperties,
        sourceAudioProperties: SourceAudioProperties,
        duration: CMTime,
        config: ExportConfig,
        sourceFrameRate: TimeInterval,
        progress: @escaping ProgressCallback
    ) async throws {
        let writerSettings = Self.writerOutputSettings(
            for: config,
            sourceVideoProperties: sourceVideoProperties,
            sourceAudioProperties: sourceAudioProperties,
            sourceFrameRate: sourceFrameRate,
            hasAudio: audioTrack != nil
        )

        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: writerSettings.videoReaderSettings
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.cannotCreateWriter
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: Self.audioReaderOutputSettings()
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            } else {
                throw ExportError.exportFailed("音声トラックを読み込みに追加できませんでした")
            }
        }

        let writer = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: writerSettings.videoSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.cannotCreateWriter
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            guard let audioSettings = writerSettings.audioSettings else {
                throw ExportError.exportFailed("音声の書き出し設定を作成できませんでした")
            }

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ExportError.exportFailed("音声トラックを書き出しに追加できませんでした")
            }
            writer.add(input)
            audioInput = input
        }

        registerAssetReader(reader)
        defer { unregisterAssetReader(reader) }

        exportLog(
            "starting AVAssetWriter codec=\(writerSettings.codec.rawValue) " +
            "bitrate=\(config.bitRate) hdr=\(sourceVideoProperties.isHDR) " +
            "10bit=\(sourceVideoProperties.is10Bit)"
        )

        guard writer.startWriting() else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "書き出し開始に失敗しました")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ExportError.exportFailed(reader.error?.localizedDescription ?? "読み込み開始に失敗しました")
        }
        writer.startSession(atSourceTime: .zero)

        let exportStart = Date()
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.appendSamples(
                            from: videoOutput,
                            to: videoInput,
                            reader: reader,
                            writer: writer,
                            duration: duration,
                            mediaDescription: "映像",
                            exportStart: exportStart,
                            reportProgress: true,
                            progress: progress
                        )
                    }

                    if let audioOutput, let audioInput {
                        group.addTask {
                            try await self.appendSamples(
                                from: audioOutput,
                                to: audioInput,
                                reader: reader,
                                writer: writer,
                                duration: duration,
                                mediaDescription: "音声",
                                exportStart: exportStart,
                                reportProgress: false,
                                progress: progress
                            )
                        }
                    }

                    do {
                        try await group.waitForAll()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            } onCancel: {
                reader.cancelReading()
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if cancellationRequested || Task.isCancelled {
                throw ExportError.cancelled
            }
            throw error
        }

        if cancellationRequested || Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.exportFailed(reader.error?.localizedDescription ?? "映像の読み込みに失敗しました")
        }
        guard writer.status == .writing else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "映像の書き込みに失敗しました")
        }

        await Self.finishWriting(writer)

        if cancellationRequested || Task.isCancelled || writer.status == .cancelled {
            throw ExportError.cancelled
        }
        guard writer.status == .completed else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "エクスポート失敗")
        }
        exportLog("writer finished: status=\(writer.status.rawValue) error=none")
    }

    private func appendSamples(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        duration: CMTime,
        mediaDescription: String,
        exportStart: Date,
        reportProgress: Bool,
        progress: @escaping ProgressCallback
    ) async throws {
        let durationSeconds = CMTimeGetSeconds(duration)

        while true {
            if cancellationRequested || Task.isCancelled || reader.status == .cancelled || writer.status == .cancelled {
                throw ExportError.cancelled
            }
            if writer.status == .failed {
                throw ExportError.exportFailed(Self.mediaFailureMessage(
                    mediaDescription: mediaDescription,
                    action: "書き込み",
                    error: writer.error
                ))
            }
            if reader.status == .failed {
                throw ExportError.exportFailed(Self.mediaFailureMessage(
                    mediaDescription: mediaDescription,
                    action: "読み込み",
                    error: reader.error
                ))
            }

            while !input.isReadyForMoreMediaData {
                if cancellationRequested || Task.isCancelled || reader.status == .cancelled || writer.status == .cancelled {
                    throw ExportError.cancelled
                }
                if writer.status == .failed {
                    throw ExportError.exportFailed(Self.mediaFailureMessage(
                        mediaDescription: mediaDescription,
                        action: "書き込み",
                        error: writer.error
                    ))
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return
            }

            if !input.append(sampleBuffer) {
                throw ExportError.exportFailed(Self.mediaFailureMessage(
                    mediaDescription: mediaDescription,
                    action: "書き込み",
                    error: writer.error
                ))
            }

            if reportProgress, durationSeconds.isFinite, durationSeconds > 0 {
                let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let seconds = CMTimeGetSeconds(sampleTime)
                if seconds.isFinite {
                    let fraction = Swift.min(
                        Swift.max(seconds / durationSeconds, 0),
                        finalConcatenationProgressStart
                    )
                    let elapsed = Date().timeIntervalSince(exportStart)
                    let estimated = fraction > 0.01 ? elapsed / fraction - elapsed : nil
                    progress(fraction, estimated)
                }
            }
        }
    }

    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private static func writerOutputSettings(
        for config: ExportConfig,
        sourceVideoProperties: SourceVideoProperties,
        sourceAudioProperties: SourceAudioProperties,
        sourceFrameRate: TimeInterval,
        hasAudio: Bool
    ) -> WriterOutputSettings {
        let codec: AVVideoCodecType = sourceVideoProperties.requiresHEVCMain10 ? .hevc : .h264
        let assistant = AVOutputSettingsAssistant(
            preset: outputSettingsPreset(for: config, codec: codec)
        )
        if let formatDescription = sourceVideoProperties.formatDescription {
            assistant?.sourceVideoFormat = formatDescription
        }
        if let formatDescription = sourceAudioProperties.formatDescription {
            assistant?.sourceAudioFormat = formatDescription
        }
        let frameRate = sourceFrameRate.isFinite && sourceFrameRate > 0 ? sourceFrameRate : TimeInterval(config.frameRate)
        let roundedFrameRate = Swift.max(Int(frameRate.rounded()), 1)
        assistant?.sourceVideoAverageFrameDuration = CMTime(value: 1, timescale: CMTimeScale(roundedFrameRate))

        var videoSettings = assistant?.videoSettings ?? fallbackVideoSettings(
            config: config,
            codec: codec
        )
        videoSettings[AVVideoCodecKey] = codec
        videoSettings[AVVideoWidthKey] = config.width
        videoSettings[AVVideoHeightKey] = config.height

        var compression = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        compression[AVVideoAverageBitRateKey] = config.bitRate
        compression[AVVideoExpectedSourceFrameRateKey] = roundedFrameRate
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2
        if codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String
            compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = true
            videoSettings[AVVideoAllowWideColorKey] = true
            if let colorProperties = sourceVideoProperties.writerColorProperties {
                videoSettings[AVVideoColorPropertiesKey] = colorProperties.videoSettings
            }
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression

        var videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: sourceVideoProperties.requiresHEVCMain10
                ? Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                : Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height
        ]
        if sourceVideoProperties.requiresHEVCMain10 {
            videoReaderSettings[AVVideoAllowWideColorKey] = true
            if let colorProperties = sourceVideoProperties.writerColorProperties {
                videoReaderSettings[AVVideoColorPropertiesKey] = colorProperties.videoSettings
            }
        }

        let audioSettings = hasAudio
            ? (assistant?.audioSettings ?? fallbackAudioSettings(sourceAudioProperties))
            : nil

        return WriterOutputSettings(
            videoSettings: videoSettings,
            audioSettings: audioSettings,
            videoReaderSettings: videoReaderSettings,
            codec: codec
        )
    }

    private static func fallbackVideoSettings(
        config: ExportConfig,
        codec: AVVideoCodecType
    ) -> [String: Any] {
        [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.bitRate
            ]
        ]
    }

    private static func fallbackAudioSettings(_ properties: SourceAudioProperties) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 192_000,
            AVSampleRateKey: properties.sampleRate ?? 48_000,
            AVNumberOfChannelsKey: properties.channelCount ?? 2
        ]
    }

    private static func audioReaderOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM
        ]
    }

    private static func audioTransferFailureMessage(error: Error) -> String {
        "音声のコピーに失敗しました: \(error.localizedDescription)"
    }

    private static func clampedAudioInsertion(
        requestedRange: CMTimeRange,
        audioTrackTimeRange: CMTimeRange,
        destinationStart: CMTime
    ) -> (range: CMTimeRange, start: CMTime)? {
        let clampedRange = CMTimeRangeGetIntersection(requestedRange, otherRange: audioTrackTimeRange)
        guard !clampedRange.isEmpty else { return nil }

        let clippedSourceOffset = CMTimeSubtract(clampedRange.start, requestedRange.start)
        return (
            range: clampedRange,
            start: CMTimeAdd(destinationStart, clippedSourceOffset)
        )
    }

    private static func mediaFailureMessage(
        mediaDescription: String,
        action: String,
        error: Error?
    ) -> String {
        let baseMessage = "\(mediaDescription)の\(action)に失敗しました"
        guard let error else { return baseMessage }
        return "\(baseMessage): \(error.localizedDescription)"
    }

    private static func outputSettingsPreset(
        for config: ExportConfig,
        codec: AVVideoCodecType
    ) -> AVOutputSettingsPreset {
        if codec == .hevc {
            return config.width >= 3840 ? .hevc3840x2160 : .hevc1920x1080
        }
        if config.width >= 3840 { return .preset3840x2160 }
        if config.width >= 1920 { return .preset1920x1080 }
        return .preset1280x720
    }

    private static func sourceVideoProperties(for track: AVAssetTrack) async -> SourceVideoProperties {
        let formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
        let formatDescription = formatDescriptions.first
        var detectedColorProperties: SourceColorProperties?
        for formatDescription in formatDescriptions {
            if let properties = sourceColorProperties(from: formatDescription) {
                detectedColorProperties = properties
                break
            }
        }
        let is10Bit = formatDescriptions.contains { formatDescription in
            bitDepth(from: formatDescription).map { $0 >= 10 } ?? false
        }
        let inferredHDR = detectedColorProperties?.isHDR == true ||
            formatDescriptions.contains { isHDRTagged(formatDescription: $0) }

        return SourceVideoProperties(
            formatDescription: formatDescription,
            colorProperties: detectedColorProperties ?? (inferredHDR ? .defaultHLG : nil),
            is10Bit: is10Bit || inferredHDR
        )
    }

    private static func sourceAudioProperties(for track: AVAssetTrack?) async -> SourceAudioProperties {
        guard let track else { return .none }
        let formatDescription = (try? await track.load(.formatDescriptions))?.first
        guard let formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return SourceAudioProperties(formatDescription: formatDescription, sampleRate: nil, channelCount: nil)
        }

        let audioStreamDescription = streamDescription.pointee
        return SourceAudioProperties(
            formatDescription: formatDescription,
            sampleRate: audioStreamDescription.mSampleRate > 0 ? audioStreamDescription.mSampleRate : nil,
            channelCount: audioStreamDescription.mChannelsPerFrame > 0
                ? Int(audioStreamDescription.mChannelsPerFrame)
                : nil
        )
    }

    private static func bitDepth(from formatDescription: CMFormatDescription) -> Int? {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
            return nil
        }
        return (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
    }

    private static func isHDRTagged(formatDescription: CMFormatDescription) -> Bool {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
            return false
        }

        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transferFunction = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String

        return primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) ||
            transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ||
            transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    private static func sourceColorProperties(from formatDescription: CMFormatDescription) -> SourceColorProperties? {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
            return nil
        }

        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transferFunction = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let yCbCrMatrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String

        guard let primaries, let transferFunction, let yCbCrMatrix else {
            return nil
        }

        return SourceColorProperties(
            primaries: primaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix
        )
    }

    private func exportSingleVideoInRanges(
        videoURL: URL,
        timeSync: TimeSync.ExportSnapshot,
        segmentIndex: Int,
        ranges: [SourceExportRange],
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        onStatus: @escaping StatusCallback,
        progress: @escaping ProgressCallback
    ) async throws {
        guard !ranges.isEmpty else {
            throw ExportError.exportFailed("カットの結果、書き出せる映像がありません")
        }

        let tempDir = try Self.createTemporaryExportDirectory(
            in: config.outputURL.deletingLastPathComponent()
        )
        defer { Self.removeTemporaryExportDirectory(tempDir) }
        let tempURLs = ranges.map { _ in
            tempDir
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
        }
        let videoOnlyURL = tempDir
            .appendingPathComponent("video_only")
            .appendingPathExtension("mp4")
        defer {
            Self.removeTemporaryExportFiles(tempURLs)
            try? FileManager.default.removeItem(at: videoOnlyURL)
        }

        let rangeDurations = ranges.map { $0.duration }
        let totalDuration = rangeDurations.reduce(0, +)
        let progressAggregator = ConcatenatedProgress(
            segmentDurations: rangeDurations,
            totalDuration: totalDuration
        )
        let maxConcurrentExports = Self.maxConcurrentSegmentExports(segmentCount: ranges.count)
        exportLog(
            "splitting seg=\(segmentIndex) into \(ranges.count) ranges " +
            "with concurrency=\(maxConcurrentExports)"
        )

        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextRangeIndex = 0

            func enqueueNextRange() throws {
                if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
                guard nextRangeIndex < ranges.count else { return }

                let rangeIndex = nextRangeIndex
                nextRangeIndex += 1

                let range = ranges[rangeIndex]
                let tempURL = tempURLs[rangeIndex]
                let rangeRenderer = overlayRenderer.makeExportCopy()
                var rangeConfig = config
                rangeConfig.outputURL = tempURL

                group.addTask {
                    if self.cancellationRequested || Task.isCancelled { throw ExportError.cancelled }

                    try await self.exportSingleVideoRange(
                        videoURL: videoURL,
                        timeSync: timeSync,
                        segmentIndex: segmentIndex,
                        sourceRange: range,
                        includeAudio: false,
                        overlayRenderer: rangeRenderer,
                        config: rangeConfig
                    ) { fraction, _ in
                        progressAggregator.update(
                            segmentIndex: rangeIndex,
                            fraction: fraction,
                            progress: progress
                        )
                    }

                    return rangeIndex
                }
            }

            for _ in 0..<maxConcurrentExports {
                try enqueueNextRange()
            }

            do {
                while let _ = try await group.next() {
                    try enqueueNextRange()
                }
            } catch {
                group.cancelAll()
                cancelActiveExportSessions()
                cancelActiveAssetReaders()
                throw error
            }
        }

        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        onStatus("動画を結合中...")
        try await concatenateExportedFiles(
            tempURLs,
            outputURL: videoOnlyURL,
            progressStart: finalVideoOnlyConcatenationProgressStart,
            progressSpan: finalVideoOnlyConcatenationProgressSpan,
            progress: progress
        )
        Self.removeTemporaryExportFiles(tempURLs)
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        onStatus("音声を処理中...")
        try await muxVideoWithSinglePassAudio(
            videoOnlyURL: videoOnlyURL,
            audioRanges: Self.mergedAudioExportRanges(videoURL: videoURL, ranges: ranges),
            outputURL: config.outputURL,
            progressStart: finalAudioMuxProgressStart,
            progressSpan: finalAudioMuxProgressSpan,
            progress: progress
        )
        progress(1.0, 0)
    }

    // MARK: - Concatenated Export

    /// Export each segment or internal time range with correct overlay, then passthrough-concat.
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
                overlayRenderer: overlayRenderer, config: config,
                onStatus: onStatus, progress: progress)
            return
        }
        Self.cleanUpAbandonedTemporaryFiles(in: config.outputURL.deletingLastPathComponent())

        let timeSyncSnapshot = await timeSync.makeExportCopy()

        // Phase 1: pre-load durations and source frame cadence.
        var segmentDurations: [Double] = []
        var segmentFrameDurations: [CMTime] = []
        for (segIdx, url) in videoURLs.enumerated() {
            let asset = AVURLAsset(url: url)
            let dur = CMTimeGetSeconds(try await asset.load(.duration))
            let tracks = try await asset.load(.tracks)
            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                throw ExportError.noVideos
            }
            let trim = segIdx < trimSettings.count ? trimSettings[segIdx] : TrimSettings()
            segmentDurations.append(Swift.max(trim.trimmedDuration(original: dur), 0))
            segmentFrameDurations.append(await Self.sourceFrameDuration(
                for: videoTrack,
                fallback: TimeInterval(config.frameRate)
            ))
        }

        // Phase 2: export each segment/range to temp file.
        // Keep intermediates next to the final output so large exports stay on
        // the user-selected volume instead of filling the system drive.
        let tempDir = try Self.createTemporaryExportDirectory(
            in: config.outputURL.deletingLastPathComponent()
        )
        defer { Self.removeTemporaryExportDirectory(tempDir) }
        let concurrencyLimit = Self.adaptiveExportConcurrencyLimit()
        let chunkBudgetPerSegment = videoURLs.count < concurrencyLimit
            ? Swift.max(1, Int(ceil(Double(concurrencyLimit) / Double(videoURLs.count))))
            : 1
        var jobs: [TimeRangeExportJob] = []
        var audioRanges: [SourceAudioExportRange] = []
        var runningOutputTime = CMTime.zero
        for (segIdx, url) in videoURLs.enumerated() {
            let trim = segIdx < trimSettings.count ? trimSettings[segIdx] : TrimSettings()
            let ranges = Self.sourceExportRanges(
                sourceStartTime: trim.startTrim,
                trimmedDuration: segmentDurations[segIdx],
                outputTimeOffset: runningOutputTime,
                maxChunkCount: chunkBudgetPerSegment,
                sourceFrameDuration: segmentFrameDurations[segIdx]
            )
            audioRanges.append(contentsOf: Self.mergedAudioExportRanges(videoURL: url, ranges: ranges))
            if let lastRange = ranges.last {
                runningOutputTime = lastRange.outputEnd
            }

            for (rangeIdx, range) in ranges.enumerated() {
                let statusMessage = ranges.count == 1
                    ? "動画 \(segIdx + 1) / \(videoURLs.count) を書き出し中..."
                    : "動画 \(segIdx + 1) / \(videoURLs.count) 範囲 \(rangeIdx + 1) / \(ranges.count) を書き出し中..."
                let tempURL = tempDir
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")
                jobs.append(TimeRangeExportJob(
                    videoURL: url,
                    segmentIndex: segIdx,
                    range: range,
                    tempURL: tempURL,
                    statusMessage: statusMessage
                ))
            }
        }
        guard !jobs.isEmpty else {
            throw ExportError.exportFailed("カットの結果、書き出せる映像がありません")
        }
        try Self.checkAvailableCapacity(
            for: config.outputURL,
            estimatedOutputBytes: Self.estimatedOutputBytes(
                duration: jobs.reduce(0) { $0 + $1.range.duration },
                config: config
            )
        )
        let tempURLs = jobs.map { $0.tempURL }
        let videoOnlyURL = tempDir
            .appendingPathComponent("video_only")
            .appendingPathExtension("mp4")
        defer {
            Self.removeTemporaryExportFiles(tempURLs)
            try? FileManager.default.removeItem(at: videoOnlyURL)
        }

        let jobDurations = jobs.map { $0.range.duration }
        let totalDuration = jobDurations.reduce(0, +)
        let progressAggregator = ConcatenatedProgress(
            segmentDurations: jobDurations,
            totalDuration: totalDuration
        )
        let maxConcurrentExports = Self.maxConcurrentSegmentExports(segmentCount: jobs.count)
        exportLog(
            "exporting \(videoURLs.count) segments as \(jobs.count) jobs " +
            "with concurrency=\(maxConcurrentExports)"
        )

        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextJobIndex = 0

            func enqueueNextJob() throws {
                if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
                guard nextJobIndex < jobs.count else { return }

                let jobIndex = nextJobIndex
                nextJobIndex += 1

                let job = jobs[jobIndex]
                onStatus(job.statusMessage)

                let jobRenderer = overlayRenderer.makeExportCopy()
                var jobConfig = config
                jobConfig.outputURL = job.tempURL

                group.addTask {
                    if self.cancellationRequested || Task.isCancelled { throw ExportError.cancelled }

                    try await self.exportSingleVideoRange(
                        videoURL: job.videoURL,
                        timeSync: timeSyncSnapshot,
                        segmentIndex: job.segmentIndex,
                        sourceRange: job.range,
                        includeAudio: false,
                        overlayRenderer: jobRenderer,
                        config: jobConfig
                    ) { fraction, _ in
                        progressAggregator.update(
                            segmentIndex: jobIndex,
                            fraction: fraction,
                            progress: progress
                        )
                    }

                    return jobIndex
                }
            }

            for _ in 0..<maxConcurrentExports {
                try enqueueNextJob()
            }

            do {
                while let _ = try await group.next() {
                    try enqueueNextJob()
                }
            } catch {
                group.cancelAll()
                cancelActiveExportSessions()
                cancelActiveAssetReaders()
                throw error
            }
        }

        // Phase 3: passthrough concat (no re-encode)
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        onStatus("動画を結合中...")

        try await concatenateExportedFiles(
            tempURLs,
            outputURL: videoOnlyURL,
            progressStart: finalVideoOnlyConcatenationProgressStart,
            progressSpan: finalVideoOnlyConcatenationProgressSpan,
            progress: progress
        )
        Self.removeTemporaryExportFiles(tempURLs)
        if cancellationRequested || Task.isCancelled { throw ExportError.cancelled }
        onStatus("音声を処理中...")
        try await muxVideoWithSinglePassAudio(
            videoOnlyURL: videoOnlyURL,
            audioRanges: audioRanges,
            outputURL: config.outputURL,
            progressStart: finalAudioMuxProgressStart,
            progressSpan: finalAudioMuxProgressSpan,
            progress: progress
        )
        progress(1.0, 0)
    }

    // MARK: - Helpers

    private func concatenateExportedFiles(
        _ tempURLs: [URL],
        outputURL: URL,
        progressStart: Double = finalConcatenationProgressStart,
        progressSpan: Double = finalConcatenationProgressSpan,
        progress: @escaping ProgressCallback
    ) async throws {
        guard !tempURLs.isEmpty else {
            throw ExportError.exportFailed("カットの結果、書き出せる映像がありません")
        }

        let concatComp = AVMutableComposition()
        guard let vcTrack = concatComp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.cannotCreateWriter }
        let acTrack = concatComp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        var hasPreferredTransform = false
        for tempURL in tempURLs {
            let a = AVURLAsset(url: tempURL)
            let d = try await a.load(.duration)
            let r = CMTimeRange(start: .zero, duration: d)
            let t = try await a.load(.tracks)
            if let vt = t.first(where: { $0.mediaType == .video }) {
                if !hasPreferredTransform {
                    vcTrack.preferredTransform = try await vt.load(.preferredTransform)
                    hasPreferredTransform = true
                }
                try vcTrack.insertTimeRange(r, of: vt, at: insertTime)
            }
            if let at = t.first(where: { $0.mediaType == .audio }) {
                guard let acTrack else {
                    throw ExportError.exportFailed("音声トラックを結合出力に追加できませんでした")
                }
                do {
                    try acTrack.insertTimeRange(r, of: at, at: insertTime)
                } catch {
                    throw ExportError.exportFailed(Self.audioTransferFailureMessage(error: error))
                }
            }
            insertTime = CMTimeAdd(insertTime, d)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        do {
            guard let concatSession = AVAssetExportSession(
                asset: concatComp, presetName: AVAssetExportPresetPassthrough
            ) else { throw ExportError.cannotCreateWriter }
            concatSession.outputURL      = outputURL
            concatSession.outputFileType = .mp4
            registerExportSession(concatSession)
            defer { unregisterExportSession(concatSession) }

            progress(progressStart, nil)
            let concatStart = Date()
            let progressPollingTask = Task {
                while !Task.isCancelled {
                    let phaseProgress = Swift.min(Swift.max(Double(concatSession.progress), 0), 1)
                    let overallProgress = progressStart + phaseProgress * progressSpan
                    let elapsed = Date().timeIntervalSince(concatStart)
                    let remaining = phaseProgress > 0.01 && phaseProgress < 1
                        ? Swift.max(elapsed / phaseProgress - elapsed, 0)
                        : nil
                    progress(overallProgress, remaining)

                    try? await Task.sleep(nanoseconds: concatenationProgressPollInterval)
                }
            }

            await withTaskCancellationHandler {
                await concatSession.export()
            } onCancel: {
                concatSession.cancelExport()
            }
            progressPollingTask.cancel()
            await progressPollingTask.value

            if cancellationRequested || Task.isCancelled || concatSession.status == .cancelled {
                throw ExportError.cancelled
            }
            guard concatSession.status == .completed else {
                throw ExportError.exportFailed(
                    concatSession.error?.localizedDescription ?? "結合に失敗しました")
            }
        } catch {
            Self.removePartialOutputIfNeeded(at: outputURL)
            throw error
        }
    }

    private func muxVideoWithSinglePassAudio(
        videoOnlyURL: URL,
        audioRanges: [SourceAudioExportRange],
        outputURL: URL,
        progressStart: Double,
        progressSpan: Double,
        progress: @escaping ProgressCallback
    ) async throws {
        let finalComp = AVMutableComposition()

        let videoAsset = AVURLAsset(url: videoOnlyURL)
        let videoDuration = try await videoAsset.load(.duration)
        let videoTracks = try await videoAsset.load(.tracks)
        guard let sourceVideoTrack = videoTracks.first(where: { $0.mediaType == .video }),
              let compVideoTrack = finalComp.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.cannotCreateWriter
        }

        compVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        try compVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )

        var compAudioTrack: AVMutableCompositionTrack?
        var hasAudio = false
        for audioRange in audioRanges {
            let sourceAsset = AVURLAsset(url: audioRange.videoURL)
            let sourceTracks = try await sourceAsset.load(.tracks)
            guard let sourceAudioTrack = sourceTracks.first(where: { $0.mediaType == .audio }) else {
                continue
            }
            let sourceAudioTimeRange = try await sourceAudioTrack.load(.timeRange)

            guard let audioInsertion = Self.clampedAudioInsertion(
                requestedRange: audioRange.range.sourceTimeRange,
                audioTrackTimeRange: sourceAudioTimeRange,
                destinationStart: audioRange.range.outputStart
            ) else {
                continue
            }

            if compAudioTrack == nil {
                compAudioTrack = finalComp.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            }
            guard let compAudioTrack else {
                throw ExportError.exportFailed("音声トラックを結合出力に追加できませんでした")
            }

            do {
                try compAudioTrack.insertTimeRange(
                    audioInsertion.range,
                    of: sourceAudioTrack,
                    at: audioInsertion.start
                )
                hasAudio = true
            } catch {
                throw ExportError.exportFailed(Self.audioTransferFailureMessage(error: error))
            }
        }

        guard hasAudio else {
            try Self.replaceOutput(withTemporaryFile: videoOnlyURL, outputURL: outputURL)
            progress(1.0, 0)
            return
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        do {
            guard let muxSession = AVAssetExportSession(
                asset: finalComp,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw ExportError.cannotCreateWriter
            }
            muxSession.outputURL = outputURL
            muxSession.outputFileType = .mp4
            registerExportSession(muxSession)
            defer { unregisterExportSession(muxSession) }

            progress(progressStart, nil)
            let muxStart = Date()
            let progressPollingTask = Task {
                while !Task.isCancelled {
                    let phaseProgress = Swift.min(Swift.max(Double(muxSession.progress), 0), 1)
                    let overallProgress = progressStart + phaseProgress * progressSpan
                    let elapsed = Date().timeIntervalSince(muxStart)
                    let remaining = phaseProgress > 0.01 && phaseProgress < 1
                        ? Swift.max(elapsed / phaseProgress - elapsed, 0)
                        : nil
                    progress(overallProgress, remaining)

                    try? await Task.sleep(nanoseconds: concatenationProgressPollInterval)
                }
            }

            await withTaskCancellationHandler {
                await muxSession.export()
            } onCancel: {
                muxSession.cancelExport()
            }
            progressPollingTask.cancel()
            await progressPollingTask.value

            if cancellationRequested || Task.isCancelled || muxSession.status == .cancelled {
                throw ExportError.cancelled
            }
            guard muxSession.status == .completed else {
                throw ExportError.exportFailed(
                    muxSession.error?.localizedDescription ?? "音声の処理に失敗しました")
            }
        } catch {
            Self.removePartialOutputIfNeeded(at: outputURL)
            throw error
        }
    }

    private static func replaceOutput(withTemporaryFile sourceURL: URL, outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        do {
            try FileManager.default.moveItem(at: sourceURL, to: outputURL)
        } catch {
            throw ExportError.exportFailed("出力ファイルの配置に失敗しました: \(error.localizedDescription)")
        }
    }

    private static func createTemporaryExportDirectory(in directoryURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let temporaryDirectoryURL = directoryURL.appendingPathComponent(
            temporaryExportFilePrefix + UUID().uuidString,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: false
            )
            return temporaryDirectoryURL
        } catch {
            throw ExportError.exportFailed("一時フォルダの作成に失敗しました: \(error.localizedDescription)")
        }
    }

    private static func removeTemporaryExportDirectory(_ directoryURL: URL) {
        do {
            try FileManager.default.removeItem(at: directoryURL)
            exportLog("removed temporary export directory: \(directoryURL.lastPathComponent)")
        } catch {
            exportLog(
                "failed to remove temporary export directory " +
                "\(directoryURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private static func removeTemporaryExportFiles(_ urls: [URL]) {
        let fileManager = FileManager.default
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
                exportLog("removed temporary export file: \(url.lastPathComponent)")
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                    continue
                }
                exportLog(
                    "failed to remove temporary export file " +
                    "\(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func cleanUpAbandonedTemporaryFiles(in directoryURL: URL) {
        let fileManager = FileManager.default
        let temporaryItems: [URL]
        do {
            temporaryItems = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]
            ).filter { $0.lastPathComponent.hasPrefix(temporaryExportFilePrefix) }
        } catch {
            exportLog("failed to inspect abandoned temporary export files: \(error.localizedDescription)")
            return
        }

        let now = Date()
        for url in temporaryItems {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            } catch {
                exportLog(
                    "failed to inspect temporary export item " +
                    "\(url.lastPathComponent): \(error.localizedDescription)"
                )
                continue
            }

            guard let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) > abandonedTemporaryFileAge else {
                continue
            }

            do {
                try fileManager.removeItem(at: url)
                exportLog("removed abandoned temporary export item: \(url.lastPathComponent)")
            } catch {
                exportLog(
                    "failed to remove abandoned temporary export item " +
                    "\(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func checkAvailableCapacity(
        for outputURL: URL,
        estimatedOutputBytes: Int64
    ) throws {
        let requiredBytes = requiredCapacityBytes(estimatedOutputBytes: estimatedOutputBytes)
        guard requiredBytes > 0 else { return }

        let availableBytes = try availableCapacityBytes(for: outputURL.deletingLastPathComponent())
        guard availableBytes >= requiredBytes else {
            throw ExportError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    private static func estimatedOutputBytes(duration: TimeInterval, config: ExportConfig) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }

        let totalBitRate = Swift.max(config.bitRate + estimatedAudioBitRate, 1)
        let estimatedBytes = (duration * Double(totalBitRate) / 8).rounded(.up)
        guard estimatedBytes.isFinite, estimatedBytes > 0 else { return Int64.max }
        guard estimatedBytes < 9_000_000_000_000_000_000 else { return Int64.max }
        return Int64(estimatedBytes)
    }

    private static func requiredCapacityBytes(estimatedOutputBytes: Int64) -> Int64 {
        let doubled = estimatedOutputBytes.multipliedReportingOverflow(by: 2)
        return doubled.overflow ? Int64.max : doubled.partialValue
    }

    private static func availableCapacityBytes(for directoryURL: URL) throws -> Int64 {
        do {
            let values = try directoryURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
            if let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
            throw ExportError.exportFailed("保存先の空き容量を確認できませんでした")
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.exportFailed("保存先の空き容量を確認できませんでした: \(error.localizedDescription)")
        }
    }

    private static func removePartialOutputIfNeeded(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            exportLog("removed partial export output: \(url.lastPathComponent)")
        } catch {
            exportLog("failed to remove partial export output \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func formatByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func validOverlayRenderSize(_ renderSize: CGSize, fallback: CGSize) -> CGSize {
        guard renderSize.width > 0, renderSize.height > 0 else { return fallback }
        return renderSize
    }

    private static func formatSize(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}
