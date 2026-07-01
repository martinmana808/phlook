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
        .task { image = await vm.thumbnail(for: item) }
    }
}

struct MicroGridView: View {
    @ObservedObject var vm: LibraryViewModel
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 80), spacing: 2)]

    var body: some View {
        Group {
            if vm.items.isEmpty {
                VStack(spacing: 12) {
                    if vm.isIndexing {
                        ProgressView()
                        Text("Indexing your library…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No media found in ~/Pictures/PHLOOK")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(vm.items, id: \.path) { item in
                            ThumbCell(item: item, vm: vm)
                        }
                    }
                    .padding(2)
                }
            }
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
}
