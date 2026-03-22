import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Main preview screen: video + overlay + minimap + controls.
struct PreviewView: View {
    @StateObject private var viewModel = PreviewViewModel()
    @State private var rightPanelTab: RightPanelTab = .trim
    @State private var showRightPanel = false
    @FocusState private var isTextFieldFocused: Bool

    enum RightPanelTab: String, CaseIterable {
        case trim = "トリム"
        case textOverlay = "テキスト"
        case youtube = "YouTube"
    }

    var body: some View {
        HSplitView {
            // Left sidebar: file list + settings
            if viewModel.showFileList {
                VStack(spacing: 0) {
                    FileListView(
                        fitURL: viewModel.fitURL,
                        fitPointCount: viewModel.fitDataPoints.count,
                        videoURLs: viewModel.videoURLs,
                        videoDurations: viewModel.videoMetadatas.map { $0.duration },
                        onRemoveVideo: { viewModel.removeVideo(at: $0) }
                    )

                    Divider()

                    // Settings inline
                    ScrollView {
                        OverlaySettingsView(settings: viewModel.overlaySettings)
                    }
                    .frame(maxHeight: 300)
                }
                .frame(minWidth: 200, maxWidth: 260)
            }

            // Main content
            VStack(spacing: 0) {
                // Video area
                VideoPlayerView(player: viewModel.player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .background(Color.black)
                    .overlay {
                        // GPS Track - relative to video, proportional size
                        GeometryReader { geo in
                            if viewModel.overlaySettings.showMiniMap && !viewModel.trackCoordinates.isEmpty {
                                GPSTrackView(
                                    trackCoordinates: viewModel.trackCoordinates,
                                    currentCoordinate: viewModel.currentCoordinate
                                )
                                .frame(
                                    width: geo.size.width * 0.18,
                                    height: geo.size.width * 0.13
                                )
                                .shadow(radius: 3)
                                .position(
                                    x: geo.size.width - geo.size.width * 0.09 - 6,
                                    y: geo.size.width * 0.065 + 6
                                )
                            }
                        }
                    }
                    .overlay {
                        // Data + text overlay on top
                        OverlayView(overlayImage: viewModel.overlayImage)
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity)

                // Compact controls
                controlsBar
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                // Status bar
                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                }
            }

            // Right panel
            if showRightPanel {
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
                                onSeek: { time in viewModel.seek(to: time) }
                            )
                        case .textOverlay:
                            TextOverlayEditView(
                                overlays: $viewModel.textOverlays,
                                videoDuration: viewModel.duration,
                                isTextFocused: $isTextFieldFocused
                            )
                        case .youtube:
                            YouTubeDescriptionView(
                                dataPoints: viewModel.fitDataPoints,
                                videoStartDate: viewModel.videoMetadatas.first?.creationDate
                            )
                        }
                    }
                }
                .frame(width: 340)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if !viewModel.videoLoaded {
                dropPrompt
            }
        }
        .sheet(isPresented: $viewModel.showExport) {
            ExportView(viewModel: viewModel.makeExportViewModel())
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.showFileList.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("ファイル一覧・設定")

                Button {
                    showRightPanel.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("編集パネル")

                Button {
                    viewModel.showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("エクスポート")
                .disabled(!viewModel.videoLoaded || !viewModel.fitLoaded)
            }
        }
        // Keyboard shortcuts (disabled when editing text)
        .onKeyPress(.leftArrow) {
            guard !isTextFieldFocused else { return .ignored }
            viewModel.skipBackward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isTextFieldFocused else { return .ignored }
            viewModel.skipForward()
            return .handled
        }
        .onKeyPress("j") {
            guard !isTextFieldFocused else { return .ignored }
            viewModel.skipBackward(10)
            return .handled
        }
        .onKeyPress("l") {
            guard !isTextFieldFocused else { return .ignored }
            viewModel.skipForward(10)
            return .handled
        }
        .onKeyPress("k") {
            guard !isTextFieldFocused else { return .ignored }
            viewModel.togglePlayback()
            return .handled
        }
        .onKeyPress(",") {
            guard !isTextFieldFocused else { return .ignored }
            viewModel.cyclePlaybackRate()
            return .handled
        }
    }

    // MARK: - Controls bar (compact)

    private var controlsBar: some View {
        VStack(spacing: 4) {
            // Seek bar with trim indicators
            HStack(spacing: 6) {
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)

                ZStack {
                    Slider(value: $viewModel.currentTime, in: 0...max(viewModel.duration, 1)) { editing in
                        if editing {
                            viewModel.beginSeeking()
                        } else {
                            viewModel.seek(to: viewModel.currentTime)
                        }
                    }
                    .controlSize(.small)

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
                }

                Text(formatTime(viewModel.trimmedTotalDuration()))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    viewModel.cyclePlaybackRate()
                } label: {
                    Text("\(String(format: "%.1f", viewModel.playbackRate))x")
                        .font(.system(size: 10).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.borderless)

                Spacer()

                // Sync offset
                if viewModel.fitLoaded {
                    HStack(spacing: 3) {
                        Text("同期:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { viewModel.syncOffset },
                            set: { viewModel.updateSyncOffset($0) }
                        ), in: -30...30, step: 0.5)
                        .frame(width: 80)
                        .controlSize(.small)
                        Text(String(format: "%+.1fs", viewModel.syncOffset))
                            .font(.system(size: 10).monospacedDigit())
                            .frame(width: 35)
                    }
                }

                if viewModel.videoURLs.count > 1 {
                    Text("\(viewModel.videoURLs.count)本")
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Drop prompt

    private var dropPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("FIT ファイルと動画をドラッグ&ドロップ")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(".fit + .mp4 / .mov")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let ext = url.pathExtension.lowercased()
                Task { @MainActor in
                    if ext == "fit" {
                        viewModel.loadFITFile(url: url)
                    } else if ["mp4", "mov", "m4v"].contains(ext) {
                        await viewModel.loadVideo(url: url)
                    }
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
}

#Preview {
    PreviewView()
        .frame(width: 1100, height: 700)
}
