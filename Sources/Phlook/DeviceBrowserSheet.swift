import SwiftUI

/// Photos-style camera-roll browser: New items (selectable, pre-selected)
/// then Already Imported (dimmed, not selectable). "Import N selected" seeds
/// PhoneImportController.importSelected with exactly the chosen subset — the
/// one-click "Import N new" bar button stays as the fast path this augments.
struct DeviceBrowserSheet: View {
    @ObservedObject var importer: PhoneImportController
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: Set<String>

    init(importer: PhoneImportController) {
        self.importer = importer
        let newIDs = importer.deviceItems.filter(\.isNew).map(\.id)
        _selectedIDs = State(initialValue: Set(newIDs))
    }

    private var newItems: [PhoneImportController.DeviceItem] { importer.deviceItems.filter(\.isNew) }
    private var importedItems: [PhoneImportController.DeviceItem] { importer.deviceItems.filter { !$0.isNew } }

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    if !newItems.isEmpty {
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(newItems) { item in
                                    DeviceItemCell(importer: importer, item: item,
                                                  isSelected: selectedIDs.contains(item.id)) {
                                        toggle(item.id)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        } header: {
                            sectionHeader("New (\(newItems.count))")
                        }
                    }
                    if !importedItems.isEmpty {
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(importedItems) { item in
                                    DeviceItemCell(importer: importer, item: item,
                                                  isSelected: false, onToggle: {})
                                        .disabled(true)
                                }
                            }
                            .padding(.horizontal, 16)
                        } header: {
                            sectionHeader("Already imported (\(importedItems.count))")
                        }
                    }
                    if importer.deviceItems.isEmpty {
                        Text("No media found on device.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding()
                    }
                }
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption).bold()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("Browse device").font(.headline)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Select All") { selectedIDs = Set(newItems.map(\.id)) }
            Button("Select None") { selectedIDs = [] }
            Spacer()
            Button("Import \(selectedIDs.count) selected") {
                importer.importSelected(selectedIDs)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(16)
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
}

private struct DeviceItemCell: View {
    @ObservedObject var importer: PhoneImportController
    let item: PhoneImportController.DeviceItem
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .overlay {
                        if !item.isNew {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.35))
                        }
                    }
                if item.isNew {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .white)
                        .background(Circle().fill(isSelected ? .white : .black.opacity(0.4)))
                        .padding(4)
                } else {
                    Text("Imported")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(item.isNew ? 1 : 0.6)
        .task {
            image = await importer.thumbnail(for: item.id)
        }
    }
}
