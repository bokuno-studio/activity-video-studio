import SwiftUI
import AppKit
import AVFoundation
import CoreLocation
import CoreGraphics
import Dispatch

@MainActor
final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()

    private struct Registration {
        var shouldTerminate: () -> Bool
        var isExporting: () -> Bool
    }

    private var registrationsByOwnerID: [UUID: Registration] = [:]

    private init() {}

    func register(
        ownerID: UUID,
        isExporting: @escaping () -> Bool = { false },
        shouldTerminate: @escaping () -> Bool
    ) {
        registrationsByOwnerID[ownerID] = Registration(
            shouldTerminate: shouldTerminate,
            isExporting: isExporting
        )
    }

    func unregister(ownerID: UUID) {
        registrationsByOwnerID[ownerID] = nil
    }

    func canTerminate() -> Bool {
        for registration in registrationsByOwnerID.values {
            guard registration.shouldTerminate() else { return false }
        }
        return true
    }

    func hasExportInProgress(excluding ownerID: UUID? = nil) -> Bool {
        registrationsByOwnerID.contains { currentOwnerID, registration in
            if currentOwnerID == ownerID { return false }
            return registration.isExporting()
        }
    }
}

@MainActor
final class AppFileOpenCoordinator {
    static let shared = AppFileOpenCoordinator()

    private var handlersByOwnerID: [UUID: ([URL]) -> Void] = [:]
    private var windowIDByOwnerID: [UUID: ObjectIdentifier] = [:]
    private var ownerIDByWindowID: [ObjectIdentifier: UUID] = [:]
    private var pendingURLs: [URL] = []
    private var recentOpenTimesByKey: [String: Date] = [:]
    private let duplicateInterval: TimeInterval = 1

    private init() {}

    func register(ownerID: UUID, handler: @escaping ([URL]) -> Void) {
        handlersByOwnerID[ownerID] = handler
        flushPendingURLs()
    }

    func unregister(ownerID: UUID) {
        handlersByOwnerID[ownerID] = nil
        unregisterWindow(ownerID: ownerID)
    }

    func registerWindow(_ window: NSWindow?, ownerID: UUID) {
        unregisterWindow(ownerID: ownerID)

        guard let window else { return }
        let windowID = ObjectIdentifier(window)
        if let previousOwnerID = ownerIDByWindowID[windowID] {
            windowIDByOwnerID[previousOwnerID] = nil
        }
        ownerIDByWindowID[windowID] = ownerID
        windowIDByOwnerID[ownerID] = windowID
        flushPendingURLs()
    }

    func open(_ urls: [URL]) {
        let urls = uniqueURLs(from: urls)
        guard !urls.isEmpty else { return }

        if let handler = targetHandler() {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    private func unregisterWindow(ownerID: UUID) {
        guard let windowID = windowIDByOwnerID.removeValue(forKey: ownerID) else { return }
        ownerIDByWindowID[windowID] = nil
    }

    private func flushPendingURLs() {
        guard let handler = targetHandler(), !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        handler(urls)
    }

    private func targetHandler() -> (([URL]) -> Void)? {
        if let ownerID = targetOwnerID(), let handler = handlersByOwnerID[ownerID] {
            return handler
        }

        guard handlersByOwnerID.count == 1 else { return nil }
        return handlersByOwnerID.values.first
    }

    private func targetOwnerID() -> UUID? {
        if let ownerID = ownerID(for: NSApplication.shared.keyWindow) {
            return ownerID
        }
        if let ownerID = ownerID(for: NSApplication.shared.mainWindow) {
            return ownerID
        }
        return nil
    }

    private func ownerID(for window: NSWindow?) -> UUID? {
        var currentWindow = window
        while let window = currentWindow {
            if let ownerID = ownerIDByWindowID[ObjectIdentifier(window)] {
                return ownerID
            }
            currentWindow = window.sheetParent
        }
        return nil
    }

    private func uniqueURLs(from urls: [URL]) -> [URL] {
        let now = Date()
        recentOpenTimesByKey = recentOpenTimesByKey.filter { _, openedAt in
            now.timeIntervalSince(openedAt) < duplicateInterval
        }

        var uniqueURLs: [URL] = []
        for url in urls {
            let key = openKey(for: url)
            guard recentOpenTimesByKey[key] == nil else { continue }
            recentOpenTimesByKey[key] = now
            uniqueURLs.append(url)
        }
        return uniqueURLs
    }

    private func openKey(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path
        }
        return url.absoluteString
    }
}

@MainActor
final class ActivityVideoStudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.canTerminate() ? .terminateNow : .terminateCancel
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        AppFileOpenCoordinator.shared.open([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        AppFileOpenCoordinator.shared.open(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppFileOpenCoordinator.shared.open(urls)
    }
}

struct ActivityVideoStudioApp: App {
    /// Stable identifier so the main window can be reopened from the menu after
    /// the user closes it (App Store Guideline 4 — a closed window must be
    /// reachable again via a menu item).
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(ActivityVideoStudioAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: ActivityVideoStudioApp.mainWindowID) {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            ActivityVideoStudioCommands()
        }
    }
}

struct PreviewCommandContext {
    var canSaveProject: Bool
    var canExport: Bool
    var canControlPlayback: Bool
    var isPlaying: Bool
    var shortcutsSuspended: Bool
    var openProject: () -> Void
    var saveProject: () -> Void
    var exportVideo: () -> Void
    var seekToTrimStart: () -> Void
    var skipBackward5: () -> Void
    var skipForward5: () -> Void
    var skipBackward10: () -> Void
    var skipForward10: () -> Void
    var togglePlayback: () -> Void
    var cyclePlaybackRate: () -> Void
    var addChapterMarker: () -> Void
}

struct PreviewCommandContextKey: FocusedValueKey {
    typealias Value = PreviewCommandContext
}

extension FocusedValues {
    var previewCommandContext: PreviewCommandContext? {
        get { self[PreviewCommandContextKey.self] }
        set { self[PreviewCommandContextKey.self] = newValue }
    }
}

struct ActivityVideoStudioCommands: Commands {
    @FocusedValue(\.previewCommandContext) private var context
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Reopens the main window after it has been closed. Required so the
            // window is always reachable from the menu (App Store Guideline 4).
            Button("新規ウィンドウ") {
                openWindow(id: ActivityVideoStudioApp.mainWindowID)
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("プロジェクトを開く...") {
                context?.openProject()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(context == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("プロジェクトを保存") {
                context?.saveProject()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!(context?.canSaveProject ?? false))
        }

        CommandGroup(after: .saveItem) {
            Button("エクスポート...") {
                context?.exportVideo()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!(context?.canExport ?? false))
        }

        CommandMenu("再生") {
            Button(context?.isPlaying == true ? "一時停止" : "再生") {
                context?.togglePlayback()
            }
            .keyboardShortcut("k", modifiers: [])
            .disabled(playbackCommandsDisabled)

            Button("トリム先頭に移動") {
                context?.seekToTrimStart()
            }
            .disabled(playbackCommandsDisabled)

            Divider()

            Button("5秒戻る") {
                context?.skipBackward5()
            }
            .disabled(playbackCommandsDisabled)

            Button("5秒進む") {
                context?.skipForward5()
            }
            .disabled(playbackCommandsDisabled)

            Button("10秒戻る") {
                context?.skipBackward10()
            }
            .keyboardShortcut("j", modifiers: [])
            .disabled(playbackCommandsDisabled)

            Button("10秒進む") {
                context?.skipForward10()
            }
            .keyboardShortcut("l", modifiers: [])
            .disabled(playbackCommandsDisabled)

            Divider()

            Button("再生速度を切り替え") {
                context?.cyclePlaybackRate()
            }
            .keyboardShortcut(",", modifiers: [])
            .disabled(playbackCommandsDisabled)

            Button("チャプターマーカーを追加") {
                context?.addChapterMarker()
            }
            .keyboardShortcut("m", modifiers: [])
            .disabled(playbackCommandsDisabled)
        }
    }

    private var playbackCommandsDisabled: Bool {
        context == nil ||
            (context?.shortcutsSuspended ?? true) ||
            !(context?.canControlPlayback ?? false)
    }
}

/// Process entry point. In DEBUG, `--headless-export` runs a GUI-free export and
/// exits — used by QA/CLI automation. The normal GUI launch (and its hang-prone
/// AVPlayer init path) is never started in that case. All other launches start
/// the SwiftUI app as usual. Release builds always start the SwiftUI app.
@main
struct AppEntryPoint {
    static func main() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--headless-export") {
            HeadlessExporter.run()   // never returns
        }
        #endif
        ActivityVideoStudioApp.main()
    }
}

#if DEBUG
/// GUI-free export for headless/CLI runs (QA automation).
///
/// The normal CLI path (`PreviewViewModel.autoLoadDebugFiles`) reaches the
/// exporter only after the SwiftUI scene and AVPlayer are initialized, which
/// hangs under a headless launch. This drives the production services
/// (FITParser → VideoMetadataReader → TimeSync → OverlayRenderer → VideoExporter)
/// directly, with no SwiftUI scene or AVPlayer, then exits.
///
/// Flags mirror `autoLoadDebugFiles`:
///   --headless-export --fit <path> --video <path> [--video <path> ...]
///   --export-to <path> [--align-fit-start | --offset <sec>]
///   [--trim-start <sec>] [--trim-end <sec>] [--trim-start-N <sec>] [--trim-end-N <sec>]
///   [--width <px>] [--height <px>] [--overlay-preset <preset>]
///   [--text <str>] [--text-pos <pos>] [--text-size <pt>]
enum HeadlessExporter {

    private static let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")

    static func run() -> Never {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        Task {
            do {
                try await perform()
                logLine("[Headless] DONE ✓")
                exit(0)
            } catch {
                logLine("[Headless] FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    static func logLine(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data((msg + "\n").utf8))
            try? h.close()
        }
    }

    private enum Err: Error, LocalizedError {
        case missing(String), empty(String), invalidArgument(String, String), unsyncedVideos([String])
        var errorDescription: String? {
            switch self {
            case .missing(let f): return "引数 \(f) が必要です"
            case .empty(let m):   return m
            case .invalidArgument(let f, let m): return "引数 \(f) が不正です: \(m)"
            case .unsyncedVideos(let names):
                return "撮影日時を読み取れない動画があるため中断しました: \(names.joined(separator: ", "))"
            }
        }
    }

    private static let booleanFlags: Set<String> = [
        "--headless-export",
        "--align-fit-start"
    ]

    private static let valueFlags: Set<String> = [
        "--fit",
        "--video",
        "--export-to",
        "--offset",
        "--trim-start",
        "--trim-end",
        "--width",
        "--height",
        "--overlay-preset",
        "--text",
        "--text-pos",
        "--text-size"
    ]

    private static func isKnownFlag(_ flag: String) -> Bool {
        booleanFlags.contains(flag) ||
            valueFlags.contains(flag) ||
            segmentTrimIndex(flag, prefix: "--trim-start-") != nil ||
            segmentTrimIndex(flag, prefix: "--trim-end-") != nil
    }

    private static func segmentTrimPrefix(for flag: String) -> String? {
        if flag.hasPrefix("--trim-start-") { return "--trim-start-" }
        if flag.hasPrefix("--trim-end-") { return "--trim-end-" }
        return nil
    }

    private static func segmentTrimIndex(_ flag: String, prefix: String) -> Int? {
        guard flag.hasPrefix(prefix) else { return nil }
        let suffix = String(flag.dropFirst(prefix.count))
        guard let index = Int(suffix), index >= 0 else { return nil }
        return index
    }

    private static func validateSegmentTrimFlags(in args: [String]) throws {
        for arg in args.dropFirst() {
            guard let prefix = segmentTrimPrefix(for: arg) else { continue }
            let suffix = String(arg.dropFirst(prefix.count))
            guard let index = Int(suffix), index >= 0 else {
                throw Err.invalidArgument(arg, "末尾は0以上の整数で指定してください")
            }
        }
    }

    private static func warnUnknownFlags(in args: [String]) {
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--"), !isKnownFlag(arg) {
                logLine("[Headless] WARNING: unknown flag ignored: \(arg)")
            }
            if valueFlags.contains(arg) ||
                segmentTrimIndex(arg, prefix: "--trim-start-") != nil ||
                segmentTrimIndex(arg, prefix: "--trim-end-") != nil {
                i += 2
            } else {
                i += 1
            }
        }
    }

    private static func argumentValue(after i: Int, for flag: String, in args: [String]) throws -> String {
        guard i + 1 < args.count, !isKnownFlag(args[i + 1]) else {
            throw Err.invalidArgument(flag, "値が必要です")
        }
        return args[i + 1]
    }

    private static func value(_ flag: String, in args: [String]) throws -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        return try argumentValue(after: i, for: flag, in: args)
    }

    private static func values(_ flag: String, in args: [String]) throws -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == flag {
                out.append(try argumentValue(after: i, for: flag, in: args))
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private static func optionalDouble(_ flag: String, in args: [String]) throws -> Double? {
        guard let raw = try value(flag, in: args) else { return nil }
        guard let parsed = Double(raw), parsed.isFinite else {
            throw Err.invalidArgument(flag, "\(raw) は数値ではありません")
        }
        return parsed
    }

    private static func doubleValue(_ flag: String, in args: [String], default defaultValue: Double) throws -> Double {
        try optionalDouble(flag, in: args) ?? defaultValue
    }

    private static func intValue(_ flag: String, in args: [String], default defaultValue: Int) throws -> Int {
        guard let raw = try value(flag, in: args) else { return defaultValue }
        guard let parsed = Int(raw), parsed > 0 else {
            throw Err.invalidArgument(flag, "\(raw) は正の整数ではありません")
        }
        return parsed
    }

    private static func segmentTrimValues(prefix: String, in args: [String]) throws -> [Int: TimeInterval] {
        var out: [Int: TimeInterval] = [:]
        var i = 0
        while i < args.count {
            if let index = segmentTrimIndex(args[i], prefix: prefix) {
                let flag = args[i]
                let raw = try argumentValue(after: i, for: flag, in: args)
                guard let parsed = TimeInterval(raw), parsed.isFinite else {
                    throw Err.invalidArgument(flag, "\(raw) は数値ではありません")
                }
                out[index] = parsed
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private static func textOverlayPosition(from raw: String?) throws -> TextOverlay.Position {
        switch raw {
        case nil, "center":
            return .center
        case "topCenter":
            return .topCenter
        case "bottomCenter":
            return .bottomCenter
        default:
            throw Err.invalidArgument("--text-pos", "\(raw ?? "")（指定可能な値: center, topCenter, bottomCenter）")
        }
    }

    private static func perform() async throws {
        let args = ProcessInfo.processInfo.arguments
        try validateSegmentTrimFlags(in: args)
        warnUnknownFlags(in: args)
        let textPosition = try textOverlayPosition(from: value("--text-pos", in: args))

        let fitPaths = try values("--fit", in: args)
        guard !fitPaths.isEmpty else { throw Err.missing("--fit") }
        let videoPaths = try values("--video", in: args)
        guard !videoPaths.isEmpty else { throw Err.missing("--video") }
        guard let outPath = try value("--export-to", in: args) else { throw Err.missing("--export-to") }

        // FIT
        let parser = FITParser()
        let parsedFITs = try fitPaths.map { try parser.parse(url: URL(fileURLWithPath: $0)) }
        let pts = FITMerger.merge(parsedFITs.map { FITMerger.Source(dataPoints: $0.dataPoints, hrZoneConfig: $0.hrZoneConfig) }).dataPoints
        guard let fitStart = pts.first?.timestamp else { throw Err.empty("FITに記録がありません") }
        logLine("[Headless] FIT points: \(pts.count)")

        // Video metadata, ordered like the app: by creationDate, filename as tiebreaker
        // (GoPro chaptered files share a creationDate).
        let reader = VideoMetadataReader()
        var metas: [VideoMetadata] = []
        for p in videoPaths { metas.append(try await reader.read(url: URL(fileURLWithPath: p))) }
        metas.sort { a, b in
            let da = a.creationDate ?? .distantPast
            let db = b.creationDate ?? .distantPast
            if da != db { return da < db }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }
        let videoURLs = metas.map { $0.url }
        logLine("[Headless] videos: \(videoURLs.map { $0.lastPathComponent }.joined(separator: ", "))")
        let unsyncedVideoNames = metas
            .filter { $0.creationDate == nil }
            .map { $0.url.lastPathComponent }
        if !unsyncedVideoNames.isEmpty {
            logLine("[Headless] WARNING: 撮影日時なし: \(unsyncedVideoNames.joined(separator: ", "))")
            throw Err.unsyncedVideos(unsyncedVideoNames)
        }

        // Sync offset (clock-skew correction)
        var syncOffset: Double = 0
        let offset = try optionalDouble("--offset", in: args)
        if args.contains("--align-fit-start") {
            if let cd = metas.first?.creationDate { syncOffset = fitStart.timeIntervalSince(cd) }
        } else if let off = offset {
            syncOffset = off
        }
        logLine("[Headless] syncOffset: \(Int(syncOffset))s")

        // TimeSync: stack chapters by cumulative duration, apply the offset to every
        // segment (matches PreviewViewModel.setupTimeSync).
        let timeSync = TimeSync(dataPoints: pts)
        var cumulative: TimeInterval = 0
        for m in metas {
            let adj = VideoMetadata(
                url: m.url,
                creationDate: m.creationDate?.addingTimeInterval(cumulative),
                quickTimeCreationDate: m.quickTimeCreationDate?.addingTimeInterval(cumulative),
                duration: m.duration,
                naturalSize: m.naturalSize
            )
            timeSync.addVideo(adj, offsetSeconds: syncOffset)
            if m.creationDate != nil {
                cumulative += m.duration
            }
        }

        // Trim: uniform --trim-start/--trim-end + per-segment --trim-start-N/--trim-end-N
        let trimStart = try doubleValue("--trim-start", in: args, default: 0)
        let trimEnd = try doubleValue("--trim-end", in: args, default: 0)
        var trims = metas.map { _ in TrimSettings(startTrim: trimStart, endTrim: trimEnd) }
        let perSegmentStart = try segmentTrimValues(prefix: "--trim-start-", in: args)
        let perSegmentEnd = try segmentTrimValues(prefix: "--trim-end-", in: args)
        for (i, v) in perSegmentStart {
            if trims.indices.contains(i) {
                trims[i].startTrim = v
            } else {
                logLine("[Headless] WARNING: --trim-start-\(i) ignored; only \(trims.count) video(s)")
            }
        }
        for (i, v) in perSegmentEnd {
            if trims.indices.contains(i) {
                trims[i].endTrim = v
            } else {
                logLine("[Headless] WARNING: --trim-end-\(i) ignored; only \(trims.count) video(s)")
            }
        }

        // Overlay
        let w = try intValue("--width", in: args, default: 1920)
        let h = try intValue("--height", in: args, default: 1080)
        let overlaySettings = OverlaySettings()
        if let presetValue = try value("--overlay-preset", in: args) {
            guard let preset = OverlayPreset(rawValue: presetValue) else {
                let allowed = OverlayPreset.allCases.map(\.rawValue).joined(separator: ", ")
                throw Err.invalidArgument("--overlay-preset", "\(presetValue)（allowed: \(allowed)）")
            }
            overlaySettings.overlayPreset = preset
            logLine("[Headless] overlayPreset: \(preset.rawValue)")
        }
        let renderer = OverlayRenderer(videoSize: CGSize(width: w, height: h), settings: overlaySettings)
        renderer.allDataPoints = pts
        renderer.buildElevationGainCache()
        renderer.trackSegments = FITMerger.trackSegments(from: pts)
        let textSize = try optionalDouble("--text-size", in: args)
        if let text = try value("--text", in: args), !text.isEmpty {
            var ov = TextOverlay(text: text, startTime: 0, duration: 9999)
            ov.position = textPosition
            if let fs = textSize { ov.fontSize = CGFloat(fs) }
            renderer.textOverlays = [ov]
        }

        // Export
        var config = VideoExporter.ExportConfig(outputURL: URL(fileURLWithPath: outPath))
        config.width = w
        config.height = h
        try? FileManager.default.removeItem(atPath: outPath)

        let progress = ProgressThrottle()
        let cb: VideoExporter.ProgressCallback = { fraction, _ in
            progress.emit(fraction)
        }
        let exporter = VideoExporter()
        if videoURLs.count > 1 {
            try await exporter.exportConcatenated(
                videoURLs: videoURLs,
                trimSettings: trims,
                timeSync: timeSync,
                overlayRenderer: renderer,
                config: config,
                onStatus: { logLine("[Headless] \($0)") },
                progress: cb
            )
        } else {
            try await exporter.exportSingleVideo(
                videoURL: videoURLs[0],
                timeSync: timeSync,
                segmentIndex: 0,
                trimSettings: trims[0],
                overlayRenderer: renderer,
                config: config,
                progress: cb
            )
        }
        logLine("[Headless] wrote \(outPath)")
    }

    /// Logs progress at most once per 10%. Reference type so it can be captured
    /// in the @Sendable progress callback.
    private final class ProgressThrottle: @unchecked Sendable {
        private var last = -1
        func emit(_ fraction: Double) {
            let p = Int(fraction * 100)
            if p / 10 != last / 10 { HeadlessExporter.logLine("[Headless] progress: \(p)%"); last = p }
        }
    }
}
#endif
