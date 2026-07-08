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

    // MARK: Photos-style open/close zoom animation state.
    // `expandFrame` is the current rect (in this view's local space, which
    // shares its origin with the "phlookWindow" named space — ViewerView is
    // an unpadded full-window layer) of the animating snapshot layer; nil
    // means "not animating", i.e. show the real media layer at full opacity.
    @State private var expandFrame: CGRect?
    @State private var expandImage: NSImage?
    @State private var backdropOpacity: Double = 1
    @State private var showChrome = true
    @State private var contentOpacity: Double = 1   // fallback whole-view fade when no cell rect is known
    @State private var fullRect: CGRect = .zero
    @State private var hasStartedOpen = false
    @State private var isClosing = false
    @State private var openCleanupTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(backdropOpacity).ignoresSafeArea()
                media.opacity(expandFrame == nil ? 1 : 0)
                if let expandFrame {
                    Group {
                        if let expandImage {
                            Image(nsImage: expandImage).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color(white: 0.15)
                        }
                    }
                    .frame(width: max(expandFrame.width, 1), height: max(expandFrame.height, 1))
                    .clipped()
                    .position(x: expandFrame.midX, y: expandFrame.midY)
                    .allowsHitTesting(false)
                }
                chevrons.opacity(showChrome ? 1 : 0)
                topBar.opacity(showChrome ? 1 : 0)
            }
            .opacity(contentOpacity)
            .onAppear {
                fullRect = CGRect(origin: .zero, size: geo.size)
                beginOpenAnimation()
            }
            .onChange(of: geo.size) { _, newSize in
                fullRect = CGRect(origin: .zero, size: newSize)
            }
        }
        // Double-click anywhere (that isn't a control) closes the viewer,
        // mirroring the double-click that opened it from the grid.
        .gesture(TapGesture(count: 2).onEnded { closeAnimated() })
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
            monitor.onEscape = { closeAnimated() }
            monitor.onToggleSidebar = { vm.sidebarOpen.toggle() }
            monitor.onDelete = { if let item = vm.currentItem { vm.requestTrash([item]) } }
            monitor.isSuspended = { vm.pendingTrash != nil || vm.trashFailures != nil || vm.detailsItem != nil }
            monitor.currentZoom = zoom
            monitor.start()
        }
        .onChange(of: zoom) { _, newZoom in
            // Mirrored onto the (class) monitor because its stored closures
            // can't observe this view's @State directly — see
            // ViewerInputMonitor.currentZoom.
            monitor.currentZoom = newZoom
        }
        .onDisappear {
            monitor.stop()
            player?.pause()
            stopLivePlayback()
        }
        .task(id: vm.currentItem?.path) { await loadCurrent() }
    }

    /// Grows the media layer from the tapped grid cell's frame to the fitted
    /// full-window rect. Runs once per viewer presentation (guarded by
    /// `hasStartedOpen`) — subsequent `step()` navigation doesn't retrigger
    /// it. Falls back to a plain fade when no origin cell frame was captured
    /// (e.g. opened some other way than a grid double-click, or the frame
    /// lookup missed).
    private func beginOpenAnimation() {
        guard !hasStartedOpen else { return }
        hasStartedOpen = true
        guard let origin = vm.viewerOpenOriginFrame, fullRect != .zero else {
            contentOpacity = 0
            withAnimation(.easeInOut(duration: 0.2)) { contentOpacity = 1 }
            return
        }
        if let item = vm.currentItem {
            expandImage = vm.cachedThumbnail(for: item, size: vm.density.rawValue)
        }
        showChrome = false
        backdropOpacity = 0
        expandFrame = origin
        withAnimation(.easeOut(duration: 0.28)) {
            expandFrame = centeredFullRect(for: vm.currentItem)
            backdropOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.22).delay(0.12)) {
            showChrome = true
        }
        openCleanupTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            expandFrame = nil
            expandImage = nil
            vm.viewerOpenOriginFrame = nil
        }
    }

    /// Shrinks the media layer back to the (re-resolved — the grid may have
    /// scrolled while the viewer was open) origin cell's current frame, then
    /// closes the viewer. Falls back to a plain fade if the cell is no
    /// longer materialized (scrolled offscreen, filtered out, deleted).
    /// All close paths (Esc, ✕, double-click) route through here.
    private func closeAnimated() {
        guard !isClosing else { return }
        isClosing = true
        openCleanupTask?.cancel()
        openCleanupTask = nil
        guard let path = vm.currentItem?.path, let origin = vm.cellFrames[path], fullRect != .zero else {
            withAnimation(.easeInOut(duration: 0.2)) { contentOpacity = 0 }
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                vm.closeViewer()
            }
            return
        }
        if expandImage == nil {
            expandImage = vm.currentItem.flatMap { vm.cachedThumbnail(for: $0, size: vm.density.rawValue) } ?? image
        }
        expandFrame = centeredFullRect(for: vm.currentItem)
        withAnimation(.easeIn(duration: 0.15)) { showChrome = false }
        withAnimation(.easeIn(duration: 0.28)) {
            expandFrame = origin
            backdropOpacity = 0
        }
        Task {
            try? await Task.sleep(nanoseconds: 290_000_000)
            vm.closeViewer()
        }
    }

    /// The full-window rect, narrowed to the item's own aspect-fit size and
    /// centered within it. Animating the snapshot to/from this rect (instead
    /// of the raw `fullRect`) means its frame already matches the image's
    /// aspect ratio when the real `.scaledToFit` media view takes over, so
    /// there's no letterbox/aspect "pop" at the open/close handoff. Falls
    /// back to the raw full rect when the item's natural size isn't known.
    private func centeredFullRect(for item: MediaItem?) -> CGRect {
        guard let item, let w = item.width, let h = item.height, w > 0, h > 0,
              fullRect != .zero else {
            return fullRect
        }
        let size = ViewerMath.fitSize(image: CGSize(width: w, height: h), in: fullRect.size)
        let origin = CGPoint(x: fullRect.midX - size.width / 2, y: fullRect.midY - size.height / 2)
        return CGRect(origin: origin, size: size)
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
                    // Content frame is at least the viewport size so the image
                    // stays centered until it actually exceeds the viewport in
                    // that dimension — otherwise the ScrollView's top-leading
                    // content anchor snaps the image away from center the
                    // instant zoom crosses 1x.
                    let contentSize = CGSize(
                        width: max(fitted.width * zoom, geo.size.width),
                        height: max(fitted.height * zoom, geo.size.height)
                    )
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            Image(nsImage: img)
                                .resizable()
                                .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                        }
                        .frame(width: contentSize.width, height: contentSize.height)
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
                Button { closeAnimated() } label: {
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
