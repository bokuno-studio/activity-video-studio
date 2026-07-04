import SwiftUI
import AVFoundation
import QuartzCore

/// AVPlayer wrapper for SwiftUI.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    @Binding var videoRect: CGRect
    let onScrollSeek: ((TimeInterval) -> Void)?

    init(
        player: AVPlayer,
        videoRect: Binding<CGRect> = .constant(.zero),
        onScrollSeek: ((TimeInterval) -> Void)? = nil
    ) {
        self.player = player
        self._videoRect = videoRect
        self.onScrollSeek = onScrollSeek
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        let videoRect = $videoRect
        view.onVideoRectChange = { rect in
            videoRect.wrappedValue = rect
        }
        view.player = player
        view.onScrollSeek = onScrollSeek
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let videoRect = $videoRect
        nsView.onVideoRectChange = { rect in
            videoRect.wrappedValue = rect
        }
        nsView.player = player
        nsView.onScrollSeek = onScrollSeek
        nsView.publishVideoRect()
    }
}

/// Simple AVPlayerView that renders the video layer.
class AVPlayerView: NSView {
    var player: AVPlayer? {
        didSet {
            guard oldValue !== player else {
                publishVideoRect()
                return
            }

            (layer as? AVPlayerLayer)?.player = player
            observePlayer()
            publishVideoRect()
        }
    }
    var onScrollSeek: ((TimeInterval) -> Void)?
    var onVideoRectChange: ((CGRect) -> Void)?
    private var lastPublishedVideoRect = CGRect.null
    private var currentItemObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = Self.makePlayerLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = Self.makePlayerLayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        CATransaction.commit()
        publishVideoRect()
    }

    func publishVideoRect() {
        let rect = normalizedVideoRect()
        guard !rect.isNearlyEqual(to: lastPublishedVideoRect) else { return }
        lastPublishedVideoRect = rect
        DispatchQueue.main.async { [weak self] in
            self?.onVideoRectChange?(rect)
        }
    }

    private func normalizedVideoRect() -> CGRect {
        guard let playerLayer = layer as? AVPlayerLayer,
              bounds.width > 0,
              bounds.height > 0 else {
            return .zero
        }

        return playerLayer.videoRect
    }

    private func observePlayer() {
        currentItemObservation = player?.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.observeCurrentItem(player.currentItem)
            }
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        presentationSizeObservation = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.publishVideoRect()
            }
        }
        statusObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.publishVideoRect()
            }
        }
        publishVideoRect()
    }

    private static func makePlayerLayer() -> AVPlayerLayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.needsDisplayOnBoundsChange = true
        return layer
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

private extension CGRect {
    func isNearlyEqual(to other: CGRect) -> Bool {
        guard isNull == other.isNull else { return false }
        if isNull { return true }

        let epsilon: CGFloat = 0.5
        return abs(origin.x - other.origin.x) < epsilon &&
            abs(origin.y - other.origin.y) < epsilon &&
            abs(size.width - other.size.width) < epsilon &&
            abs(size.height - other.size.height) < epsilon
    }
}
