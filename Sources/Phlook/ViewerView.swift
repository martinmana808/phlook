import SwiftUI
import AVKit
import PhlookCore

struct ViewerView: View {
    @ObservedObject var vm: LibraryViewModel
    @State private var monitor = ViewerInputMonitor()
    @State private var player: AVPlayer?
    @State private var livePlayer: AVPlayer?
    @State private var liveEndObserver: NSObjectProtocol?
    @State private var liveFailureObserver: NSObjectProtocol?
    @State private var image: NSImage?
    @State private var missing = false
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var hasSharpened = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
            chevrons
            topBar
        }
        // Double-click anywhere (that isn't a control) closes the viewer,
        // mirroring the double-click that opened it from the grid.
        .gesture(TapGesture(count: 2).onEnded { vm.closeViewer() })
        .contextMenu {
            if let item = vm.currentItem {
                Button("Copy") { Self.copyFile(item) }
                if item.fileType == "image" {
                    Button("Copy Image") { Self.copyImageData(item) }
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: item.path)])
                }
            }
        }
        .overlay(alignment: .trailing) { sidebarHost }
        .animation(.easeInOut(duration: 0.2), value: vm.sidebarOpen)
        .onAppear {
            monitor.onLeft = { vm.step(-1) }
            monitor.onRight = { vm.step(+1) }
            monitor.onEscape = { vm.closeViewer() }
            monitor.onToggleSidebar = { vm.sidebarOpen.toggle() }
            monitor.onDelete = { if let item = vm.currentItem { vm.requestTrash([item]) } }
            monitor.isSuspended = { vm.pendingTrash != nil || vm.trashFailures != nil || vm.detailsItem != nil }
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
            player?.pause()
            stopLivePlayback()
        }
        .task(id: vm.currentItem?.path) { await loadCurrent() }
    }

    @ViewBuilder private var sidebarHost: some View {
        if vm.sidebarOpen, let item = vm.currentItem {
            DetailsSidebar(
                item: item,
                motionPath: vm.livePairs.videoPath(forImagePath: item.path),
                onClose: { vm.sidebarOpen = false }
            )
            .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder private var media: some View {
        if missing {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.square.dashed").font(.largeTitle)
                Text("File is missing on disk").foregroundStyle(.secondary)
            }
        } else if let player {
            // AppKit AVPlayerView, not SwiftUI's VideoPlayer: the _AVKit_SwiftUI
            // overlay aborts in runtime metadata instantiation on this
            // macOS/CLT-SDK combination (verified crash report 2026-07-06).
            PlayerHostView(player: player)
        } else if let livePlayer {
            PlayerHostView(player: livePlayer)
        } else if let image {
            zoomableImage(image)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private func zoomableImage(_ img: NSImage) -> some View {
        GeometryReader { geo in
            let fitted = ViewerMath.fitSize(image: img.size, in: geo.size)
            Group {
                if zoom <= 1.001 {
                    // Bypass the ScrollView at 1x: plain scaledToFit stays centered.
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .gesture(magnifyGesture)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = ViewerMath.clampZoom(baseZoom * value.magnification)
                if zoom >= ViewerMath.sharpenZoomThreshold { checkSharpen() }
            }
            .onEnded { _ in
                baseZoom = zoom
            }
    }

    /// Binding used by the top-bar slider/reset so slider drags and the
    /// magnify gesture agree on the "current base zoom" for the next pinch.
    private var zoomBinding: Binding<CGFloat> {
        Binding(
            get: { zoom },
            set: { newValue in
                zoom = ViewerMath.clampZoom(newValue)
                baseZoom = zoom
                if zoom >= ViewerMath.sharpenZoomThreshold { checkSharpen() }
            }
        )
    }

    /// Past `sharpenZoomThreshold`, the fitted-then-upscaled decode looks
    /// soft — re-decode once at a much higher pixel cap and swap it in.
    private func checkSharpen() {
        guard !hasSharpened, let item = vm.currentItem, item.fileType != "video" else { return }
        hasSharpened = true
        let capturedPath = item.path
        let url = URL(fileURLWithPath: item.path)
        let maxPixel = (NSScreen.main.map { $0.frame.width * $0.backingScaleFactor } ?? 2560) * 4
        Task {
            let loaded = await Task.detached {
                Self.downsampledImage(at: url, maxPixel: maxPixel)
            }.value
            if vm.currentItem?.path == capturedPath, let loaded {
                image = loaded
            }
        }
    }

    private var chevrons: some View {
        HStack {
            Button { vm.step(-1) } label: { chevron("chevron.left") }
                .disabled(vm.viewerIndex == 0)
            Spacer()
            Button { vm.step(+1) } label: { chevron("chevron.right") }
                .disabled(vm.viewerIndex == vm.visibleItems.count - 1)
        }
        .padding(.horizontal, 16)
        .buttonStyle(.plain)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title)
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.35), in: Circle())
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 12) {
                Button { vm.closeViewer() } label: {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if let item = vm.currentItem {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .foregroundStyle(.white).lineLimit(1)
                    if let i = vm.viewerIndex {
                        Text(ViewerMath.positionString(index: i, count: vm.visibleItems.count))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                if let item = vm.currentItem, item.fileType != "video", livePlayer == nil {
                    Button {
                        zoom = 1
                        baseZoom = 1
                    } label: {
                        Text("1×").foregroundStyle(.white).monospacedDigit()
                    }
                    Slider(value: zoomBinding, in: ViewerMath.minZoom...ViewerMath.maxZoom)
                        .frame(width: 120)
                }
                if let item = vm.currentItem, vm.isLive(item) {
                    Button {
                        playLive(for: item)
                    } label: {
                        Label("LIVE", systemImage: "livephoto")
                            .foregroundStyle(.white)
                    }
                    .disabled(livePlayer != nil)
                }
                Button { vm.sidebarOpen.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(12)
            .background(.black.opacity(0.35))
            Spacer()
        }
    }

    private func playLive(for item: MediaItem) {
        stopLivePlayback()
        guard let motion = vm.livePairs.videoPath(forImagePath: item.path) else { return }
        let player = AVPlayer(url: URL(fileURLWithPath: motion))
        livePlayer = player
        liveEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { _ in
            Task { @MainActor in
                self.stopLivePlayback()
            }
        }
        liveFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem, queue: .main) { _ in
            Task { @MainActor in
                self.stopLivePlayback()
            }
        }
        player.play()
    }

    private func stopLivePlayback() {
        livePlayer?.pause()
        livePlayer = nil
        if let token = liveEndObserver {
            NotificationCenter.default.removeObserver(token)
            liveEndObserver = nil
        }
        if let token = liveFailureObserver {
            NotificationCenter.default.removeObserver(token)
            liveFailureObserver = nil
        }
    }

    private func loadCurrent() async {
        stopLivePlayback()
        player?.pause()
        player = nil
        image = nil
        missing = false
        zoom = 1
        baseZoom = 1
        hasSharpened = false
        guard let item = vm.currentItem else { return }
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: item.path) else {
            missing = true
            return
        }
        if item.fileType == "video" {
            player = AVPlayer(url: url)
        } else {
            let capturedPath = item.path
            let maxPixel = (NSScreen.main.map { $0.frame.width * $0.backingScaleFactor } ?? 2560) * 2
            let loaded = await Task.detached {
                Self.downsampledImage(at: url, maxPixel: maxPixel)
            }.value
            // Rapid navigation: only publish if this decode is still the current item.
            if vm.currentItem?.path == capturedPath { image = loaded }
        }
    }

    /// Decode at bounded size so 48MP HEICs don't balloon memory.
    nonisolated static func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

extension ViewerView {
    /// Copy the file itself — pasteable into Finder, Mail, iMessage, Final Cut.
    static func copyFile(_ item: MediaItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: item.path) as NSURL])
    }

    /// Copy decoded image data — pasteable into image editors and documents.
    static func copyImageData(_ item: MediaItem) {
        guard let image = NSImage(contentsOf: URL(fileURLWithPath: item.path)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }
}

/// AppKit-backed player host. Deliberately avoids SwiftUI's `VideoPlayer`:
/// its _AVKit_SwiftUI overlay crashes (SIGABRT in generic-metadata init) when
/// built with Command Line Tools SDK and run on macOS 26.
private struct PlayerHostView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
