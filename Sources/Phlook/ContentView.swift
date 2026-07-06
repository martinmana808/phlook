import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    @StateObject private var importer: PhoneImportController

    init() {
        let vm = LibraryViewModel()
        _vm = StateObject(wrappedValue: vm)
        _importer = StateObject(wrappedValue: PhoneImportController(service: vm.service))
    }

    private var showResult: Bool {
        if case .finished = importer.state { return true }
        if case .error = importer.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            MicroGridView(vm: vm, importer: importer)
            if vm.viewerIndex != nil {
                ViewerView(vm: vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.viewerIndex != nil)
        .sheet(item: $vm.detailsItem) { item in
            DetailsModal(item: item) { vm.detailsItem = nil }
        }
        .sheet(isPresented: Binding(
            get: { showResult },
            set: { if !$0 { importer.dismissResult() } }
        )) {
            ImportResultSheet(state: importer.state) { importer.dismissResult() }
        }
        .onAppear {
            importer.onLibraryChanged = { vm.load() }
            vm.load()
            importer.start()
        }
    }
}
