import SwiftUI
import AVFoundation

/// AVPlayer wrapper for SwiftUI.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Simple AVPlayerView that renders the video layer.
class AVPlayerView: NSView {
    var player: AVPlayer? {
        didSet {
            (layer as? AVPlayerLayer)?.player = player
        }
    }

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
}
