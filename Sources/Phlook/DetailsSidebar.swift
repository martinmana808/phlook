import SwiftUI
import PhlookCore

struct DetailsSidebar: View {
    let item: MediaItem
    private var details: MediaDetails { .from(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(details.filename).font(.headline).lineLimit(2)
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
            Spacer()
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
