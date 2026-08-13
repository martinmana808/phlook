import SwiftUI
import PhlookCore
import UniformTypeIdentifiers

/// "Reclaim space" panel: shows archive/shrink status against the PHLOOK_SSD
/// archive drive, lets the user point at a drive to adopt as the archive
/// target, and runs the archive/shrink/reclaim pipeline. Presented as a
/// `.sheet` from ContentView (same style as `DuplicatesView`).
struct ReclaimSpaceView: View {
    @ObservedObject var vm: LibraryViewModel
    @State private var showingSetupPicker = false

    private func formatted(_ n: Int) -> String {
        n.formatted(.number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reclaim space").font(.title2).bold()

            if let s = vm.reclaimStatus {
                Text(s.buttonSubtitle).foregroundStyle(.secondary)
                Text("\(s.counts.hasSmall) have 10% versions").font(.caption).foregroundStyle(.secondary)

                if vm.archiveRunning {
                    if let p = vm.archiveProgress {
                        ProgressView(value: Double(p.done), total: Double(p.total))
                        Text("Archiving \(formatted(p.done)) of \(formatted(p.total))…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Archiving…")
                    }
                    Button("Cancel") { vm.requestCancelArchive() }
                } else {
                    Button {
                        vm.startArchive()
                    } label: {
                        Label("Archive & shrink", systemImage: "externaldrive.badge.timemachine")
                    }
                    .disabled(!s.canArchive)

                    if !s.ssdConnected {
                        Button("Set up archive drive…") { showingSetupPicker = true }
                            .buttonStyle(.link)
                    }
                }

                if let r = vm.lastArchiveReport {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Archived \(r.archived) · shrunk \(r.shrunk) · reclaimed \(r.reclaimed)")
                        if !r.skippedCollisions.isEmpty {
                            Text("Skipped (name collision): \(r.skippedCollisions.joined(separator: ", "))")
                                .foregroundStyle(.orange)
                        }
                        if !r.failures.isEmpty {
                            Text("\(r.failures.count) failures — originals kept").foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                }
            } else {
                ProgressView().onAppear { vm.refreshReclaimStatus() }
            }
        }
        .padding()
        .frame(minWidth: 340)
        .fileImporter(isPresented: $showingSetupPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { vm.setUpArchiveDrive(volumeRoot: url) }
        }
        .onAppear { vm.refreshReclaimStatus() }
    }
}
