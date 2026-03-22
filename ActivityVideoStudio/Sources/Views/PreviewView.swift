import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Main preview screen: video + overlay + minimap + controls.
struct PreviewView: View {
    @StateObject private var viewModel = PreviewViewModel()
    @State private var rightPanelTab: RightPanelTab = .settings
    @FocusState private var isTextFieldFocused: Bool

    enum RightPanelTab: String, CaseIterable {
        case settings = "設定"
        case textOverlay = "テキスト"
        case trim = "トリム"
        case youtube = "YouTube"
    }

    var body: some View {
        HSplitView {
            // Left sidebar: file list
            if viewModel.showFileList {
                FileListView(
                    fitURL: viewModel.fitURL,
                    fitPointCount: viewModel.fitDataPoints.count,
                    videoURLs: viewModel.videoURLs,
                    videoDurations: viewModel.videoMetadatas.map { $0.duration },
                    onRemoveVideo: { viewModel.removeVideo(at: $0) }
                )
                .frame(minWidth: 180, maxWidth: 250)
            }

            // Main content
            VStack(spacing: 0) {
                // Video area
                ZStack(alignment: .topTrailing) {
                    VideoPlayerView(player: viewModel.player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)

                    // GPS Track - right top
                    if viewModel.overlaySettings.showMiniMap && !viewModel.trackCoordinates.isEmpty {
                        GPSTrackView(
                            trackCoordinates: viewModel.trackCoordinates,
                            currentCoordinate: viewModel.currentCoordinate
                        )
                        .frame(width: 240, height: 180)
                        .shadow(radius: 4)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                    }

                    // Overlay (data + text) - drawn OVER map
                    OverlayView(overlayImage: viewModel.overlayImage)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)

                // Controls
                controlsBar

                // Status bar
                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }

            // Right panel
            if viewModel.showSettings {
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
                        case .settings:
                            OverlaySettingsView(settings: viewModel.overlaySettings)
                        case .textOverlay:
                            TextOverlayEditView(
                                overlays: $viewModel.textOverlays,
                                videoDuration: viewModel.duration,
                                isTextFocused: $isTextFieldFocused
                            )
                        case .trim:
                            TrimView(
                                trimSettings: $viewModel.trimSettings,
                                videoNames: viewModel.videoURLs.map { $0.lastPathComponent },
                                videoDurations: viewModel.videoMetadatas.map { $0.duration }
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
                .help("ファイル一覧")

                Button {
                    viewModel.showSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("設定パネル")

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

    // MARK: - Controls bar

    private var controlsBar: some View {
        VStack(spacing: 8) {
            // Seek bar with trim indicators
            HStack {
                Text(formatTime(viewModel.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                ZStack {
                    Slider(value: $viewModel.currentTime, in: 0...max(viewModel.duration, 1)) { editing in
                        if editing {
                            viewModel.beginSeeking()
                        } else {
                            viewModel.seek(to: viewModel.currentTime)
                        }
                    }

                    // Trim indicators on seek bar
                    GeometryReader { geo in
                        let totalDur = max(viewModel.duration, 1)
                        let trimInfo = viewModel.trimRangesForSeekbar()

                        ForEach(Array(trimInfo.enumerated()), id: \.offset) { _, range in
                            // Start trim
                            if range.startFrac > 0 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.3))
                                    .frame(width: geo.size.width * range.startFrac)
                                    .allowsHitTesting(false)
                            }
                            // End trim
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

                // Show trimmed duration instead of total
                let trimmedDuration = viewModel.trimmedTotalDuration()
                Text(formatTime(trimmedDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                // Playback rate
                Button {
                    viewModel.cyclePlaybackRate()
                } label: {
                    Text("\(String(format: "%.1f", viewModel.playbackRate))x")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.borderless)

                Spacer()

                // Sync offset
                if viewModel.fitLoaded {
                    HStack(spacing: 4) {
                        Text("同期:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { viewModel.syncOffset },
                            set: { viewModel.updateSyncOffset($0) }
                        ), in: -30...30, step: 0.5)
                        .frame(width: 120)
                        Text(String(format: "%+.1fs", viewModel.syncOffset))
                            .font(.caption.monospacedDigit())
                            .frame(width: 45)
                    }
                }

                // Video count
                if viewModel.videoURLs.count > 1 {
                    Text("\(viewModel.videoURLs.count)本")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
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

    // MARK: - Formatting

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    PreviewView()
        .frame(width: 1100, height: 700)
}
