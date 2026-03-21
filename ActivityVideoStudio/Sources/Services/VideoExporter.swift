import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import AppKit

/// Exports video with overlay composited, supporting multi-video concatenation.
final class VideoExporter {

    enum ExportError: Error, LocalizedError {
        case noVideos
        case cannotCreateWriter
        case cannotCreateReader
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideos: return "エクスポートする動画がありません"
            case .cannotCreateWriter: return "動画ライターを作成できませんでした"
            case .cannotCreateReader: return "動画リーダーを作成できませんでした"
            case .exportFailed(let msg): return "エクスポート失敗: \(msg)"
            case .cancelled: return "エクスポートがキャンセルされました"
            }
        }
    }

    struct ExportConfig {
        var outputURL: URL
        var width: Int = 1920
        var height: Int = 1080
        var bitRate: Int = 10_000_000  // 10 Mbps
        var frameRate: Int = 30
    }

    /// Progress callback: fraction (0-1), estimated remaining seconds
    typealias ProgressCallback = @Sendable (Double, TimeInterval?) -> Void

    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    /// Export a single video with overlay.
    func exportSingleVideo(
        videoURL: URL,
        timeSync: TimeSync,
        segmentIndex: Int,
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        progress: @escaping ProgressCallback
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw ExportError.noVideos
        }
        let audioTrack = tracks.first(where: { $0.mediaType == .audio })

        // Setup reader
        let reader = try AVAssetReader(asset: asset)

        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(ao)
            audioOutput = ao
        }

        // Setup writer
        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }

        let writer = try AVAssetWriter(outputURL: config.outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.bitRate,
                AVVideoMaxKeyFrameIntervalKey: config.frameRate
            ]
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerVideoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height
            ]
        )
        writer.add(writerVideoInput)

        var writerAudioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            writerAudioInput = ai
        }

        // Start
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let startTime = Date()

        // Process video frames
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.avs.export.video")
            writerVideoInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self = self else { return }

                while writerVideoInput.isReadyForMoreMediaData {
                    if self.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: ExportError.cancelled)
                        return
                    }

                    guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                        writerVideoInput.markAsFinished()
                        continuation.resume()
                        return
                    }

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let seconds = CMTimeGetSeconds(presentationTime)

                    // Compose overlay
                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        let overlayBuffer = self.compositeOverlay(
                            pixelBuffer: pixelBuffer,
                            timeSync: timeSync,
                            segmentIndex: segmentIndex,
                            playbackTime: seconds,
                            renderer: overlayRenderer,
                            width: config.width,
                            height: config.height
                        )
                        pixelBufferAdaptor.append(overlayBuffer ?? pixelBuffer, withPresentationTime: presentationTime)
                    }

                    // Progress
                    if totalSeconds > 0 {
                        let fraction = seconds / totalSeconds
                        let elapsed = Date().timeIntervalSince(startTime)
                        let estimated = fraction > 0 ? elapsed / fraction - elapsed : nil
                        progress(min(fraction, 1.0), estimated)
                    }
                }
            }
        }

        // Process audio
        if let audioOutput = audioOutput, let writerAudioInput = writerAudioInput {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "com.avs.export.audio")
                writerAudioInput.requestMediaDataWhenReady(on: queue) {
                    while writerAudioInput.isReadyForMoreMediaData {
                        guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                            writerAudioInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                        writerAudioInput.append(sampleBuffer)
                    }
                }
            }
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Unknown error")
        }

        progress(1.0, 0)
    }

    /// Concatenate multiple videos and export with overlay.
    func exportConcatenated(
        videoURLs: [URL],
        timeSync: TimeSync,
        overlayRenderer: OverlayRenderer,
        config: ExportConfig,
        progress: @escaping ProgressCallback
    ) async throws {
        guard !videoURLs.isEmpty else { throw ExportError.noVideos }

        if videoURLs.count == 1 {
            try await exportSingleVideo(
                videoURL: videoURLs[0],
                timeSync: timeSync,
                segmentIndex: 0,
                overlayRenderer: overlayRenderer,
                config: config,
                progress: progress
            )
            return
        }

        // For multiple videos: compose with AVMutableComposition
        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.cannotCreateWriter }

        let audioCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertTime = CMTime.zero

        for url in videoURLs {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            if let vTrack = tracks.first(where: { $0.mediaType == .video }) {
                try videoCompositionTrack.insertTimeRange(timeRange, of: vTrack, at: insertTime)
            }
            if let aTrack = tracks.first(where: { $0.mediaType == .audio }) {
                try audioCompositionTrack?.insertTimeRange(timeRange, of: aTrack, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime, duration)
        }

        // Export the composition as a single temporary file, then overlay
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        exportSession?.outputURL = tempURL
        exportSession?.outputFileType = .mp4

        await exportSession?.export()

        guard exportSession?.status == .completed else {
            throw ExportError.exportFailed(exportSession?.error?.localizedDescription ?? "Merge failed")
        }

        // Now export with overlay
        try await exportSingleVideo(
            videoURL: tempURL,
            timeSync: timeSync,
            segmentIndex: 0,
            overlayRenderer: overlayRenderer,
            config: config,
            progress: progress
        )

        // Cleanup temp
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Overlay compositing

    private func compositeOverlay(
        pixelBuffer: CVPixelBuffer,
        timeSync: TimeSync,
        segmentIndex: Int,
        playbackTime: Double,
        renderer: OverlayRenderer,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard let dataPoint = timeSync.dataPoint(segmentIndex: segmentIndex, playbackTime: playbackTime),
              let elapsed = timeSync.elapsedTime(segmentIndex: segmentIndex, playbackTime: playbackTime),
              let overlayImage = renderer.render(dataPoint: dataPoint, elapsedTime: elapsed) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Draw overlay on top of existing frame
        context.draw(overlayImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixelBuffer
    }
}
