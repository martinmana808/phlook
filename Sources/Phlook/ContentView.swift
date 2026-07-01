import SwiftUI

struct ContentView: View {
    @StateObject private var vm = LibraryViewModel()
    var body: some View {
        MicroGridView(vm: vm)
            .onAppear { vm.load() }
    }
}
