import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Main preview screen: video + overlay + minimap + controls.
struct PreviewView: View {
    @StateObject private var viewModel = PreviewViewModel()
    @State private var rightPanelTab: RightPanelTab = .trim
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showRightPanel = true
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var focusedChapterMarkerID: ChapterMarker.ID?
    @State private var trimFieldEditing = false
    @State private var selectedTextOverlayID: TextOverlay.ID?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.undoManager) private var undoManager

    enum RightPanelTab: String, CaseIterable {
        case trim = "トリム"
        case textOverlay = "テキスト"
        case chapters = "チャプター"
        case youtube = "YouTube"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            mainContent
                .contentShape(Rectangle())
                .onTapGesture {
                    clearChapterMarkerFocus()
                }
        }
        .inspector(isPresented: $showRightPanel) {
            inspectorPanel
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if viewModel.isLoading {
                loadingOverlay
            } else if !viewModel.videoLoaded || !viewModel.fitLoaded {
                dropPrompt
            }
        }
        .sheet(isPresented: $viewModel.showExport) {
            ExportView(
                viewModel: viewModel.makeExportViewModel(),
                isTextFocused: $isTextFieldFocused
            )
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("閉じる"))
            )
        }
        .background {
            WindowDocumentBridge(
                title: viewModel.windowTitle,
                representedURL: viewModel.projectURL,
                isDocumentEdited: viewModel.isProjectEdited
            )
            .frame(width: 0, height: 0)
        }
        .focusedSceneValue(\.previewCommandContext, commandContext)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.presentOpenProjectPanel()
                } label: {
                    Label("プロジェクトを開く", systemImage: "folder")
                }
                .help("プロジェクトを開く (⌘O)")
                .accessibilityLabel("プロジェクトを開く")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.presentSaveProjectPanel()
                } label: {
                    Label("プロジェクトを保存", systemImage: "square.and.arrow.down")
                }
                .help("プロジェクトを保存 (⌘S)")
                .accessibilityLabel("プロジェクトを保存")
                .disabled(!viewModel.canSaveProject)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRightPanel.toggle()
                } label: {
                    Label("インスペクタ", systemImage: "sidebar.right")
                }
                .help("インスペクタ")
                .accessibilityLabel("インスペクタ")
                .accessibilityValue(showRightPanel ? "表示中" : "非表示")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showExport = true
                } label: {
                    Label("エクスポート", systemImage: "square.and.arrow.up")
                }
                .help("エクスポート (⌘E)")
                .accessibilityLabel("エクスポート")
                .disabled(!viewModel.videoLoaded || !viewModel.fitLoaded)
            }
        }
        // Keyboard shortcuts (disabled when editing text or a front modal is open)
        .onKeyPress(.leftArrow) {
            guard !previewShortcutsSuspended else { return .ignored }
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !previewShortcutsSuspended else { return .ignored }
            viewModel.skipForward()
            return .handled
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            FileListView(
                fitURL: viewModel.fitURL,
                fitPointCount: viewModel.fitDataPoints.count,
                videoURLs: viewModel.videoURLs,
                videoDurations: viewModel.videoMetadatas.map { $0.duration },
                onRemoveVideo: { viewModel.removeVideo(at: $0, undoManager: undoManager) }
            )

            Divider()

            ScrollView {
                OverlaySettingsView(
                    settings: viewModel.overlaySettings
                )
            }
            .frame(maxHeight: 300)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            clearChapterMarkerFocus()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 260)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Video with overlays
            VideoPlayerView(player: viewModel.player) { delta in
                viewModel.seekBy(delta)
            }
                .aspectRatio(16/9, contentMode: .fit)
                // Single source of truth for the overlay: OverlayView shows the
                // exact image OverlayRenderer burns into the export (mini-map,
                // metrics, elevation profile included). The old SwiftUI
                // GPSTrackView drew a second map on top, so the preview showed
                // two overlapping maps that didn't match the export.
                .overlay {
                    OverlayView(overlayImage: viewModel.overlayImage)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if rightPanelTab == .textOverlay {
                        TextOverlayPlacementLayer(
                            overlays: $viewModel.textOverlays,
                            selectedOverlayID: $selectedTextOverlayID
                        )
                    }
                }
                .background(Color.black)
                .layoutPriority(1)

            // Thin controls bar
            controlsBar
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                    .accessibilityLabel("状態: \(status)")
            }
            if let warning = viewModel.projectWarningMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning)
                        .lineLimit(2)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.bottom, 4)
                .accessibilityLabel("警告: \(warning)")
            }
        }
    }

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $rightPanelTab) {
                ForEach(RightPanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            ScrollView {
                switch rightPanelTab {
                case .trim:
                    TrimView(
                        trimSettings: $viewModel.trimSettings,
                        videoNames: viewModel.videoURLs.map { $0.lastPathComponent },
                        videoDurations: viewModel.videoMetadatas.map { $0.duration },
                        onPreviewSeek: { time in viewModel.previewTrimSeek(to: time) },
                        onCommitSeek: { time in viewModel.commitTrimSeek(to: time) },
                        onEditingChanged: { trimFieldEditing = $0 }
                    )
                case .textOverlay:
                    TextOverlayEditView(
                        overlays: $viewModel.textOverlays,
                        selectedOverlayID: $selectedTextOverlayID,
                        videoDuration: viewModel.duration,
                        isTextFocused: $isTextFieldFocused
                    )
                case .chapters:
                    ChapterMarkerView(
                        markers: $viewModel.chapterMarkers,
                        trimmedTime: viewModel.trimmedTime(for:),
                        onSeek: { viewModel.seekToMarker($0) },
                        onAdd: { addChapterMarker() },
                        onRemove: { viewModel.removeChapterMarker(id: $0.id, undoManager: undoManager) },
                        focusedMarkerID: $focusedChapterMarkerID
                    )
                case .youtube:
                    YouTubeDescriptionView(
                        dataPoints: viewModel.fitDataPoints,
                        videoStartDate: viewModel.videoMetadatas.first?.creationDate,
                        chapterMarkers: viewModel.chapterMarkers,
                        trimmedTime: viewModel.trimmedTime(for:)
                    )
                }
            }
            .background {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        clearChapterMarkerFocus()
                    }
            }
        }
        .background(.regularMaterial)
        .inspectorColumnWidth(min: 320, ideal: 340, max: 380)
        .onChange(of: rightPanelTab) { _, tab in
            if tab != .chapters {
                clearChapterMarkerFocus()
            }
        }
    }

    private var commandContext: PreviewCommandContext {
        PreviewCommandContext(
            canSaveProject: viewModel.canSaveProject,
            canExport: viewModel.videoLoaded && viewModel.fitLoaded,
            isPlaying: viewModel.isPlaying,
            shortcutsSuspended: previewShortcutsSuspended,
            openProject: { viewModel.presentOpenProjectPanel() },
            saveProject: { viewModel.presentSaveProjectPanel() },
            exportVideo: { viewModel.showExport = true },
            seekToTrimStart: { viewModel.seekToTrimStart() },
            skipBackward5: { viewModel.skipBackward() },
            skipForward5: { viewModel.skipForward() },
            skipBackward10: { viewModel.skipBackward(10) },
            skipForward10: { viewModel.skipForward(10) },
            togglePlayback: { viewModel.togglePlayback() },
            cyclePlaybackRate: { viewModel.cyclePlaybackRate() },
            addChapterMarker: { addChapterMarker() }
        )
    }

    private var frontModalPresented: Bool {
        viewModel.showExport
    }

    private var previewShortcutsSuspended: Bool {
        isTextFieldFocused || focusedChapterMarkerID != nil || trimFieldEditing || frontModalPresented
    }

    private func clearChapterMarkerFocus() {
        focusedChapterMarkerID = nil
    }

    private func addChapterMarker() {
        clearChapterMarkerFocus()
        viewModel.addChapterMarker(undoManager: undoManager)
    }

    // MARK: - Controls bar (compact)

    private var controlsBar: some View {
        let totalDuration = max(viewModel.duration, 1)

        return VStack(spacing: 4) {
            // Seek bar with trim indicators (absolute time axis)
            HStack(spacing: 8) {
                Text(formatTime(viewModel.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)

                ZStack {
                    Slider(value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.currentTime = $0 }
                    ), in: 0...totalDuration) { editing in
                        if editing {
                            viewModel.beginSeeking()
                        } else {
                            viewModel.seek(to: viewModel.currentTime)
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("再生位置")
                    .accessibilityValue("\(formatTime(viewModel.currentTime)) / \(formatTime(totalDuration))")

                    GeometryReader { geo in
                        let trimInfo = viewModel.trimRangesForSeekbar()
                        ForEach(Array(trimInfo.enumerated()), id: \.offset) { _, range in
                            if range.startFrac > 0 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: geo.size.width * range.startFrac)
                                    .allowsHitTesting(false)
                            }
                            if range.endFrac > 0 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: geo.size.width * range.endFrac)
                                    .offset(x: geo.size.width * (1 - range.endFrac))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .allowsHitTesting(false)

                    // Chapter markers on seekbar (absolute time)
                    GeometryReader { geo in
                        ForEach(viewModel.chapterMarkers) { marker in
                            let frac = min(max(marker.time / totalDuration, 0), 1)
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 2, height: geo.size.height)
                                .offset(x: geo.size.width * CGFloat(frac))
                        }
                    }
                    .allowsHitTesting(false)
                }

                Text(formatTime(totalDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .leading)
            }

            HStack(spacing: 8) {
                // Trim start
                Button { viewModel.seekToTrimStart() } label: {
                    Image(systemName: "backward.end.fill")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
                .help("トリム先頭に戻る")
                .accessibilityLabel("トリム先頭に移動")

                // Skip back 5s
                Button { viewModel.skipBackward() } label: {
                    Image(systemName: "gobackward.5")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
                .help("5秒戻る")
                .accessibilityLabel("5秒戻る")

                // Play/Pause
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 32, minHeight: 28)
                .contentShape(Rectangle())
                .keyboardShortcut(.space, modifiers: [])
                .disabled(frontModalPresented)
                .help(viewModel.isPlaying ? "一時停止" : "再生")
                .accessibilityLabel(viewModel.isPlaying ? "一時停止" : "再生")
                .accessibilityValue(viewModel.isPlaying ? "再生中" : "停止中")

                // Skip forward 5s
                Button { viewModel.skipForward() } label: {
                    Image(systemName: "goforward.5")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
                .help("5秒進む")
                .accessibilityLabel("5秒進む")

                Picker("再生速度", selection: playbackRateBinding) {
                    ForEach(viewModel.playbackRateOptions, id: \.self) { rate in
                        Text("\(formatPlaybackRate(rate))x").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .help("再生速度")
                .accessibilityLabel("再生速度")
                .accessibilityValue("\(formatPlaybackRate(viewModel.playbackRate))倍")

                Spacer()

                if viewModel.videoURLs.count > 1 {
                    Text("\(viewModel.videoURLs.count)本")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }

            if viewModel.fitLoaded {
                syncControlsRow
            }
        }
    }

    private var syncControlsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    viewModel.alignFitStartToCurrentFrame()
                } label: {
                    Text("ここをFIT開始に")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("いま表示しているフレームを活動の開始（0:00 / 0km）に合わせます。スタート地点までスクラブして押し、±で微調整してください")
                .accessibilityLabel("ここをFIT開始にする")
                .accessibilityHint("現在の再生位置をFIT活動の開始時刻に合わせます")

                Divider().frame(height: 16)

                Text("同期")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper("同期オフセット", value: syncOffsetBinding, step: 0.5)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("同期オフセットを0.5秒単位で調整")

                TextField("秒", value: syncOffsetBinding, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .focused($isTextFieldFocused)
                    .accessibilityLabel("同期オフセット秒")
                Text("秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                syncNudgeButton("−1m", delta: -60)
                syncNudgeButton("−10s", delta: -10)
                syncNudgeButton("−", delta: -0.5)

                Text(viewModel.videoStartDescription() ?? "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .center)
                    .help("オフセット適用後の動画先頭の時刻。ここがFITの活動中の時刻と一致すれば同期OK")
                    .accessibilityLabel("同期後の動画先頭時刻")
                    .accessibilityValue(viewModel.videoStartDescription() ?? "未設定")

                syncNudgeButton("＋", delta: 0.5)
                syncNudgeButton("+10s", delta: 10)
                syncNudgeButton("+1m", delta: 60)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
    }

    private var playbackRateBinding: Binding<Float> {
        Binding(
            get: { viewModel.playbackRate },
            set: { viewModel.setPlaybackRate($0) }
        )
    }

    private var syncOffsetBinding: Binding<Double> {
        Binding(
            get: { viewModel.syncOffset },
            set: { viewModel.updateSyncOffset($0) }
        )
    }

    // MARK: - Drop prompt

    private var dropPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("FIT ファイルと動画をドラッグ&ドロップ")
                .font(.title3)
                .foregroundStyle(.primary)
            Text(".fit / .zip + .mp4 / .mov")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.fitLoaded ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(viewModel.fitLoaded ? .green : .secondary)
                    if differentiateWithoutColor && viewModel.fitLoaded {
                        Text("読み込み済み")
                            .font(.caption2)
                    }
                    Text(".FIT / .ZIP (アクティビティデータ)")
                        .foregroundStyle(viewModel.fitLoaded ? .primary : .secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: viewModel.videoLoaded ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(viewModel.videoLoaded ? .green : .secondary)
                    if differentiateWithoutColor && viewModel.videoLoaded {
                        Text("読み込み済み")
                            .font(.caption2)
                    }
                    Text(".MP4 (動画ファイル)")
                        .foregroundStyle(viewModel.videoLoaded ? .primary : .secondary)
                }
            }
            .font(.callout)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            if let progress = viewModel.loadingProgress {
                ProgressView(value: progress, total: 1)
                    .controlSize(.large)
                    .frame(width: 220)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(viewModel.loadingMessage ?? "読み込み中...")
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.loadingMessage ?? "読み込み中")
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            let droppedFiles = await droppedFileURLs(from: providers)
            guard !droppedFiles.urls.isEmpty else {
                viewModel.showError(
                    title: "ファイルを読み込めませんでした",
                    message: "ドロップされた項目のファイルURLを取得できませんでした。"
                )
                return
            }

            var videoURLs: [URL] = []
            var unsupportedNames: [String] = []

            for url in droppedFiles.urls {
                let ext = url.pathExtension.lowercased()
                if ext == "fit" || ext == "zip" {
                    viewModel.loadFITFile(url: url)
                } else if ["mp4", "mov", "m4v"].contains(ext) {
                    videoURLs.append(url)
                } else {
                    unsupportedNames.append(url.lastPathComponent)
                }
            }

            if !videoURLs.isEmpty {
                await viewModel.loadVideos(urls: videoURLs)
            }

            if droppedFiles.failedCount > 0 {
                viewModel.showError(
                    title: "ファイルを読み込めませんでした",
                    message: "ドロップされた項目のうち \(droppedFiles.failedCount) 件のファイルURLを取得できませんでした。"
                )
            } else if !unsupportedNames.isEmpty {
                viewModel.showError(
                    title: "対応していないファイル形式です",
                    message: "\(unsupportedNames.joined(separator: ", ")) は読み込めません。対応形式は .fit / .zip / .mp4 / .mov / .m4v です。"
                )
            }
        }
    }

    private func droppedFileURLs(from providers: [NSItemProvider]) async -> (urls: [URL], failedCount: Int) {
        var urls: [URL] = []
        var failedCount = 0

        for provider in providers {
            if let url = await droppedFileURL(from: provider) {
                urls.append(url)
            } else {
                failedCount += 1
            }
        }

        return (urls, failedCount)
    }

    private func droppedFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatPlaybackRate(_ rate: Float) -> String {
        String(format: rate == Float(Int(rate)) ? "%.0f" : "%.1f", rate)
    }

    @ViewBuilder
    private func syncNudgeButton(_ label: String, delta: Double) -> some View {
        Button {
            viewModel.updateSyncOffset(viewModel.syncOffset + delta)
        } label: {
            Text(label)
                .font(.caption2.weight(.semibold))
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .help(syncNudgeHelp(delta: delta))
        .accessibilityLabel(syncNudgeAccessibilityLabel(delta: delta))
    }

    private func syncNudgeAccessibilityLabel(delta: Double) -> String {
        let direction = delta < 0 ? "戻す" : "進める"
        return "同期を\(formatNudgeAmount(abs(delta)))\(direction)"
    }

    private func syncNudgeHelp(delta: Double) -> String {
        let direction = delta < 0 ? "戻します" : "進めます"
        return "同期を\(formatNudgeAmount(abs(delta)))\(direction)"
    }

    private func formatNudgeAmount(_ seconds: Double) -> String {
        if seconds >= 60 {
            return "\(Int(seconds / 60))分"
        }
        if seconds == floor(seconds) {
            return "\(Int(seconds))秒"
        }
        return String(format: "%.1f秒", seconds)
    }
}

#if false
#Preview {
    PreviewView()
        .frame(width: 1100, height: 700)
}
#endif

private struct TextOverlayPlacementLayer: View {
    @Binding var overlays: [TextOverlay]
    @Binding var selectedOverlayID: TextOverlay.ID?

    private static let coordinateSpaceName = "TextOverlayPlacementLayer"

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                            .onChanged { value in
                                guard let selectedOverlayID else { return }
                                moveOverlay(id: selectedOverlayID, to: value.location, in: geometry.size)
                            }
                    )

                ForEach(overlays) { overlay in
                    placementHandle(for: overlay, in: geometry.size)
                }
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
        }
    }

    @ViewBuilder
    private func placementHandle(for overlay: TextOverlay, in size: CGSize) -> some View {
        let selected = selectedOverlayID == overlay.id
        let diameter: CGFloat = selected ? 20 : 14

        Circle()
            .fill(selected ? Color.accentColor : Color.white.opacity(0.85))
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .stroke(Color.black.opacity(0.65), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
            .position(
                x: min(max(overlay.relativeX, 0), 1) * size.width,
                y: min(max(overlay.relativeY, 0), 1) * size.height
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                    .onChanged { value in
                        selectedOverlayID = overlay.id
                        moveOverlay(id: overlay.id, to: value.location, in: size)
                    }
            )
            .accessibilityLabel("テキスト位置")
            .accessibilityValue(selected ? "選択中" : "未選択")
    }

    private func moveOverlay(id: TextOverlay.ID, to point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0,
              let index = overlays.firstIndex(where: { $0.id == id }) else { return }

        overlays[index].relativeX = min(max(point.x / size.width, 0), 1)
        overlays[index].relativeY = min(max(point.y / size.height, 0), 1)
        overlays[index].clampRelativePosition()
    }
}

private struct WindowDocumentBridge: NSViewRepresentable {
    var title: String
    var representedURL: URL?
    var isDocumentEdited: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowDocumentBridgeView {
        let view = WindowDocumentBridgeView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.apply(to: window)
        }
        updateCoordinator(context.coordinator)
        context.coordinator.apply(to: view.window)
        return view
    }

    func updateNSView(_ nsView: WindowDocumentBridgeView, context: Context) {
        updateCoordinator(context.coordinator)
        context.coordinator.apply(to: nsView.window)
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.title = title
        coordinator.representedURL = representedURL
        coordinator.isDocumentEdited = isDocumentEdited
    }

    final class Coordinator {
        var title = ""
        var representedURL: URL?
        var isDocumentEdited = false

        func apply(to window: NSWindow?) {
            guard let window else { return }
            window.title = title
            window.representedURL = representedURL
            window.isDocumentEdited = isDocumentEdited
        }
    }

    final class WindowDocumentBridgeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
