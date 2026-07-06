import SwiftUI
import PhlookCore

struct ImportBar: View {
    @ObservedObject var importer: PhoneImportController

    var body: some View {
        switch importer.state {
        case .idle:
            EmptyView()
        case .connecting(let device):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(device) — unlock it and tap Trust…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let device, let pending):
            if pending > 0 {
                Button {
                    importer.importAllNew()
                } label: {
                    Label("Import \(pending) new from \(device)", systemImage: "iphone.and.arrow.forward")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Label("\(device): up to date", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .importing(_, let done, let total):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text("Importing \(done) of \(total)…").font(.caption)
            }
        case .finished, .error:
            EmptyView()   // presented as a sheet by ContentView
        }
    }
}

struct ImportResultSheet: View {
    let state: PhoneImportController.ImportState
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .finished(let report, let failed):
                Text("Import complete").font(.headline)
                Text(report.summaryText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if !failed.isEmpty {
                    Text("Failed downloads (still on the phone):").font(.caption).foregroundStyle(.secondary)
                    ForEach(failed, id: \.self) { Text($0).font(.caption2) }
                }
            case .error(let message):
                Text("Import problem").font(.headline)
                Text(message)
            default:
                EmptyView()
            }
            HStack { Spacer(); Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
