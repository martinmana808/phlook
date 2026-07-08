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
        // Stash this cell's frame (in the shared "phlookWindow" space) so the
        // viewer's open/close animation can grow/shrink from/to it, even
        // after scrolling moves the cell around.
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named("phlookWindow"))
                Color.clear
                    .onAppear { vm.cellFrames[item.path] = frame }
                    .onChange(of: frame) { _, newFrame in
                        vm.cellFrames[item.path] = newFrame
                    }
            }
        )
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
        // Also drop its stashed frame so a recycled cell can't serve a stale
        // rect to the viewer's close animation (closeAnimated's fade fallback
        // covers items with no materialized cell).
        .onDisappear {
            hover.hoverEnded(path: item.path)
            vm.cellFrames.removeValue(forKey: item.path)
        }
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
            if vm.scope == .hidden {
                Button("Unhide") { vm.setHidden(hideTargets(), hidden: false) }
            } else {
                Button(hideTitle) { vm.setHidden(hideTargets(), hidden: true) }
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
        // ThumbnailCache already requests QLThumbnailGenerator at scale: 2.0
        // (retina), so passing `side * 2` here double-applies retina scaling
        // (4x the needed pixels). Request the logical side; QL supplies @2x.
        .task(id: side) { image = await vm.thumbnail(for: item, size: Int(side)) }
    }

    private var trashTitle: String {
        let n = vm.selectedPaths.contains(item.path) ? max(vm.selectedPaths.count, 1) : 1
        return n > 1 ? "Move \(n) Items to Trash" : "Move to Trash"
    }

    private var hideTitle: String {
        let n = vm.selectedPaths.contains(item.path) ? max(vm.selectedPaths.count, 1) : 1
        return n > 1 ? "Hide \(n) Items" : "Hide"
    }

    /// Right-click outside the current selection re-selects just the clicked
    /// item first (mirrors the trash context-menu action above).
    private func hideTargets() -> [MediaItem] {
        if !vm.selectedPaths.contains(item.path) {
            vm.select(item, commandKey: false, shiftKey: false)
        }
        let targets = vm.visibleItems.filter { vm.selectedPaths.contains($0.path) }
        return targets.isEmpty ? [item] : targets
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
            Picker("Density", selection: $vm.density) {
                ForEach(GridDensity.allCases) { d in
                    Image(systemName: d.symbol).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            Spacer()
            Picker("Time Mode", selection: $vm.timeMode) {
                Text("Years").tag(TimeMode.years)
                Text("Months").tag(TimeMode.months)
                Text("All").tag(TimeMode.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Spacer()
            ImportBar(importer: importer)
        }
        .padding(.vertical, 8)
    }

    private var emptyStateText: String {
        switch vm.scope {
        case .all: "Nothing to show"
        case .hidden: "No hidden items"
        default: "No \(vm.scope.rawValue.lowercased()) to show"
        }
    }

    @ViewBuilder private var content: some View {
        if vm.scope == .hidden && !vm.hiddenUnlocked {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Hidden items are locked")
                    .foregroundStyle(.secondary)
                Button("Authenticate") {
                    Task { await vm.unlockHidden() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.visibleItems.isEmpty {
            VStack(spacing: 12) {
                if vm.isIndexing && vm.items.isEmpty {
                    ProgressView()
                    Text("Indexing your library…")
                        .foregroundStyle(.secondary)
                } else if vm.items.isEmpty {
                    Text("No media found in ~/Pictures/PHLOOK")
                        .foregroundStyle(.secondary)
                } else {
                    Text(emptyStateText)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch vm.timeMode {
            case .all: allGrid
            case .months: monthsList
            case .years: yearsGrid
            }
        }
    }

    private var allGrid: some View {
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
                if vm.timeline.filter({ $0.monthStart != nil }).count >= 2 {
                    TimelineRail(buckets: vm.timeline) { path in
                        // Defer to the next runloop tick so the LazyVGrid has a
                        // chance to realize the target before scrolling to it.
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(path, anchor: .top)
                            }
                        }
                    }
                }
            }
            .onAppear { consumePendingScroll(proxy) }
            .onChange(of: vm.pendingScrollPath) { _, _ in consumePendingScroll(proxy) }
        }
    }

    private func consumePendingScroll(_ proxy: ScrollViewProxy) {
        guard let path = vm.pendingScrollPath else { return }
        vm.pendingScrollPath = nil
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(path, anchor: .top) }
        }
    }

    private var monthsList: some View {
        let columns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 12)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.timeline.filter { $0.monthStart != nil }, id: \.firstItemPath) { bucket in
                        TimeCard(
                            title: bucket.label, count: bucket.count,
                            items: vm.items(forMonthBucket: bucket), vm: vm, height: 220
                        ) {
                            vm.pendingScrollPath = bucket.firstItemPath
                            vm.timeMode = .all
                        }
                        .id(bucket.firstItemPath)
                    }
                }
                .padding(12)
            }
            .onAppear { consumePendingScroll(proxy) }
            .onChange(of: vm.pendingScrollPath) { _, _ in consumePendingScroll(proxy) }
        }
    }

    private var yearsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(vm.yearBuckets, id: \.year) { bucket in
                    TimeCard(
                        title: bucket.label, count: bucket.count,
                        items: vm.items(forYear: bucket.year), vm: vm, height: 220
                    ) {
                        vm.pendingScrollPath = bucket.firstItemPath
                        vm.timeMode = .months
                    }
                }
            }
            .padding(12)
        }
    }
}

/// A key-photo card used by Months and Years mode: pure navigation, no
/// selection/context-menu surface (spec: selection is All-mode only).
/// Auto-cycles through up to 10 of the period's photos with a gentle
/// crossfade, so a single cropped photo doesn't have to stand in for an
/// entire month/year. Cards stagger their cycle phase (hashed from the
/// card's identity) so they don't all flip in lockstep.
private struct TimeCard: View {
    let title: String
    let count: Int
    let items: [MediaItem]
    let vm: LibraryViewModel
    let height: CGFloat
    let action: () -> Void
    @State private var startDate = Date()
    @State private var imageCache: [String: NSImage] = [:]

    private var cardKey: String { items.first?.path ?? title }
    /// Stable per-card offset (0..<2.5s) into the shared 2.5s cycle.
    private var phase: Double {
        Double(abs(cardKey.hashValue) % 250) / 100
    }

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 2.5)) { context in
            let idx = items.isEmpty ? 0
                : Int((context.date.timeIntervalSince(startDate) + phase) / 2.5) % items.count
            ZStack(alignment: .bottomLeading) {
                if let current = items.indices.contains(idx) ? items[idx] : nil,
                   let image = imageCache[current.path] {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .id(current.path)
                        .transition(.opacity)
                } else {
                    Rectangle().fill(.quaternary)
                }
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: 60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                .padding(10)
            }
            .animation(.easeInOut(duration: 0.6), value: idx)
            .task(id: idx) {
                guard items.indices.contains(idx) else { return }
                let item = items[idx]
                guard imageCache[item.path] == nil else { return }
                if let loaded = await vm.thumbnail(for: item, size: 480) {
                    imageCache[item.path] = loaded
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { action() }
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
                guard self.vm.timeMode == .all else { return event }
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
                    if chars.lowercased() == "h" {
                        let targets = self.vm.visibleItems.filter { self.vm.selectedPaths.contains($0.path) }
                        guard !targets.isEmpty else { return event }
                        self.vm.setHidden(targets, hidden: self.vm.scope != .hidden)
                        return nil
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
