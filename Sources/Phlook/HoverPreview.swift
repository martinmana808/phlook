import SwiftUI
import AVFoundation
import AVKit

/// One muted, looping preview player app-wide; hovering a new cell steals it.
@MainActor
final class HoverPreviewCoordinator: ObservableObject {
    static let shared = HoverPreviewCoordinator()
    @Published private(set) var activePath: String?
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pendingTask: Task<Void, Never>?
    private var pendingPath: String?

    /// `path` is the identity key (used for hover/active-cell comparisons);
    /// `loadURL` is the actual file to play, which may be the item's 10%
    /// small version when the original has been reclaimed (trashed after
    /// SSD archive).
    func hoverBegan(path: String, loadURL: URL) {
        pendingTask?.cancel()
        pendingPath = path
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.start(path: path, loadURL: loadURL)
        }
    }

    func hoverEnded(path: String) {
        if pendingPath == path {
            pendingTask?.cancel()
            pendingPath = nil
        }
        if activePath == path { stop() }
    }

    private func start(path: String, loadURL: URL) {
        pendingPath = nil
        stop()
        let item = AVPlayerItem(url: loadURL)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        activePath = path
        queue.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        activePath = nil
    }
}

struct HoverPreviewPlayer: NSViewRepresentable {
    let player: AVQueuePlayer

    func makeNSView(context: Context) -> AVPlayerLayerView { AVPlayerLayerView(player: player) }
    func updateNSView(_ nsView: AVPlayerLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class AVPlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
