import Foundation
import AVFoundation

/// Reads metadata from GoPro MP4 files.
final class VideoMetadataReader {

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

        // Load creation date
        let creationDate = try? await asset.load(.creationDate)
        let date = try? await creationDate?.load(.dateValue)

        return VideoMetadata(
            url: url,
            creationDate: date,
            duration: durationSeconds
        )
    }

    /// Read metadata from multiple video files.
    func read(urls: [URL]) async throws -> [VideoMetadata] {
        try await withThrowingTaskGroup(of: VideoMetadata.self) { group in
            for url in urls {
                group.addTask {
                    try await self.read(url: url)
                }
            }
            var results: [VideoMetadata] = []
            for try await metadata in group {
                results.append(metadata)
            }
            // Sort by creation date
            return results.sorted { a, b in
                guard let dateA = a.creationDate else { return false }
                guard let dateB = b.creationDate else { return true }
                return dateA < dateB
            }
        }
    }
}
