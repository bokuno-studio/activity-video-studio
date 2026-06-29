import Foundation
import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreLocation
import UniformTypeIdentifiers

struct UserFacingAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#if DEBUG
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
#endif

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
    @Published var showExport = false
    @Published var showFileList = false
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var trackCoordinates: [CLLocationCoordinate2D] = []
    @Published var statusMessage: String?
    @Published var alert: UserFacingAlert?
    @Published var isLoading = false
    @Published var loadingMessage: String?
    @Published var loadingProgress: Double?
    @Published var projectWarningMessage: String?
    @Published var textOverlays: [TextOverlay] = []
    @Published var trimSettings: [TrimSettings] = []
    @Published var playbackRate: Float = 1.0
    @Published var chapterMarkers: [ChapterMarker] = []
    @Published private(set) var projectURL: URL?
    @Published private(set) var isProjectEdited = false
    @Published private(set) var videoNativeWidth: Int = 0

    let playbackRateOptions: [Float] = [0.5, 1.0, 2.0, 4.0, 8.0, 10.0]

    let player = AVPlayer()
    let overlaySettings = OverlaySettings()

    var canSaveProject: Bool {
        fitURL != nil || !videoURLs.isEmpty || !textOverlays.isEmpty || !chapterMarkers.isEmpty
    }

    var windowTitle: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "無題"
    }

    func showError(title: String, message: String) {
        alert = UserFacingAlert(title: title, message: message)
    }

    private func showError(title: String, error: Error, recovery: String? = nil) {
        var details: [String] = []
        details.append(error.localizedDescription)
        if let localizedError = error as? LocalizedError {
            if let failureReason = localizedError.failureReason {
                details.append(failureReason)
            }
            if let recoverySuggestion = localizedError.recoverySuggestion {
                details.append(recoverySuggestion)
            }
        }
        if let recovery {
            details.append(recovery)
        }
        alert = UserFacingAlert(title: title, message: details.joined(separator: "\n\n"))
    }

    private func beginLoading(_ message: String, progress: Double? = nil) {
        loadingMessage = message
        loadingProgress = progress
        isLoading = true
    }

    private func endLoading() {
        isLoading = false
        loadingMessage = nil
        loadingProgress = nil
    }

    private func updateLoading(_ message: String, progress: Double? = nil) {
        loadingMessage = message
        loadingProgress = progress
    }

    private var projectEditedCancellables: Set<AnyCancellable> = []
    private(set) var timeSync: TimeSync?
    private var overlayRenderer: OverlayRenderer?
    private var timeObserver: Any?
    private var trimPreviewSeekTask: Task<Void, Never>?
    private var didApplyDefaultFITStartAlignment = false
    private var projectSecurityScopedURLs: [URL] = []
    private(set) var fitDataPoints: [FITDataPoint] = []
    private(set) var fitURL: URL?
    private(set) var videoURLs: [URL] = []
    private(set) var videoMetadatas: [VideoMetadata] = []

    /// Durations of individual video segments, for mapping playback time to segment.
    private var segmentDurations: [TimeInterval] = []

    init() {
        setupTimeObserver()
        setupProjectEditedObservers()
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
        var cliOffset: Double?
        var alignFitStart = false

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
            case "--offset":
                if i + 1 < args.count, let value = Double(args[i + 1]) {
                    cliOffset = value
                    i += 1
                }
            case "--align-fit-start":
                alignFitStart = true
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

        // Apply a manual sync offset before export (GoPro clock-skew correction).
        if let cliOffset { updateSyncOffset(cliOffset) }
        if alignFitStart { alignFitStartToCurrentFrame() }

        let cliTrimSettings = TrimSettings(startTrim: trimStart, endTrim: trimEnd)
        if trimSettings.isEmpty {
            trimSettings = [cliTrimSettings]
        } else {
            trimSettings = trimSettings.indices.map { _ in cliTrimSettings }
        }

        // Per-segment trim override: --trim-start-N <sec> / --trim-end-N <sec>
        for segIdx in 0..<trimSettings.count {
            if let idx = args.firstIndex(of: "--trim-start-\(segIdx)"),
               idx + 1 < args.count, let v = TimeInterval(args[idx + 1]) {
                trimSettings[segIdx].startTrim = v
            }
            if let idx = args.firstIndex(of: "--trim-end-\(segIdx)"),
               idx + 1 < args.count, let v = TimeInterval(args[idx + 1]) {
                trimSettings[segIdx].endTrim = v
            }
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
        var config = VideoExporter.ExportConfig(outputURL: outputURL)
        // Honor CLI --width/--height overrides (read from ProcessInfo; default preserved)
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--width"), idx + 1 < args.count, let w = Int(args[idx + 1]) { config.width = w }
        if let idx = args.firstIndex(of: "--height"), idx + 1 < args.count, let h = Int(args[idx + 1]) { config.height = h }
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
        trimPreviewSeekTask?.cancel()
        for url in projectSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }

    // MARK: - Project save/load

    func presentSaveProjectPanel() {
        let panel = NSSavePanel()
        panel.title = "プロジェクトを保存"
        panel.allowedContentTypes = [Self.projectFileType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultProjectFileName()
        panel.message = "編集状態をプロジェクトとして保存"
        panel.prompt = "保存"

        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { return }
                self?.saveProject(to: url)
            }
        }
    }

    func presentOpenProjectPanel() {
        if canSaveProject, !confirmDiscardCurrentProject() {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "プロジェクトを開く"
        panel.allowedContentTypes = [Self.projectFileType]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "保存したプロジェクトを開く"
        panel.prompt = "開く"

        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { return }
                await self?.loadProject(from: url)
            }
        }
    }

    func saveProject(to url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let document = ProjectDocument(
                version: ProjectDocument.currentVersion,
                fitFile: fitURL.map(ProjectFileReference.init(url:)),
                videoFiles: videoURLs.map(ProjectFileReference.init(url:)),
                syncOffset: syncOffset,
                trimSettings: trimSettings,
                overlaySettings: OverlaySettingsSnapshot(settings: overlaySettings),
                textOverlays: textOverlays,
                chapterMarkers: chapterMarkers
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            projectURL = url
            isProjectEdited = false
            projectWarningMessage = nil
            statusMessage = "プロジェクト保存完了: \(url.lastPathComponent)"
        } catch {
            showError(
                title: "プロジェクトを保存できませんでした",
                error: error,
                recovery: "保存先の空き容量とアクセス権を確認して、もう一度保存してください。"
            )
        }
    }

    func loadProject(from url: URL) async {
        beginLoading("プロジェクトを読み込み中...")
        defer { endLoading() }

        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(ProjectDocument.self, from: data)
            await restoreProject(document, sourceName: url.lastPathComponent)
            projectURL = url
            isProjectEdited = false
        } catch {
            showError(
                title: "プロジェクトを読み込めませんでした",
                error: error,
                recovery: ".avsprojファイルが壊れていないか、参照先にアクセスできるか確認してください。"
            )
        }
    }

    private func restoreProject(_ document: ProjectDocument, sourceName: String) async {
        resetProjectState()

        var warnings: [String] = []
        if document.version > ProjectDocument.currentVersion {
            warnings.append("新しいプロジェクト形式です")
        }

        if let fitFile = document.fitFile {
            if let url = resolveProjectFile(fitFile, warnings: &warnings) {
                loadFITFile(url: url)
                if !fitLoaded {
                    warnings.append("FITを読み込めません: \(url.lastPathComponent)")
                }
            }
        }

        document.overlaySettings.apply(to: overlaySettings)
        syncOffset = document.syncOffset

        let reader = VideoMetadataReader()
        for (index, file) in document.videoFiles.enumerated() {
            guard let url = resolveProjectFile(file, warnings: &warnings) else { continue }
            loadingMessage = "動画を読み込み中... \(index + 1) / \(document.videoFiles.count)"

            do {
                let metadata = try await reader.read(url: url)
                videoURLs.append(url)
                videoMetadatas.append(metadata)
                if index < document.trimSettings.count {
                    trimSettings.append(document.trimSettings[index])
                } else {
                    trimSettings.append(TrimSettings())
                }
            } catch {
                warnings.append("動画を読み込めません: \(url.lastPathComponent)")
            }
        }

        segmentDurations = videoMetadatas.map { $0.duration }
        videoLoaded = !videoURLs.isEmpty
        updateNativeVideoWidth()
        setupTimeSync()

        textOverlays = document.textOverlays
        chapterMarkers = document.chapterMarkers.sorted { $0.time < $1.time }

        if videoLoaded {
            if await rebuildComposition() {
                overlayRenderer?.textOverlays = textOverlays
                overlayRenderer?.trackCoordinates = trackCoordinates
                overlayRenderer?.allDataPoints = fitDataPoints
                overlayRenderer?.buildElevationGainCache()
            } else {
                warnings.append("動画タイムラインを復元できませんでした")
            }
        }

        seek(to: 0)
        didApplyDefaultFITStartAlignment = true
        projectWarningMessage = warningMessage(from: warnings)
        statusMessage = "プロジェクト読み込み完了: \(sourceName)"
    }

    private func resetProjectState() {
        trimPreviewSeekTask?.cancel()
        trimPreviewSeekTask = nil
        stopAccessingProjectResources()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        isSeeking = false
        duration = 0
        overlayImage = nil
        currentCoordinate = nil
        trackCoordinates = []
        fitDataPoints = []
        fitLoaded = false
        videoLoaded = false
        fitURL = nil
        videoURLs = []
        videoMetadatas = []
        trimSettings = []
        textOverlays = []
        chapterMarkers = []
        syncOffset = 0
        timeSync = nil
        overlayRenderer = nil
        segmentDurations = []
        videoNativeWidth = 0
        projectWarningMessage = nil
        projectURL = nil
        isProjectEdited = false
        didApplyDefaultFITStartAlignment = false
    }

    private func confirmDiscardCurrentProject() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "現在の編集内容を破棄して開きますか？"
        alert.informativeText = "プロジェクトを開くと、読み込み済みファイル、同期、トリム、テキスト、チャプターの現在の編集状態が置き換わります。必要なら先に保存してください。"
        alert.addButton(withTitle: "開く")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func resolveProjectFile(_ reference: ProjectFileReference, warnings: inout [String]) -> URL? {
        let resolved = reference.resolve()
        if resolved.isStale {
            warnings.append("参照情報が古くなっています: \(resolved.url.lastPathComponent)")
        }
        if resolved.usesSecurityScope,
           resolved.url.startAccessingSecurityScopedResource() {
            projectSecurityScopedURLs.append(resolved.url)
        }

        guard FileManager.default.fileExists(atPath: resolved.url.path) else {
            warnings.append("見つかりません: \(reference.displayName)")
            return nil
        }
        return resolved.url
    }

    private func stopAccessingProjectResources() {
        for url in projectSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        projectSecurityScopedURLs.removeAll()
    }

    private func warningMessage(from warnings: [String]) -> String? {
        guard !warnings.isEmpty else { return nil }
        let visible = warnings.prefix(3).joined(separator: " / ")
        let hiddenCount = warnings.count - 3
        if hiddenCount > 0 {
            return "警告: \(visible) ほか\(hiddenCount)件"
        }
        return "警告: \(visible)"
    }

    private func defaultProjectFileName() -> String {
        let baseName = videoURLs.first?.deletingPathExtension().lastPathComponent ?? "ActivityVideoStudio"
        return baseName + ".avsproj"
    }

    private static let projectFileType = UTType(exportedAs: "com.activityvideostudio.project", conformingTo: .json)

    // MARK: - File loading

    func loadFITFile(url: URL) {
        do {
            let parser = FITParser()
            let result = try parser.parse(url: url)
            guard !result.dataPoints.isEmpty else {
                fitDataPoints = []
                fitLoaded = false
                fitURL = nil
                showError(
                    title: "FITを読み込めませんでした",
                    message: "\(url.lastPathComponent) にデータポイントがありません。別のFITファイルを選択してください。"
                )
                return
            }

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
            applyDefaultFITStartAlignmentIfPossible()

            // Update renderer if already exists
            if let renderer = overlayRenderer {
                renderer.allDataPoints = fitDataPoints
                renderer.trackCoordinates = trackCoordinates
                renderer.buildElevationGainCache()
            }

            statusMessage = "FIT: \(fitDataPoints.count) データポイント読み込み完了"
            markProjectEdited()
        } catch {
            showError(
                title: "FITを読み込めませんでした",
                error: error,
                recovery: "対応している.fitファイルか確認してください。"
            )
        }
    }

    func loadVideo(url: URL) async {
        beginLoading("動画を読み込み中...")
        defer { endLoading() }

        let reader = VideoMetadataReader()
        do {
            try await appendVideo(url: url, reader: reader)
            await finishVideoLoading()
        } catch {
            showError(
                title: "動画を読み込めませんでした",
                error: error,
                recovery: "対応形式は .mp4 / .mov / .m4v です。ファイルが破損していないか確認してください。"
            )
        }
    }

    func loadVideos(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard urls.count > 1 else {
            await loadVideo(url: urls[0])
            return
        }

        beginLoading("0 / \(urls.count) 本 読み込み中...", progress: 0)
        defer { endLoading() }

        let reader = VideoMetadataReader()
        var loadedCount = 0
        var failedNames: [String] = []

        for (index, url) in urls.enumerated() {
            updateLoading(
                "\(index + 1) / \(urls.count) 本 読み込み中...",
                progress: Double(index) / Double(urls.count)
            )

            do {
                try await appendVideo(url: url, reader: reader)
                loadedCount += 1
                updateLoading(
                    "\(index + 1) / \(urls.count) 本 読み込み中...",
                    progress: Double(index + 1) / Double(urls.count)
                )
            } catch {
                failedNames.append(url.lastPathComponent)
            }
        }

        guard loadedCount > 0 else {
            showError(
                title: "動画を読み込めませんでした",
                message: "ドロップされた動画を読み込めませんでした。対応形式は .mp4 / .mov / .m4v です。ファイルが破損していないか確認してください。"
            )
            return
        }

        await finishVideoLoading(loadedCount: loadedCount, requestedCount: urls.count)

        if !failedNames.isEmpty {
            showError(
                title: "一部の動画を読み込めませんでした",
                message: "\(failedNames.joined(separator: ", ")) を読み込めませんでした。ファイルが破損していないか確認してください。"
            )
        }
    }

    private func appendVideo(url: URL, reader: VideoMetadataReader) async throws {
        let metadata = try await reader.read(url: url)
        videoURLs.append(url)
        videoMetadatas.append(metadata)
        trimSettings.append(TrimSettings())
    }

    private func finishVideoLoading(loadedCount: Int? = nil, requestedCount: Int? = nil) async {
        sortVideosByCreationDate()
        videoLoaded = true
        setupTimeSync()

        guard await rebuildComposition() else { return }
        applyDefaultFITStartAlignmentIfPossible()

        statusMessage = videoLoadStatusMessage(loadedCount: loadedCount, requestedCount: requestedCount)
        markProjectEdited()
    }

    private func videoLoadStatusMessage(loadedCount: Int? = nil, requestedCount: Int? = nil) -> String {
        let loadSummary: String
        if let loadedCount, let requestedCount, requestedCount > 1 {
            if loadedCount == requestedCount {
                loadSummary = "\(loadedCount)本 読み込み完了"
            } else {
                loadSummary = "\(loadedCount) / \(requestedCount)本 読み込み完了"
            }
        } else {
            loadSummary = "動画読み込み完了"
        }

        var message = "\(loadSummary) (\(videoURLs.count)本, 合計 \(formatDuration(duration)))"
        if let ts = timeSync, let firstSeg = ts.segments.first,
           let fitStart = ts.activityStartTime {
            let offset = fitStart.timeIntervalSince(firstSeg.fitStartTime)
            if offset > 0 {
                message += " | FIT記録開始: \(formatDuration(offset))後"
            }
        }
        return message
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
        updateNativeVideoWidth()
    }

    /// Remove a video at the given index.
    func removeVideo(at index: Int, undoManager: UndoManager? = nil) {
        guard index < videoURLs.count else { return }
        let removedURL = videoURLs.remove(at: index)
        let removedMetadata = videoMetadatas.remove(at: index)
        let removedTrim = trimSettings.remove(at: index)
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.insertVideo(removedURL, metadata: removedMetadata, trim: removedTrim, at: index)
            }
        }
        undoManager?.setActionName("動画削除")

        segmentDurations = videoMetadatas.map { $0.duration }
        videoLoaded = !videoURLs.isEmpty
        updateNativeVideoWidth()
        setupTimeSync()
        if videoLoaded {
            Task { await rebuildComposition() }
        } else {
            player.replaceCurrentItem(with: nil)
            duration = 0
            currentTime = 0
            overlayImage = nil
            overlayRenderer = nil
        }
        markProjectEdited()
    }

    private func insertVideo(_ url: URL, metadata: VideoMetadata, trim: TrimSettings, at index: Int) {
        let insertionIndex = min(max(index, 0), videoURLs.count)
        videoURLs.insert(url, at: insertionIndex)
        videoMetadatas.insert(metadata, at: insertionIndex)
        trimSettings.insert(trim, at: insertionIndex)
        segmentDurations = videoMetadatas.map { $0.duration }
        videoLoaded = true
        updateNativeVideoWidth()
        setupTimeSync()
        Task { await rebuildComposition() }
        markProjectEdited()
    }

    // MARK: - Composition

    /// Build or rebuild AVMutableComposition from all loaded videos.
    @discardableResult
    private func rebuildComposition() async -> Bool {
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
            return true
        } catch {
            showError(
                title: "動画タイムラインを作成できませんでした",
                error: error,
                recovery: "動画ファイルの読み込み権限と空き容量を確認してください。"
            )
            return false
        }
    }

    // MARK: - Playback controls

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            // Clear any stale seeking state so the periodic time observer resumes
            // driving overlay updates the moment playback starts.
            isSeeking = false
            player.rate = playbackRate
        }
        isPlaying.toggle()
    }

    func beginSeeking() {
        isSeeking = true
    }

    func seek(to time: TimeInterval) {
        trimPreviewSeekTask?.cancel()
        trimPreviewSeekTask = nil
        performSeek(to: time, tolerance: .zero, finishSeeking: true)
    }

    func previewTrimSeek(to time: TimeInterval) {
        let target = clampedSeekTime(time)
        currentTime = target
        isSeeking = true

        // Preview seeks use a loose tolerance so the player can settle on a nearby
        // keyframe instead of decoding to an exact frame. On a multi-hour
        // composition an exact (.zero) seek costs seconds of decode, so the exact
        // frame is deferred to commitTrimSeek (drag release / field commit). This
        // is what kept the trim slider feeling heavy on long videos.
        trimPreviewSeekTask?.cancel()
        trimPreviewSeekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // finishSeeking: true clears isSeeking once the preview lands. The
                // previous version left it false, so a trim drag could leave
                // isSeeking stuck true and freeze the overlay during playback
                // (the periodic time observer skips updates while seeking).
                self?.performSeek(
                    to: target,
                    tolerance: CMTime(seconds: 0.5, preferredTimescale: 600),
                    finishSeeking: true
                )
                self?.trimPreviewSeekTask = nil
            }
        }
    }

    func commitTrimSeek(to time: TimeInterval) {
        trimPreviewSeekTask?.cancel()
        trimPreviewSeekTask = nil
        performSeek(to: time, tolerance: .zero, finishSeeking: true)
    }

    func seekToTrimmedTime(_ time: TimeInterval) {
        seek(to: absoluteTime(forTrimmed: time))
    }

    func seekBy(_ seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func skipForward(_ seconds: TimeInterval = 5) {
        seekBy(seconds)
    }

    func skipBackward(_ seconds: TimeInterval = 5) {
        seekBy(-seconds)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.rate = isPlaying ? rate : 0
    }

    func cyclePlaybackRate() {
        if let idx = playbackRateOptions.firstIndex(of: playbackRate) {
            setPlaybackRate(playbackRateOptions[(idx + 1) % playbackRateOptions.count])
        } else {
            setPlaybackRate(1.0)
        }
    }

    /// Seek to the start of trimmed content.
    func seekToTrimStart() {
        let startTrim = trimSettings.first?.startTrim ?? 0
        seek(to: startTrim)
    }

    private func clampedSeekTime(_ time: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, time) }
        return min(max(time, 0), duration)
    }

    private func performSeek(to time: TimeInterval, tolerance: CMTime, finishSeeking: Bool) {
        let target = clampedSeekTime(time)
        currentTime = target
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        if finishSeeking {
            isSeeking = false
        }
        updateOverlay()
    }

    func updateSyncOffset(_ offset: Double) {
        syncOffset = offset
        // Rebuild every segment so the offset applies uniformly across all
        // chapters (not just segment 0). Cheap: only a handful of segments.
        if timeSync != nil { setupTimeSync() }
        updateOverlay()
    }

    /// Map the FIT activity start (0:00 / 0 km) onto the frame currently shown in
    /// the preview. Scrub to the moment the activity actually begins (e.g. crossing
    /// the start line), press this, then fine-tune with the ± nudge controls.
    /// Also handles a large clock offset in one step — e.g. a GoPro whose date was
    /// never set records a 2016 timestamp while the activity is years later.
    /// At playback position 0 this is equivalent to aligning the video start to the
    /// FIT start (the behavior used by the headless --align-fit-start path).
    func alignFitStartToCurrentFrame() {
        guard let creationDate = videoMetadatas.first?.creationDate else {
            showError(
                title: "同期できません",
                message: "動画の撮影時刻を読み取れませんでした。別の動画を読み込むか、手動で同期オフセットを調整してください。"
            )
            return
        }
        guard let fitStart = fitDataPoints.first?.timestamp else {
            showError(
                title: "同期できません",
                message: "FITの開始時刻がありません。データポイントを含むFITファイルを読み込んでください。"
            )
            return
        }
        // Offset so the FIT start lands on the current playback position: at global
        // time `currentTime` the mapped FIT time = creationDate + syncOffset + currentTime,
        // and we want that to equal fitStart.
        updateSyncOffset(fitStart.timeIntervalSince(creationDate) - currentTime)
        statusMessage = "再生位置を活動開始（0:00 / 0km）に合わせました"
    }

    private func applyDefaultFITStartAlignmentIfPossible() {
        guard !didApplyDefaultFITStartAlignment,
              videoLoaded,
              fitLoaded,
              let videoTimeline = videoTimelineRange(),
              let fitStart = fitDataPoints.first?.timestamp,
              let fitEnd = fitDataPoints.last?.timestamp else {
            return
        }

        didApplyDefaultFITStartAlignment = true
        let timelinesOverlap = videoTimeline.start <= fitEnd && fitStart <= videoTimeline.end
        guard !timelinesOverlap else {
            updateOverlay()
            return
        }

        updateSyncOffset(fitStart.timeIntervalSince(videoTimeline.start))
    }

    private func videoTimelineRange() -> (start: Date, end: Date)? {
        var cumulativeOffset: TimeInterval = 0
        var rangeStart: Date?
        var rangeEnd: Date?

        for metadata in videoMetadatas {
            guard let creationDate = metadata.creationDate else { continue }

            let segmentStart = creationDate.addingTimeInterval(cumulativeOffset)
            let segmentEnd = segmentStart.addingTimeInterval(metadata.duration)
            rangeStart = rangeStart.map { min($0, segmentStart) } ?? segmentStart
            rangeEnd = rangeEnd.map { max($0, segmentEnd) } ?? segmentEnd
            cumulativeOffset += metadata.duration
        }

        guard let rangeStart, let rangeEnd else { return nil }
        return (rangeStart, rangeEnd)
    }

    /// Wall-clock time mapped to the first frame of the first video, given the
    /// current sync offset. nil until both a video and FIT are loaded.
    var videoStartDate: Date? { timeSync?.segments.first?.fitStartTime }

    /// Localized (device timezone) description of the current video-start time.
    func videoStartDescription() -> String? {
        guard let date = videoStartDate else { return nil }
        return Self.videoStartFormatter.string(from: date)
    }

    private static let videoStartFormatter: DateFormatter = {
        let f = DateFormatter()
        // Tenths so a ±0.5s fine nudge is visible in the readout.
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.S"
        return f
    }()

    // MARK: - Chapter markers

    func addChapterMarker(undoManager: UndoManager? = nil) {
        let marker = ChapterMarker(time: currentTime)
        chapterMarkers.append(marker)
        chapterMarkers.sort { $0.time < $1.time }
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.removeChapterMarker(id: marker.id)
            }
        }
        undoManager?.setActionName("チャプターマーカー追加")
        statusMessage = "チャプターマーカー追加: \(formatDuration(trimmedTime(for: marker.time)))"
    }

    func removeChapterMarker(id: UUID, undoManager: UndoManager? = nil) {
        guard let index = chapterMarkers.firstIndex(where: { $0.id == id }) else { return }
        let removedMarker = chapterMarkers.remove(at: index)
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.insertChapterMarker(removedMarker, at: index)
            }
        }
        undoManager?.setActionName("チャプターマーカー削除")
    }

    private func insertChapterMarker(_ marker: ChapterMarker, at index: Int) {
        let insertionIndex = min(max(index, 0), chapterMarkers.count)
        chapterMarkers.insert(marker, at: insertionIndex)
        chapterMarkers.sort { $0.time < $1.time }
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

    // MARK: - Export

    func makeExportViewModel() -> ExportViewModel {
        let vm = ExportViewModel()
        vm.videoURLs = videoURLs
        vm.trimSettings = trimSettings
        vm.nativeVideoWidth = videoNativeWidth
        vm.resetOutputFileName()
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
        for metadata in videoMetadatas {
            guard metadata.creationDate != nil else { continue }

            // Create a metadata with adjusted creationDate for chaptered files
            let adjustedMetadata = VideoMetadata(
                url: metadata.url,
                creationDate: metadata.creationDate?.addingTimeInterval(cumulativeOffset),
                duration: metadata.duration,
                naturalSize: metadata.naturalSize
            )
            // Apply the manual sync offset to every segment so the whole video
            // timeline shifts uniformly against the FIT timeline. Applying it to
            // segment 0 only would leave later GoPro chapters mis-aligned.
            timeSync?.addVideo(adjustedMetadata, offsetSeconds: syncOffset)
            cumulativeOffset += metadata.duration
        }
    }

    private func setupProjectEditedObservers() {
        let editedPublishers: [AnyPublisher<Void, Never>] = [
            $syncOffset.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $trimSettings.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $textOverlays.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $chapterMarkers.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            overlaySettings.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(editedPublishers)
            .sink { [weak self] in
                self?.markProjectEdited()
            }
            .store(in: &projectEditedCancellables)
    }

    private func markProjectEdited() {
        isProjectEdited = true
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

    private func updateNativeVideoWidth() {
        let widths = videoMetadatas.compactMap { $0.nativeWidth }.filter { $0 > 0 }
        videoNativeWidth = widths.min() ?? 0
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

        var totalStartTrim: TimeInterval = 0
        var totalEndTrim: TimeInterval = 0

        for i in segmentDurations.indices {
            if i < trimSettings.count {
                totalStartTrim += min(max(trimSettings[i].startTrim, 0), segmentDurations[i])
                totalEndTrim += min(max(trimSettings[i].endTrim, 0), segmentDurations[i])
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

private struct ProjectDocument: Codable {
    static let currentVersion = 1

    var version: Int
    var fitFile: ProjectFileReference?
    var videoFiles: [ProjectFileReference]
    var syncOffset: Double
    var trimSettings: [TrimSettings]
    var overlaySettings: OverlaySettingsSnapshot
    var textOverlays: [TextOverlay]
    var chapterMarkers: [ChapterMarker]
}

private struct ProjectFileReference: Codable {
    var path: String
    var bookmarkData: String?

    init(url: URL) {
        path = url.path
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarkData = data.base64EncodedString()
        }
    }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    func resolve() -> ResolvedProjectFile {
        if let bookmarkData,
           let data = Data(base64Encoded: bookmarkData) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return ResolvedProjectFile(url: url, isStale: isStale, usesSecurityScope: true)
            }
        }

        return ResolvedProjectFile(
            url: URL(fileURLWithPath: path),
            isStale: false,
            usesSecurityScope: false
        )
    }
}

private struct ResolvedProjectFile {
    var url: URL
    var isStale: Bool
    var usesSecurityScope: Bool
}

private struct OverlaySettingsSnapshot: Codable {
    var showTime: Bool
    var showDistance: Bool
    var showHeartRate: Bool
    var showPace: Bool
    var showGrade: Bool
    var showAltitude: Bool
    var showCadence: Bool
    var showElevationGain: Bool
    var showCoreTemp: Bool
    var showMiniMap: Bool
    var showElevationProfile: Bool
    var overlayOpacity: Double
    var z1Max: UInt8
    var z2Max: UInt8
    var z3Max: UInt8
    var z4Max: UInt8

    init(settings: OverlaySettings) {
        showTime = settings.showTime
        showDistance = settings.showDistance
        showHeartRate = settings.showHeartRate
        showPace = settings.showPace
        showGrade = settings.showGrade
        showAltitude = settings.showAltitude
        showCadence = settings.showCadence
        showElevationGain = settings.showElevationGain
        showCoreTemp = settings.showCoreTemp
        showMiniMap = settings.showMiniMap
        showElevationProfile = settings.showElevationProfile
        overlayOpacity = settings.overlayOpacity
        z1Max = settings.z1Max
        z2Max = settings.z2Max
        z3Max = settings.z3Max
        z4Max = settings.z4Max
    }

    func apply(to settings: OverlaySettings) {
        settings.showTime = showTime
        settings.showDistance = showDistance
        settings.showHeartRate = showHeartRate
        settings.showPace = showPace
        settings.showGrade = showGrade
        settings.showAltitude = showAltitude
        settings.showCadence = showCadence
        settings.showElevationGain = showElevationGain
        settings.showCoreTemp = showCoreTemp
        settings.showMiniMap = showMiniMap
        settings.showElevationProfile = showElevationProfile
        settings.overlayOpacity = overlayOpacity
        settings.z1Max = z1Max
        settings.z2Max = z2Max
        settings.z3Max = z3Max
        settings.z4Max = z4Max
    }
}
