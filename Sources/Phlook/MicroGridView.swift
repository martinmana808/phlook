import SwiftUI
import PhlookCore

struct ThumbCell: View {
    let item: MediaItem
    let vm: LibraryViewModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 80, height: 80)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if item.fileType == "video",
               let text = DurationFormatter.string(seconds: item.duration) {
                Text(text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if item.fileType == "video" {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { vm.openViewer(item) })
        .contextMenu {
            Button("Open") { vm.openViewer(item) }
            Button("View Details") { vm.detailsItem = item }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
        .task { image = await vm.thumbnail(for: item) }
    }
}

struct MicroGridView: View {
    @ObservedObject var vm: LibraryViewModel
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 80), spacing: 2)]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            content
        }
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
        Picker("Filter", selection: $vm.filter) {
            ForEach(MediaFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(vm.visibleItems, id: \.path) { item in
                        ThumbCell(item: item, vm: vm)
                    }
                }
                .padding(2)
            }
        }
    }
}
