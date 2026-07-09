import SwiftUI
import AVKit
import PhlookCore

/// Non-destructive Live Photo poster-frame picker (#10): scrub the paired
/// motion file and pick a frame to use as the still's poster. The chosen
/// frame's time offset is stored in the DB (`MediaItem.posterTime`) — the
/// original HEIC and MOV are never modified.
struct PosterPickerSheet: View {
    @ObservedObject var vm: LibraryViewModel
    let item: MediaItem
    let motionPath: String
    let onDismiss: () -> Void

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 16) {
            Text("Set Poster Frame").font(.headline)
            if let player {
                // AppKit AVPlayerView — SwiftUI's VideoPlayer crashes on this
                // SDK/macOS combination (see ViewerView.PlayerHostView).
                PosterPlayerHostView(player: player)
                    .frame(width: 480, height: 360)
            } else {
                Color.black.frame(width: 480, height: 360)
            }
            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { newValue in
                        currentTime = newValue
                        player?.seek(to: CMTime(seconds: newValue, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                ),
                in: 0...max(duration, 0.01)
            )
            .padding(.horizontal)

            HStack {
                Button("Cancel") { onDismiss() }
                Spacer()
                Button("Reset to Original") {
                    vm.setPosterTime(item, time: nil)
                    onDismiss()
                }
                Button("Use This Frame") {
                    vm.setPosterTime(item, time: currentTime)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            let p = AVPlayer(url: URL(fileURLWithPath: motionPath))
            player = p
            Task {
                let asset = p.currentItem?.asset ?? AVURLAsset(url: URL(fileURLWithPath: motionPath))
                let d = (try? await asset.load(.duration).seconds) ?? 0
                duration = d.isFinite && d > 0 ? d : 0
                let startTime = item.posterTime ?? 0
                currentTime = min(startTime, duration)
                await p.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
            }
            timeObserver = p.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
            ) { time in
                currentTime = time.seconds
            }
        }
        .onDisappear {
            if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player?.pause()
            player = nil
        }
    }
}

/// AppKit-backed player host for the picker's preview, mirroring
/// ViewerView.PlayerHostView (SwiftUI's VideoPlayer crashes on this SDK).
private struct PosterPlayerHostView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
