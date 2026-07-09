import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    @StateObject private var importer: PhoneImportController

    init() {
        let vm = LibraryViewModel()
        _vm = StateObject(wrappedValue: vm)
        _importer = StateObject(wrappedValue: PhoneImportController(service: vm.service))
    }

    private var trashFailuresMessage: String {
        let failures = vm.trashFailures ?? []
        let shown = failures.prefix(10)
        var lines = shown.joined(separator: "\n")
        let remaining = failures.count - shown.count
        if remaining > 0 { lines += "\n…and \(remaining) more" }
        return lines
    }

    private var showResult: Bool {
        if case .finished = importer.state { return true }
        if case .error = importer.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView(vm: vm)
            } detail: {
                MicroGridView(vm: vm, importer: importer)
            }
            // Kept outside NavigationSplitView so the viewer covers the whole
            // window (including the sidebar column), not just the detail pane.
            if vm.viewerIndex != nil {
                ViewerView(vm: vm)
            }
        }
        // Shared coordinate space for the Photos-style expand/collapse
        // animation: ThumbCell stashes each cell's frame in this space
        // (vm.cellFrames); ViewerView reads it to grow/shrink its media
        // layer from/to the tapped cell. ViewerView itself drives its own
        // open/close timing (see closeAnimated/beginOpenAnimation), so no
        // mount-transition animation is applied here — that would double up.
        .coordinateSpace(name: "phlookWindow")
        .sheet(item: $vm.detailsItem) { item in
            DetailsModal(
                item: item,
                motionPath: vm.livePairs.videoPath(forImagePath: item.path)
            ) { vm.detailsItem = nil }
        }
        .sheet(item: $vm.posterPickerItem) { item in
            if let motionPath = vm.livePairs.videoPath(forImagePath: item.path) {
                PosterPickerSheet(vm: vm, item: item, motionPath: motionPath) {
                    vm.posterPickerItem = nil
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { showResult },
            set: { if !$0 { importer.dismissResult() } }
        )) {
            ImportResultSheet(state: importer.state) { importer.dismissResult() }
        }
        .sheet(isPresented: Binding(
            get: { vm.duplicateGroups != nil },
            set: { if !$0 { vm.duplicateGroups = nil } }
        )) {
            DuplicatesView(vm: vm, groups: vm.duplicateGroups ?? []) { vm.duplicateGroups = nil }
        }
        .sheet(isPresented: $importer.showDeviceBrowser) {
            DeviceBrowserSheet(importer: importer)
        }
        .confirmationDialog(
            "Move \(vm.pendingTrash?.count ?? 0) item(s) to Trash?",
            isPresented: Binding(get: { vm.pendingTrash != nil },
                                 set: { if !$0 { vm.pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { vm.confirmTrash() }
            Button("Cancel", role: .cancel) { vm.pendingTrash = nil }
        } message: {
            Text("You can restore them from the Trash.")
        }
        .alert("Some items could not be moved to Trash",
               isPresented: Binding(get: { vm.trashFailures != nil },
                                    set: { if !$0 { vm.trashFailures = nil } })) {
            Button("OK") { vm.trashFailures = nil }
        } message: {
            Text(trashFailuresMessage)
        }
        .onAppear {
            importer.onLibraryChanged = { vm.load() }
            vm.load()
            importer.start()
        }
    }
}
