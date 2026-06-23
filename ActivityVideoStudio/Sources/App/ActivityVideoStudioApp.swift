import SwiftUI
import AVFoundation
import CoreLocation
import CoreGraphics

struct ActivityVideoStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            ActivityVideoStudioCommands()
        }
    }
}

struct PreviewCommandContext {
    var canSaveProject: Bool
    var canExport: Bool
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
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
        context == nil || (context?.shortcutsSuspended ?? true)
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
///   [--width <px>] [--height <px>] [--text <str>] [--text-pos <pos>] [--text-size <pt>]
enum HeadlessExporter {

    private static let logURL = URL(fileURLWithPath: "/tmp/avs_export.log")

    static func run() -> Never {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task {
            do {
                try await perform()
                logLine("[Headless] DONE ✓")
            } catch {
                logLine("[Headless] FAILED: \(error.localizedDescription)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        exit(code)
    }

    static func logLine(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data((msg + "\n").utf8))
            try? h.close()
        }
    }

    private enum Err: Error, LocalizedError {
        case missing(String), empty(String)
        var errorDescription: String? {
            switch self {
            case .missing(let f): return "引数 \(f) が必要です"
            case .empty(let m):   return m
            }
        }
    }

    private static func perform() async throws {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func values(_ flag: String) -> [String] {
            var out: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == flag, i + 1 < args.count { out.append(args[i + 1]); i += 2 } else { i += 1 }
            }
            return out
        }

        guard let fitPath = value("--fit") else { throw Err.missing("--fit") }
        let videoPaths = values("--video")
        guard !videoPaths.isEmpty else { throw Err.missing("--video") }
        guard let outPath = value("--export-to") else { throw Err.missing("--export-to") }

        // FIT
        let pts = try FITParser().parseDataPoints(url: URL(fileURLWithPath: fitPath))
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

        // Sync offset (clock-skew correction)
        var syncOffset: Double = 0
        if args.contains("--align-fit-start") {
            if let cd = metas.first?.creationDate { syncOffset = fitStart.timeIntervalSince(cd) }
        } else if let off = value("--offset").flatMap(Double.init) {
            syncOffset = off
        }
        logLine("[Headless] syncOffset: \(Int(syncOffset))s")

        // TimeSync: stack chapters by cumulative duration, apply the offset to every
        // segment (matches PreviewViewModel.setupTimeSync).
        let timeSync = TimeSync(dataPoints: pts)
        var cumulative: TimeInterval = 0
        for m in metas {
            guard m.creationDate != nil else { continue }
            let adj = VideoMetadata(
                url: m.url,
                creationDate: m.creationDate?.addingTimeInterval(cumulative),
                duration: m.duration,
                naturalSize: m.naturalSize
            )
            timeSync.addVideo(adj, offsetSeconds: syncOffset)
            cumulative += m.duration
        }

        // Trim: uniform --trim-start/--trim-end + per-segment --trim-start-N/--trim-end-N
        let trimStart = value("--trim-start").flatMap(TimeInterval.init) ?? 0
        let trimEnd = value("--trim-end").flatMap(TimeInterval.init) ?? 0
        var trims = metas.map { _ in TrimSettings(startTrim: trimStart, endTrim: trimEnd) }
        for i in trims.indices {
            if let v = value("--trim-start-\(i)").flatMap(TimeInterval.init) { trims[i].startTrim = v }
            if let v = value("--trim-end-\(i)").flatMap(TimeInterval.init) { trims[i].endTrim = v }
        }

        // Overlay
        let w = value("--width").flatMap(Int.init) ?? 1920
        let h = value("--height").flatMap(Int.init) ?? 1080
        let renderer = OverlayRenderer(videoSize: CGSize(width: w, height: h))
        renderer.allDataPoints = pts
        renderer.trackCoordinates = pts.compactMap { $0.coordinate }
        if let text = value("--text"), !text.isEmpty {
            var ov = TextOverlay(text: text, startTime: 0, duration: 9999)
            switch value("--text-pos") {
            case "topCenter":    ov.position = .topCenter
            case "bottomCenter": ov.position = .bottomCenter
            default:             ov.position = .center
            }
            if let fs = value("--text-size").flatMap(Double.init) { ov.fontSize = CGFloat(fs) }
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
