import SwiftUI
import PhlookCore

struct ThumbCell: View {
    let item: MediaItem
    let vm: LibraryViewModel
    // Passed as plain values (not read via `vm` in body): SwiftUI diffs the
    // cell's stored properties to decide whether to re-render, and `vm` is a
    // reference that never "changes" — rings/badges would go stale otherwise.
    let isSelected: Bool
    let showsCheckmark: Bool   // tick only in multi-selection; a lone ring is enough
    let isLive: Bool
    let side: CGFloat
    @State private var image: NSImage?
    @ObservedObject private var hover = HoverPreviewCoordinator.shared

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            if hover.activePath == item.path, let player = hover.player {
                HoverPreviewPlayer(player: player)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if item.fileType == "video", !isLive,
               let text = DurationFormatter.string(seconds: item.duration) {
                Text(text)
                    .font(side >= 160 ? .caption.monospacedDigit() : .caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if item.fileType == "video", !isLive {
                Image(systemName: "play.fill")
                    .font(.system(size: side >= 160 ? 12 : 9))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if isLive {
                Image(systemName: "livephoto")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsCheckmark {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard item.fileType == "video", !isLive,
                  let d = item.duration, d > 0 else { return }
            if inside { hover.hoverBegan(path: item.path) }
            else { hover.hoverEnded(path: item.path) }
        }
        // LazyVGrid recycling: a previewing cell scrolled offscreen never gets
        // onHover(false) — stop its player when the cell leaves the hierarchy.
        .onDisappear { hover.hoverEnded(path: item.path) }
        .gesture(TapGesture(count: 2).onEnded {
            HoverPreviewCoordinator.shared.stop()
            vm.openViewer(item)
        })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            let flags = NSEvent.modifierFlags
            vm.select(item, commandKey: flags.contains(.command), shiftKey: flags.contains(.shift))
        })
        .contextMenu {
            Button("Open") { vm.openViewer(item) }
            Button("View Details") { vm.detailsItem = item }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Divider()
            Button(trashTitle, role: .destructive) {
                if !vm.selectedPaths.contains(item.path) {
                    vm.select(item, commandKey: false, shiftKey: false)
                }
                let targets = vm.visibleItems.filter { vm.selectedPaths.contains($0.path) }
                vm.requestTrash(targets.isEmpty ? [item] : targets)
            }
        }
        .task(id: side) { image = await vm.thumbnail(for: item, size: Int(side * 2)) }
    }

    private var trashTitle: String {
        let n = vm.selectedPaths.contains(item.path) ? max(vm.selectedPaths.count, 1) : 1
        return n > 1 ? "Move \(n) Items to Trash" : "Move to Trash"
    }
}

struct MicroGridView: View {
    @ObservedObject var vm: LibraryViewModel
    @ObservedObject var importer: PhoneImportController
    private var columns: [GridItem] {
        let side = CGFloat(vm.density.rawValue)
        return [GridItem(.adaptive(minimum: side, maximum: side), spacing: 2)]
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            content
        }
        .background(GridKeyCatcher(vm: vm))
        // Subtle "updating" chip while a background re-scan runs over already-shown items.
        .overlay(alignment: .bottomTrailing) {
            if vm.isIndexing && !vm.items.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 16) {
            Picker("Filter", selection: $vm.filter) {
                ForEach(MediaFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            Picker("Density", selection: $vm.density) {
                ForEach(GridDensity.allCases) { d in
                    Image(systemName: d.symbol).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            ImportBar(importer: importer)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if vm.visibleItems.isEmpty {
            VStack(spacing: 12) {
                if vm.isIndexing && vm.items.isEmpty {
                    ProgressView()
                    Text("Indexing your library…")
                        .foregroundStyle(.secondary)
                } else if vm.items.isEmpty {
                    Text("No media found in ~/Pictures/PHLOOK")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No \(vm.filter.rawValue.lowercased()) to show")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(vm.visibleItems, id: \.path) { item in
                            ThumbCell(item: item, vm: vm,
                                      isSelected: vm.selectedPaths.contains(item.path),
                                      showsCheckmark: vm.selectedPaths.count > 1
                                          && vm.selectedPaths.contains(item.path),
                                      isLive: vm.isLive(item),
                                      side: CGFloat(vm.density.rawValue))
                                .id(item.path)
                        }
                    }
                    .padding(2)
                }
                .overlay(alignment: .trailing) {
                    if vm.timeline.count >= 2 {
                        TimelineRail(buckets: vm.timeline) { path in
                            proxy.scrollTo(path, anchor: .top)
                        }
                    }
                }
            }
        }
    }
}

/// Grid-scoped key handling: ⌘A select-all, Esc clear, Delete → trash selection.
/// Local NSEvent monitor active only while the viewer is closed.
private struct GridKeyCatcher: NSViewRepresentable {
    let vm: LibraryViewModel

    func makeNSView(context: Context) -> NSView { KeyView(vm: vm) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    final class KeyView: NSView {
        let vm: LibraryViewModel
        private var monitor: Any?

        init(vm: LibraryViewModel) {
            self.vm = vm
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.vm.viewerIndex == nil else { return event }
                guard self.vm.pendingTrash == nil, self.vm.trashFailures == nil,
                      self.vm.detailsItem == nil else { return event }
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "a" {
                    self.vm.selectAllVisible(); return nil
                }
                if event.modifierFlags.contains(.command),
                   let chars = event.charactersIgnoringModifiers {
                    if chars == "=" || chars == "+" {
                        self.vm.stepDensity(1); return nil
                    }
                    if chars == "-" {
                        self.vm.stepDensity(-1); return nil
                    }
                }
                switch event.keyCode {
                case 53:          // Esc
                    guard !self.vm.selectedPaths.isEmpty else { return event }
                    self.vm.clearSelection(); return nil
                case 51, 117:     // Delete / Forward-delete
                    let targets = self.vm.visibleItems.filter { self.vm.selectedPaths.contains($0.path) }
                    guard !targets.isEmpty else { return event }
                    self.vm.requestTrash(targets); return nil
                default:
                    return event
                }
            }
        }

        required init?(coder: NSCoder) { fatalError() }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
