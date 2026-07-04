import Foundation
import AVFoundation
import CoreGraphics

/// Reads metadata from GoPro MP4 files.
final class VideoMetadataReader {
    struct ReadResult {
        let url: URL
        let result: Result<VideoMetadata, Error>
    }

    enum ReadError: Error, LocalizedError {
        case cannotLoadMetadata
        case cannotLoadDuration

        var errorDescription: String? {
            switch self {
            case .cannotLoadMetadata: return "動画のメタデータを読み取れませんでした"
            case .cannotLoadDuration: return "動画の長さを取得できませんでした"
            }
        }
    }

    /// Read metadata from a video file at the given URL.
    func read(url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)

        // Load duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite else {
            throw ReadError.cannotLoadDuration
        }

        let tracks = try await asset.load(.tracks)
        let videoTrack = tracks.first(where: { $0.mediaType == .video })
        let naturalSize = try await videoTrack?.load(.naturalSize)
        let preferredTransform = try await videoTrack?.load(.preferredTransform)
        let displaySize = Self.displaySize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )

        // Load creation date
        let creationDate = try? await asset.load(.creationDate)
        let date = try? await creationDate?.load(.dateValue)

        return VideoMetadata(
            url: url,
            creationDate: date,
            duration: durationSeconds,
            naturalSize: displaySize
        )
    }

    /// Read metadata from multiple video files.
    func read(urls: [URL]) async -> [ReadResult] {
        await withTaskGroup(of: (Int, ReadResult).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let metadata = try await self.read(url: url)
                        return (index, ReadResult(url: url, result: .success(metadata)))
                    } catch {
                        return (index, ReadResult(url: url, result: .failure(error)))
                    }
                }
            }
            var indexedResults: [(Int, ReadResult)] = []
            for await result in group {
                indexedResults.append(result)
            }
            return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func displaySize(
        naturalSize: CGSize?,
        preferredTransform: CGAffineTransform?
    ) -> CGSize? {
        guard let naturalSize else { return nil }
        guard let preferredTransform else { return naturalSize }

        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized

        return CGSize(
            width: abs(transformed.width),
            height: abs(transformed.height)
        )
    }
}
