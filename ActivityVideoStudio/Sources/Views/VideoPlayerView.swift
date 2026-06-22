import SwiftUI
import AVFoundation

/// AVPlayer wrapper for SwiftUI.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let onScrollSeek: ((TimeInterval) -> Void)?

    init(player: AVPlayer, onScrollSeek: ((TimeInterval) -> Void)? = nil) {
        self.player = player
        self.onScrollSeek = onScrollSeek
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.onScrollSeek = onScrollSeek
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.onScrollSeek = onScrollSeek
    }
}

/// Simple AVPlayerView that renders the video layer.
class AVPlayerView: NSView {
    var player: AVPlayer? {
        didSet {
            (layer as? AVPlayerLayer)?.player = player
        }
    }
    var onScrollSeek: ((TimeInterval) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = AVPlayerLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = AVPlayerLayer()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }

        let magnitude: TimeInterval
        if event.hasPreciseScrollingDeltas {
            magnitude = min(max(TimeInterval(abs(deltaY)) / 40.0, 0.05), 3.0)
        } else {
            magnitude = max(1.0, min(TimeInterval(abs(deltaY)), 3.0))
        }

        onScrollSeek?(deltaY < 0 ? magnitude : -magnitude)
    }
}
