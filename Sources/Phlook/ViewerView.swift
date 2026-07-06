import SwiftUI
import AVKit
import PhlookCore

struct ViewerView: View {
    @ObservedObject var vm: LibraryViewModel
    @State private var monitor = ViewerInputMonitor()
    @State private var player: AVPlayer?
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
            chevrons
            topBar
        }
        .overlay(alignment: .trailing) { sidebarHost }   // Task 7 fills this
        .onAppear {
            monitor.onLeft = { vm.step(-1) }
            monitor.onRight = { vm.step(+1) }
            monitor.onEscape = { vm.closeViewer() }
            monitor.onToggleSidebar = { vm.sidebarOpen.toggle() }
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
            player?.pause()
        }
        .task(id: vm.viewerIndex) { await loadCurrent() }
    }

    @ViewBuilder private var sidebarHost: some View {
        EmptyView()   // replaced by DetailsSidebar in Task 7
    }

    @ViewBuilder private var media: some View {
        if missing {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.square.dashed").font(.largeTitle)
                Text("File is missing on disk").foregroundStyle(.secondary)
            }
        } else if let player {
            VideoPlayer(player: player)
        } else if let image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            ProgressView()
        }
    }

    private var chevrons: some View {
        HStack {
            Button { vm.step(-1) } label: { chevron("chevron.left") }
                .disabled(vm.viewerIndex == 0)
            Spacer()
            Button { vm.step(+1) } label: { chevron("chevron.right") }
                .disabled(vm.viewerIndex == vm.items.count - 1)
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
                        Text(ViewerMath.positionString(index: i, count: vm.items.count))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
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

    private func loadCurrent() async {
        player?.pause()
        player = nil
        image = nil
        missing = false
        guard let item = vm.currentItem else { return }
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: item.path) else {
            missing = true
            return
        }
        if item.fileType == "video" {
            player = AVPlayer(url: url)
        } else {
            let capturedIndex = vm.viewerIndex
            let maxPixel = (NSScreen.main.map { $0.frame.width * $0.backingScaleFactor } ?? 2560) * 2
            let loaded = await Task.detached {
                Self.downsampledImage(at: url, maxPixel: maxPixel)
            }.value
            // Rapid navigation: only publish if this decode is still the current item.
            if vm.viewerIndex == capturedIndex { image = loaded }
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
