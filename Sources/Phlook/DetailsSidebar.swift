import SwiftUI
import PhlookCore

/// The metadata rows shared by the viewer sidebar and the grid's details modal.
struct DetailsRows: View {
    let details: MediaDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Date taken", details.dateTaken)
            if let dims = details.dimensions { row("Dimensions", dims) }
            if let dur = details.duration { row("Duration", dur) }
            if let size = details.fileSize { row("Size", size) }
            row("Kind", details.kind)
            VStack(alignment: .leading, spacing: 4) {
                Text("Path").font(.caption).foregroundStyle(.secondary)
                Text(details.path)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .lineLimit(4)
                HStack {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: details.path)])
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}

/// Trailing panel inside the viewer. Has its own close button — the top bar's
/// ⓘ sits underneath the panel once it is open, so it can't be the way out.
struct DetailsSidebar: View {
    let item: MediaItem
    let onClose: () -> Void
    private var details: MediaDetails { .from(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(details.filename).font(.headline).lineLimit(2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close details (⌘I)")
            }
            DetailsRows(details: details)
            Spacer()
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// Modal used by the grid's "View Details" — shows metadata without entering
/// the full-app-screen viewer.
struct DetailsModal: View {
    let item: MediaItem
    let onDone: () -> Void
    private var details: MediaDetails { .from(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(details.filename).font(.headline).lineLimit(2)
            DetailsRows(details: details)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
