import SwiftUI
import PhlookCore

/// Left source-list: Library / Kinds / Hidden scopes with per-scope counts,
/// plus a From–To date-range control at the bottom.
///
/// Selecting the Hidden row while locked does NOT switch scope directly —
/// it delegates to `vm.unlockHidden()`, which authenticates and only flips
/// `vm.scope = .hidden` on success. On failure the selection reverts to
/// whatever scope was showing.
struct SidebarView: View {
    @ObservedObject var vm: LibraryViewModel

    private var selection: Binding<LibraryScope?> {
        Binding(
            get: { vm.scope },
            set: { newValue in
                guard let newValue else { return }
                guard newValue == .hidden else {
                    vm.scope = newValue
                    return
                }
                Task { await vm.unlockHidden() }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Library") {
                    row(.all, symbol: "photo.on.rectangle")
                    row(.photos, symbol: "photo")
                    row(.videos, symbol: "video")
                    row(.live, symbol: "livephoto")
                }
                Section("Kinds") {
                    row(.screenshots, symbol: "camera.viewfinder")
                    row(.selfies, symbol: "person.crop.square")
                }
                Section {
                    row(.hidden, symbol: vm.hiddenUnlocked ? "lock.open" : "lock.fill")
                }
            }
            .listStyle(.sidebar)
            Divider()
            DateRangeControl(vm: vm)
                .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    @ViewBuilder
    private func row(_ scope: LibraryScope, symbol: String) -> some View {
        HStack {
            Label(scope.rawValue, systemImage: symbol)
            Spacer()
            if let text = countText(for: scope) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(scope)
    }

    /// Hidden's count is withheld until the scope is unlocked (Task 5 sets
    /// `hiddenUnlocked`; until then it stays false and the count stays blank).
    private func countText(for scope: LibraryScope) -> String? {
        if scope == .hidden && !vm.hiddenUnlocked { return nil }
        guard let count = vm.scopeCounts[scope] else { return nil }
        return "\(count)"
    }
}

/// From–To date-range sliders over the library's dated months. `vm.fullTimeline`
/// (unaffected by `vm.dateRange` itself — see its declaration) is newest-first;
/// this view reverses the dated buckets to oldest-first so the sliders read
/// left-to-right chronologically.
private struct DateRangeControl: View {
    @ObservedObject var vm: LibraryViewModel
    @State private var fromIndex: Double = 0
    @State private var toIndex: Double = 0

    private var months: [TimelineBucket] {
        vm.fullTimeline.filter { $0.monthStart != nil }.reversed()
    }

    private var lastIndex: Int { max(months.count - 1, 0) }
    private var clampedFrom: Int { min(max(Int(fromIndex), 0), lastIndex) }
    private var clampedTo: Int { min(max(Int(toIndex), 0), lastIndex) }

    var body: some View {
        Group {
            if months.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Date Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { reset() }
                            .font(.caption)
                            .disabled(!vm.dateRange.isActive)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From: \(months[clampedFrom].label)")
                            .font(.caption2)
                        Slider(value: $fromIndex, in: 0...Double(lastIndex), step: 1)
                            .onChange(of: fromIndex) { _, newValue in
                                if newValue > toIndex { toIndex = newValue }
                                applyRange()
                            }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To: \(months[clampedTo].label)")
                            .font(.caption2)
                        Slider(value: $toIndex, in: 0...Double(lastIndex), step: 1)
                            .onChange(of: toIndex) { _, newValue in
                                if newValue < fromIndex { fromIndex = newValue }
                                applyRange()
                            }
                    }
                    if vm.dateRange.isActive {
                        Text("\(vm.visibleItems.count, format: .number) items in range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear { syncToFullRangeIfInactive() }
                .onChange(of: months.count) { _, _ in syncToFullRangeIfInactive() }
            }
        }
    }

    /// Follows the growing library (more months load in during background
    /// indexing) as long as the user hasn't dragged an active range yet;
    /// once `vm.dateRange.isActive`, leave the user's selection alone.
    private func syncToFullRangeIfInactive() {
        guard !months.isEmpty, !vm.dateRange.isActive else { return }
        fromIndex = 0
        toIndex = Double(lastIndex)
    }

    private func reset() {
        fromIndex = 0
        toIndex = Double(lastIndex)
        vm.dateRange = DateRangeFilter()
    }

    private func applyRange() {
        guard !months.isEmpty else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let lower = months[clampedFrom].monthStart
        let toStart = months[clampedTo].monthStart
        let upper = toStart.flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }
        vm.dateRange = DateRangeFilter(lower: lower, upper: upper)
    }
}
