import SwiftUI
import AppKit
import AVFoundation
import CoreText
import UniformTypeIdentifiers

/// Main preview screen: video + overlay + minimap + controls.
struct PreviewView: View {
    @StateObject private var viewModel = PreviewViewModel()
    @State private var exportViewModel: ExportViewModel?
    @State private var rightPanelTab: RightPanelTab = .trim
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showRightPanel = true
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var focusedChapterMarkerID: ChapterMarker.ID?
    @State private var trimFieldEditing = false
    @State private var selectedTextOverlayID: TextOverlay.ID?
    @State private var videoDisplayRect: CGRect = .zero
    @State private var appLifecycleOwnerID = UUID()
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.undoManager) private var undoManager

    private static let supportedDropContentTypes: [UTType] = ["fit", "zip", "mp4", "mov", "m4v"]
        .compactMap { UTType(filenameExtension: $0) }
    private static let supportedFITExtensions: Set<String> = ["fit", "zip"]
    private static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

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
        .onDrop(of: Self.supportedDropContentTypes, isTargeted: nil) { providers in
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
        .sheet(item: $exportViewModel, onDismiss: {
            exportViewModel = nil
        }) { exportViewModel in
            ExportView(
                viewModel: exportViewModel,
                isTextFocused: $isTextFieldFocused
            )
            .interactiveDismissDisabled(viewModel.isExporting)
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("閉じる"))
            )
        }
        .onAppear {
            AppTerminationCoordinator.shared.register(
                ownerID: appLifecycleOwnerID,
                isExporting: { viewModel.isExporting }
            ) {
                viewModel.confirmCloseEditedProject()
            }
            AppFileOpenCoordinator.shared.register(ownerID: appLifecycleOwnerID) { urls in
                Task { @MainActor in
                    await viewModel.openExternalFiles(urls)
                }
            }
        }
        .onDisappear {
            AppTerminationCoordinator.shared.unregister(ownerID: appLifecycleOwnerID)
            AppFileOpenCoordinator.shared.unregister(ownerID: appLifecycleOwnerID)
        }
        .onOpenURL { url in
            AppFileOpenCoordinator.shared.open([url])
        }
        .background {
            WindowDocumentBridge(
                ownerID: appLifecycleOwnerID,
                title: viewModel.windowTitle,
                representedURL: viewModel.projectURL,
                isDocumentEdited: viewModel.isProjectEdited,
                shouldClose: {
                    viewModel.confirmCloseEditedProject()
                }
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
                    presentExport()
                } label: {
                    Label("エクスポート", systemImage: "square.and.arrow.up")
                }
                .help("エクスポート (⌘E)")
                .accessibilityLabel("エクスポート")
                .disabled(!canPresentExport)
            }
        }
        // Keyboard shortcuts (disabled when editing text or a front modal is open)
        .onKeyPress(.leftArrow) {
            guard !previewShortcutsSuspended, viewModel.canControlPlayback else { return .ignored }
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !previewShortcutsSuspended, viewModel.canControlPlayback else { return .ignored }
            viewModel.skipForward()
            return .handled
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            FileListView(
                fitURLs: viewModel.fitURLs,
                fitPointCounts: viewModel.fitPointCounts,
                videoURLs: viewModel.videoURLs,
                videoDurations: viewModel.videoMetadatas.map { $0.duration },
                onRemoveVideo: { viewModel.removeVideo(at: $0, undoManager: undoManager) },
                onRemoveFIT: { viewModel.removeFIT(at: $0) }
            )

            Divider()

            ScrollView {
                OverlaySettingsView(
                    settings: viewModel.overlaySettings,
                    onImportTheme: { viewModel.presentImportThemePanel() },
                    onExportTheme: { viewModel.presentExportThemePanel() }
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
            VideoPlayerView(player: viewModel.player, videoRect: $videoDisplayRect) { delta in
                viewModel.scrollSeekBy(delta)
            }
                .overlay(alignment: .topLeading) {
                    if videoDisplayRect.isDrawableVideoRect {
                        LivePreviewOverlayView(
                            frame: viewModel.liveOverlayFrame,
                            settings: viewModel.overlaySettings,
                            allDataPoints: viewModel.fitDataPoints,
                            trackSegments: viewModel.trackSegments,
                            textOverlays: viewModel.textOverlays,
                            textPlaybackTime: viewModel.trimmedPlaybackTime()
                        )
                        .modifier(PreviewOverlayLayout(videoRect: videoDisplayRect))
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if rightPanelTab == .textOverlay, videoDisplayRect.isDrawableVideoRect {
                        TextOverlayPlacementLayer(
                            overlays: $viewModel.textOverlays,
                            selectedOverlayID: $selectedTextOverlayID,
                            onMoveCompleted: { id, originalX, originalY in
                                viewModel.registerTextOverlayMoveUndo(
                                    id: id,
                                    originalRelativeX: originalX,
                                    originalRelativeY: originalY,
                                    undoManager: undoManager
                                )
                            }
                        )
                            .frame(width: videoDisplayRect.width, height: videoDisplayRect.height)
                            .offset(x: videoDisplayRect.minX, y: videoDisplayRect.minY)
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
                        description: $viewModel.youtubeDescription,
                        onGenerate: { viewModel.regenerateYouTubeDescription() },
                        onAppear: { viewModel.initializeYouTubeDescriptionIfNeeded() },
                        isTextFocused: $isTextFieldFocused
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
            canExport: canPresentExport,
            canControlPlayback: viewModel.canControlPlayback,
            isPlaying: viewModel.isPlaying,
            shortcutsSuspended: previewShortcutsSuspended,
            openProject: { viewModel.presentOpenProjectPanel() },
            saveProject: { viewModel.presentSaveProjectPanel() },
            exportVideo: { presentExport() },
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

    private var canPresentExport: Bool {
        viewModel.videoLoaded && viewModel.fitLoaded && exportViewModel == nil
    }

    private var frontModalPresented: Bool {
        exportViewModel != nil
    }

    private var previewShortcutsSuspended: Bool {
        isTextFieldFocused || focusedChapterMarkerID != nil || trimFieldEditing || frontModalPresented
    }

    private func presentExport() {
        guard canPresentExport else { return }
        viewModel.pausePlayback()

        let exportViewModel = viewModel.makeExportViewModel()
        exportViewModel.shouldQuitWhenDone = { [ownerID = appLifecycleOwnerID] in
            !AppTerminationCoordinator.shared.hasExportInProgress(excluding: ownerID)
        }
        exportViewModel.onDismiss = {
            self.exportViewModel = nil
        }
        self.exportViewModel = exportViewModel
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
        let playbackControlsDisabled = !viewModel.canControlPlayback || frontModalPresented

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
                    .disabled(playbackControlsDisabled)
                    .accessibilityLabel("再生位置")
                    .accessibilityValue("\(formatTime(viewModel.currentTime)) / \(formatTime(totalDuration))")

                    GeometryReader { geo in
                        let trimInfo = viewModel.trimRangesForSeekbar()
                        ForEach(Array(trimInfo.enumerated()), id: \.offset) { _, range in
                            if range.widthFrac > 0 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: geo.size.width * range.widthFrac)
                                    .offset(x: geo.size.width * range.startFrac)
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
                .disabled(playbackControlsDisabled)
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
                .disabled(playbackControlsDisabled)
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
                .disabled(playbackControlsDisabled)
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
                .disabled(playbackControlsDisabled)
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
                .disabled(playbackControlsDisabled)
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
                if let message = viewModel.gpsAlignmentMessage {
                    Text(message)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var syncControlsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(viewModel.isAligningGPS ? "GPSを確認中…" : "カメラのGPSで合わせる") {
                    Task { await viewModel.alignCameraGPS() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isAligningGPS || !viewModel.videoLoaded || !viewModel.fitLoaded)
                if viewModel.gpsPreviousOffset != nil {
                    Button("GPS補正を取り消す") { viewModel.undoGPSAlignment() }
                        .controlSize(.small)
                }
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

                if let candidateLabel = viewModel.timeZoneCorrectionCandidateLabel {
                    Button {
                        viewModel.applyTimeZoneCorrectionCandidate()
                    } label: {
                        Label(candidateLabel, systemImage: "clock.arrow.circlepath")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("FITの時間範囲に合うタイムゾーン補正候補を同期オフセットに適用")
                    .accessibilityLabel(candidateLabel)
                }

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
        .alert("GPS軌跡の一致を確認してください", isPresented: Binding(
            get: { viewModel.pendingGPSAlignment != nil },
            set: { if !$0 { viewModel.pendingGPSAlignment = nil } }
        )) {
            Button("補正を適用") {
                if let result = viewModel.pendingGPSAlignment { viewModel.applyGPSAlignment(result) }
            }
            Button("キャンセル", role: .cancel) { viewModel.pendingGPSAlignment = nil }
        } message: {
            Text((viewModel.pendingGPSAlignment?.summary ?? "") + "\n距離の中央値が50mを超えるか、比較できるGPS記録がありません。補正を適用しますか？")
        }
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
            var duplicateNames: [String] = []
            var seenDropKeys = Set<String>()
            let existingVideoKeys = Set(viewModel.videoURLs.map { resolvedFileKey(for: $0) })
            var existingFITKeys = Set(viewModel.fitURLs.map { resolvedFileKey(for: $0) })

            for url in droppedFiles.urls {
                let resolvedURL = resolvedFileURL(for: url)
                let key = resolvedFileKey(for: resolvedURL)
                guard seenDropKeys.insert(key).inserted else {
                    duplicateNames.append(resolvedURL.lastPathComponent)
                    continue
                }

                switch droppedFileKind(for: resolvedURL) {
                case .fit:
                    if existingFITKeys.contains(key) {
                        duplicateNames.append(resolvedURL.lastPathComponent)
                    } else {
                        viewModel.loadFITFile(url: resolvedURL)
                        existingFITKeys.insert(key)
                    }
                case .video:
                    if existingVideoKeys.contains(key) {
                        duplicateNames.append(resolvedURL.lastPathComponent)
                    } else {
                        videoURLs.append(resolvedURL)
                    }
                case nil:
                    unsupportedNames.append(resolvedURL.lastPathComponent)
                }
            }

            if !videoURLs.isEmpty {
                await viewModel.loadVideos(urls: videoURLs)
            }

            var messages: [String] = []
            if droppedFiles.failedCount > 0 {
                messages.append("ドロップされた項目のうち \(droppedFiles.failedCount) 件のファイルURLを取得できませんでした。")
            }
            if !unsupportedNames.isEmpty {
                messages.append("\(unsupportedNames.joined(separator: ", ")) は読み込めません。対応形式は .fit / .zip / .mp4 / .mov / .m4v です。")
            }
            if !duplicateNames.isEmpty {
                messages.append("\(duplicateNames.joined(separator: ", ")) はすでに追加済みのためスキップしました。")
            }

            if !messages.isEmpty {
                viewModel.showError(
                    title: "一部のファイルを読み込めませんでした",
                    message: messages.joined(separator: "\n")
                )
            }
        }
    }

    private enum DroppedFileKind {
        case fit
        case video
    }

    private func droppedFileKind(for url: URL) -> DroppedFileKind? {
        guard url.isFileURL, !url.hasDirectoryPath else { return nil }
        let ext = url.pathExtension.lowercased()
        if Self.supportedFITExtensions.contains(ext) {
            return .fit
        }
        if Self.supportedVideoExtensions.contains(ext) {
            return .video
        }
        return nil
    }

    private func resolvedFileURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func resolvedFileKey(for url: URL) -> String {
        resolvedFileURL(for: url).path
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
    var onMoveCompleted: (TextOverlay.ID, CGFloat, CGFloat) -> Void

    private static let coordinateSpaceName = "TextOverlayPlacementLayer"
    @State private var activeDrag: ActiveDrag?

    private struct ActiveDrag {
        let id: TextOverlay.ID
        let originalRelativeX: CGFloat
        let originalRelativeY: CGFloat
        let grabOffset: CGSize
    }

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpaceName))
                        .onChanged { value in
                            guard let drag = activeDrag ?? beginDrag(value: value, in: geometry.size) else { return }
                            let target = CGPoint(
                                x: value.location.x - drag.grabOffset.width,
                                y: value.location.y - drag.grabOffset.height
                            )
                            moveOverlay(id: drag.id, to: target, in: geometry.size)
                        }
                        .onEnded { _ in
                            guard let drag = activeDrag,
                                  let overlay = overlays.first(where: { $0.id == drag.id }) else {
                                activeDrag = nil
                                return
                            }
                            activeDrag = nil
                            if abs(overlay.relativeX - drag.originalRelativeX) > 0.0001 ||
                                abs(overlay.relativeY - drag.originalRelativeY) > 0.0001 {
                                onMoveCompleted(drag.id, drag.originalRelativeX, drag.originalRelativeY)
                            }
                        }
                )
                .coordinateSpace(name: Self.coordinateSpaceName)
        }
    }

    private func beginDrag(value: DragGesture.Value, in size: CGSize) -> ActiveDrag? {
        guard activeDrag == nil,
              let selectedOverlayID,
              let overlay = overlays.first(where: { $0.id == selectedOverlayID }),
              let hitRect = hitRect(for: overlay, in: size),
              hitRect.contains(value.startLocation) else { return nil }

        let center = CGPoint(
            x: min(max(overlay.relativeX, 0), 1) * size.width,
            y: min(max(overlay.relativeY, 0), 1) * size.height
        )
        let drag = ActiveDrag(
            id: overlay.id,
            originalRelativeX: overlay.relativeX,
            originalRelativeY: overlay.relativeY,
            grabOffset: CGSize(
                width: value.startLocation.x - center.x,
                height: value.startLocation.y - center.y
            )
        )
        activeDrag = drag
        return drag
    }

    private func moveOverlay(id: TextOverlay.ID, to point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0,
              let index = overlays.firstIndex(where: { $0.id == id }) else { return }

        overlays[index].relativeX = min(max(point.x / size.width, 0), 1)
        overlays[index].relativeY = min(max(point.y / size.height, 0), 1)
        overlays[index].clampRelativePosition()
    }

    private func hitRect(for overlay: TextOverlay, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = max(size.width, 1) / 1920
        let fontSize = max(1, overlay.fontSize * scale)
        let font = textOverlayFont(for: overlay, size: fontSize)
        let lineHeight = max(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), fontSize * 1.2)
        let lines = overlay.text.components(separatedBy: "\n")
        let maxWidth = lines
            .map { lineText -> CGFloat in
                let attrStr = NSAttributedString(string: lineText, attributes: [.font: font])
                let line = CTLineCreateWithAttributedString(attrStr)
                return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
            .max() ?? fontSize

        let totalHeight = lineHeight * CGFloat(max(lines.count, 1))
        let padding = 30 * scale
        let strokeWidth = max(0, overlay.strokeWidth) * scale
        let centerX = min(max(overlay.relativeX, 0), 1) * size.width
        let centerY = min(max(overlay.relativeY, 0), 1) * size.height

        return CGRect(
            x: centerX - maxWidth / 2 - padding - strokeWidth,
            y: centerY - totalHeight / 2 - padding / 2 - strokeWidth,
            width: maxWidth + padding * 2 + strokeWidth * 2,
            height: totalHeight + padding + strokeWidth * 2
        )
    }

    private func textOverlayFont(for overlay: TextOverlay, size: CGFloat) -> CTFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.placementNSFontWeight)
        let nsFont = NSFontManager.shared.font(
            withFamily: overlay.fontFamily,
            traits: [],
            weight: overlay.fontWeight.placementNSFontManagerWeight,
            size: size
        ) ?? fallback

        return CTFontCreateWithName(nsFont.fontName as CFString, size, nil)
    }
}

private extension TextOverlay.FontWeight {
    var placementNSFontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var placementNSFontManagerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }
}

private extension CGRect {
    var isDrawableVideoRect: Bool {
        !isNull &&
            origin.x.isFinite &&
            origin.y.isFinite &&
            size.width.isFinite &&
            size.height.isFinite &&
            width > 0 &&
            height > 0
    }
}

private struct WindowDocumentBridge: NSViewRepresentable {
    var ownerID: UUID
    var title: String
    var representedURL: URL?
    var isDocumentEdited: Bool
    var shouldClose: () -> Bool

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
        coordinator.ownerID = ownerID
        coordinator.title = title
        coordinator.representedURL = representedURL
        coordinator.isDocumentEdited = isDocumentEdited
        coordinator.shouldClose = shouldClose
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var ownerID = UUID()
        var title = ""
        var representedURL: URL?
        var isDocumentEdited = false
        var shouldClose: () -> Bool = { true }

        @MainActor
        func apply(to window: NSWindow?) {
            AppFileOpenCoordinator.shared.registerWindow(window, ownerID: ownerID)
            guard let window else { return }
            window.title = title
            window.representedURL = representedURL
            window.isDocumentEdited = isDocumentEdited
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose()
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
