import SwiftUI
import PhlookCore

/// The metadata rows shared by the viewer sidebar and the grid's details modal.
struct DetailsRows: View {
    let details: MediaDetails
    var motionPath: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Date taken", details.dateTaken)
            if let dims = details.dimensions { row("Dimensions", dims) }
            if let dur = details.duration { row("Duration", dur) }
            if let size = details.fileSize { row("Size", size) }
            row("Kind", motionPath != nil ? "Live Photo (\(liveKindSuffix))" : details.kind)
            if let motionPath {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Photo motion").font(.caption).foregroundStyle(.secondary)
                    Text((motionPath as NSString).lastPathComponent).font(.caption2)
                    Button("Show Motion File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: motionPath)])
                    }.controlSize(.small)
                }
            }
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

    /// "HEIC + MOV" — the still and motion files' uppercased extensions.
    private var liveKindSuffix: String {
        let stillExt = (details.path as NSString).pathExtension.uppercased()
        let motionExt = (motionPath.map { $0 as NSString }?.pathExtension ?? "").uppercased()
        return "\(stillExt) + \(motionExt)"
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
    var motionPath: String? = nil
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
            DetailsRows(details: details, motionPath: motionPath)
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
    var motionPath: String? = nil
    let onDone: () -> Void
    private var details: MediaDetails { .from(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(details.filename).font(.headline).lineLimit(2)
            DetailsRows(details: details, motionPath: motionPath)
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
