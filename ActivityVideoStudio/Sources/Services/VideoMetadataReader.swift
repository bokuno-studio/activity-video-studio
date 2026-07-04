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

        // Prefer the timezone-bearing QuickTime creation date when available.
        let quickTimeCreationDate = await Self.quickTimeCreationDate(from: asset)
        let creationDate = try? await asset.load(.creationDate)
        let fallbackDate = try? await creationDate?.load(.dateValue)
        let date = quickTimeCreationDate ?? fallbackDate

        return VideoMetadata(
            url: url,
            creationDate: date,
            quickTimeCreationDate: quickTimeCreationDate,
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

    private static func quickTimeCreationDate(from asset: AVURLAsset) async -> Date? {
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let creationDateItems = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .quickTimeMetadataCreationDate
        )

        for item in creationDateItems {
            guard let stringValue = try? await item.load(.stringValue),
                  let date = parseOffsetCreationDate(stringValue) else {
                continue
            }
            return date
        }

        return nil
    }

    private static func parseOffsetCreationDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasUTCOffset(trimmed) else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ssZ"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private static func hasUTCOffset(_ value: String) -> Bool {
        value.range(
            of: #"([zZ]|[+-]\d{2}:?\d{2})$"#,
            options: .regularExpression
        ) != nil
    }
}
