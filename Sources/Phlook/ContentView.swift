import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    var body: some View {
        ZStack {
            MicroGridView(vm: vm)
            if vm.viewerIndex != nil {
                ViewerView(vm: vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.viewerIndex != nil)
        .sheet(item: $vm.detailsItem) { item in
            DetailsModal(item: item) { vm.detailsItem = nil }
        }
        .onAppear { vm.load() }
    }
}
