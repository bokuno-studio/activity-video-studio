import Foundation
import AppKit

/// ViewModel for the export flow.
@MainActor
final class ExportViewModel: ObservableObject {

    enum Resolution: String, CaseIterable {
        case r720p, r1080p, r4k

        var title: String {
            switch self {
            case .r720p: return "720p (1280x720)"
            case .r1080p: return "1080p (1920x1080)"
            case .r4k: return "4K (3840x2160)"
            }
        }

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
    @Published var quitWhenDone = false
    @Published var preventSleepDuringExport = true {
        didSet {
            if isExporting {
                beginSleepPreventionIfNeeded()
            }
        }
    }
    @Published var isExporting = false
    @Published var exportComplete = false
    @Published var progress: Double = 0
    @Published var estimatedRemaining: TimeInterval?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var alert: UserFacingAlert?
    @Published var isCancelling = false
    @Published var outputURL: URL?
    @Published var outputFileName: String = ""
    @Published var nativeVideoWidth: Int = 0 {
        didSet { clampResolutionToSource() }
    }

    var videoURLs: [URL] = []
    var trimSettings: [TrimSettings] = []
    var timeSync: TimeSync?
    var overlayRenderer: OverlayRenderer?
    var onDismiss: (() -> Void)?

    var videoCount: Int { videoURLs.count }
    var canExport: Bool { !videoURLs.isEmpty && timeSync != nil }
    var availableResolutions: [Resolution] {
        let maxWidth = nativeVideoWidth > 0 ? nativeVideoWidth : Resolution.r1080p.width
        let resolutions = Resolution.allCases.filter { $0.width <= maxWidth }
        return resolutions.isEmpty ? [.r720p] : resolutions
    }
    var sourceResolutionText: String? {
        nativeVideoWidth > 0 ? "元動画幅: \(nativeVideoWidth)px" : nil
    }

    private var exporter: VideoExporter?
    private var sleepPreventionActivity: NSObjectProtocol?

    func startExport() {
        clampResolutionToSource()

        if outputFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputFileName = defaultOutputFileName()
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "保存先フォルダを選択"
        panel.prompt = "エクスポート"

        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let directoryURL = panel.url else { return }
                self?.startExport(in: directoryURL)
            }
        }
    }

    func resetOutputFileName() {
        outputFileName = defaultOutputFileName()
    }

    private func startExport(in directoryURL: URL) {
        guard let timeSync = timeSync, let renderer = overlayRenderer else {
            isExporting = false
            let message = "動画とFITファイルを読み込んでから、もう一度エクスポートしてください。"
            errorMessage = message
            alert = UserFacingAlert(title: "エクスポートの準備ができていません", message: message)
            return
        }

        let directoryAccess = directoryURL.startAccessingSecurityScopedResource()
        let url = uniqueOutputURL(in: directoryURL, fileName: normalizedOutputFileName())
        outputURL = url
        isExporting = true
        exportComplete = false
        errorMessage = nil
        alert = nil
        isCancelling = false
        statusMessage = nil
        progress = 0
        beginSleepPreventionIfNeeded()

        let exporter = VideoExporter()
        self.exporter = exporter

        let config = VideoExporter.ExportConfig(
            outputURL: url,
            width: resolution.width,
            height: resolution.height,
            bitRate: quality.bitRate
        )

        let concatenateVideos = self.concatenateVideos
        let videoURLs = self.videoURLs
        let trimSettings = self.trimSettings
        Task.detached(priority: .userInitiated) { [weak self] in
            var isAccessingDirectory = directoryAccess
            defer {
                if isAccessingDirectory { directoryURL.stopAccessingSecurityScopedResource() }
            }

            do {
                if concatenateVideos && videoURLs.count > 1 {
                    try await exporter.exportConcatenated(
                        videoURLs: videoURLs,
                        trimSettings: trimSettings,
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
                        trimSettings: trimSettings.first ?? TrimSettings(),
                        overlayRenderer: renderer,
                        config: config
                    ) { [weak self] fraction, remaining in
                        Task { @MainActor in
                            self?.progress = fraction
                            self?.estimatedRemaining = remaining
                        }
                    }
                }

                if isAccessingDirectory {
                    directoryURL.stopAccessingSecurityScopedResource()
                    isAccessingDirectory = false
                }
                await MainActor.run { [weak self] in
                    self?.finishExportSuccessfully()
                }
            } catch {
                if isAccessingDirectory {
                    directoryURL.stopAccessingSecurityScopedResource()
                    isAccessingDirectory = false
                }
                await MainActor.run { [weak self] in
                    self?.finishExportWithError(error)
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        isCancelling = true
        statusMessage = "キャンセル中..."
        exporter?.cancel()
    }

    func dismiss() {
        onDismiss?()
    }

    private func clampResolutionToSource() {
        let available = availableResolutions
        guard !available.contains(resolution), let fallback = available.last else { return }
        resolution = fallback
    }

    private func beginSleepPreventionIfNeeded() {
        endSleepPreventionIfNeeded()
        guard preventSleepDuringExport else { return }
        sleepPreventionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "Video export"
        )
    }

    private func endSleepPreventionIfNeeded() {
        guard let activity = sleepPreventionActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        sleepPreventionActivity = nil
    }

    private func finishExportSuccessfully() {
        isExporting = false
        isCancelling = false
        exportComplete = true
        endSleepPreventionIfNeeded()

        if quitWhenDone {
            NSApplication.shared.terminate(nil)
        }
    }

    private func finishExportWithError(_ error: Error) {
        isExporting = false
        if isCancelling || isCancellation(error) {
            isCancelling = false
            statusMessage = "キャンセルしました"
            errorMessage = nil
            endSleepPreventionIfNeeded()
            return
        }

        isCancelling = false
        let message = exportErrorMessage(error)
        errorMessage = message
        alert = UserFacingAlert(
            title: "エクスポートに失敗しました",
            message: message
        )
        endSleepPreventionIfNeeded()
    }

    private func isCancellation(_ error: Error) -> Bool {
        if let exportError = error as? VideoExporter.ExportError,
           case .cancelled = exportError {
            return true
        }
        return false
    }

    private func exportErrorMessage(_ error: Error) -> String {
        var details = [error.localizedDescription]
        if let localizedError = error as? LocalizedError {
            if let failureReason = localizedError.failureReason {
                details.append(failureReason)
            }
            if let recoverySuggestion = localizedError.recoverySuggestion {
                details.append(recoverySuggestion)
            }
        }
        details.append("保存先の空き容量、アクセス権、動画コーデックを確認してから再試行してください。")
        return details.joined(separator: "\n\n")
    }

    private func defaultOutputFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: Date())
        let baseName = videoURLs.first?.deletingPathExtension().lastPathComponent ?? "activity_overlay"
        return "\(dateString)_\(baseName).mp4"
    }

    private func normalizedOutputFileName() -> String {
        let trimmed = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? defaultOutputFileName() : trimmed
        let sanitized = fallback
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return sanitized.lowercased().hasSuffix(".mp4") ? sanitized : sanitized + ".mp4"
    }

    private func uniqueOutputURL(in directoryURL: URL, fileName: String) -> URL {
        let fileManager = FileManager.default
        let originalURL = directoryURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: originalURL.path) else { return originalURL }

        let base = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        for index in 2...999 {
            let candidate = directoryURL
                .appendingPathComponent("\(base)-\(index)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directoryURL
            .appendingPathComponent("\(base)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
