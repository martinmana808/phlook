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
