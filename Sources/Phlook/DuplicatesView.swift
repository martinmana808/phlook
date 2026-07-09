import SwiftUI
import PhlookCore

/// One duplicate group: keeper (first item, badged) + the rest as
/// pre-checked "trash this" candidates.
private struct DuplicateGroupRow: View {
    let group: [MediaItem]
    let keeperLabel: String
    @ObservedObject var vm: LibraryViewModel
    @Binding var selectedPaths: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(group.enumerated()), id: \.element.path) { index, item in
                        DuplicateThumb(item: item, vm: vm, isKeeper: index == 0, keeperLabel: keeperLabel,
                                       isSelected: selectedPaths.contains(item.path)) {
                            if selectedPaths.contains(item.path) {
                                selectedPaths.remove(item.path)
                            } else {
                                selectedPaths.insert(item.path)
                            }
                        }
                    }
                }
            }
            Divider()
        }
    }
}

private struct DuplicateThumb: View {
    let item: MediaItem
    @ObservedObject var vm: LibraryViewModel
    let isKeeper: Bool
    let keeperLabel: String
    let isSelected: Bool
    let toggle: () -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 120, height: 120)
                .clipped()
                .overlay {
                    if isSelected {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                if !isKeeper {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isKeeper { toggle() } }
            if isKeeper {
                Text(keeperLabel).font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: Capsule())
            } else {
                Text((item.path as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 120)
            }
        }
        .task { image = await vm.thumbnail(for: item, size: 120) }
    }
}

struct DuplicatesView: View {
    @ObservedObject var vm: LibraryViewModel
    let groups: [[MediaItem]]           // exact-content ("Identical files") groups
    let editedGroups: [[MediaItem]]     // original+edited (IMG_/IMG_E) groups
    let onDone: () -> Void

    @State private var selectedPaths: Set<String> = []

    private var isEmpty: Bool { groups.isEmpty && editedGroups.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Duplicates").font(.title2.bold())
                Spacer()
                Button("Done") { onDone() }
            }
            .padding()
            Divider()
            if isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No duplicates found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !groups.isEmpty {
                            Text("Identical files").font(.headline)
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                                DuplicateGroupRow(group: group, keeperLabel: "Keep",
                                                   vm: vm, selectedPaths: $selectedPaths)
                            }
                        }
                        if !editedGroups.isEmpty {
                            Text("Edited versions (original + edited)").font(.headline)
                            ForEach(Array(editedGroups.enumerated()), id: \.offset) { _, group in
                                DuplicateGroupRow(group: group, keeperLabel: "Keep · Edited",
                                                   vm: vm, selectedPaths: $selectedPaths)
                            }
                        }
                    }
                    .padding()
                }
                Divider()
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        let paths = Array(selectedPaths)
                        vm.trashPaths(paths)
                        selectedPaths.removeAll()
                        onDone()
                    } label: {
                        Text("Move \(selectedPaths.count) Selected to Trash")
                    }
                    .disabled(selectedPaths.isEmpty)
                }
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear {
            // Pre-check every non-keeper across both sections' groups.
            var initial: Set<String> = []
            for group in groups + editedGroups where group.count > 1 {
                for item in group.dropFirst() { initial.insert(item.path) }
            }
            selectedPaths = initial
        }
    }
}
