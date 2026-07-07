import SwiftUI
import PhlookCore

/// Right-edge scrubber: one tick per month (longer at year starts). Hover
/// shows the month; click/drag jumps the grid. Fades when idle.
struct TimelineRail: View {
    let buckets: [TimelineBucket]
    let onJump: (String) -> Void
    @State private var hovering = false
    @State private var hoverLabel: String?
    @State private var lastJumpedPath: String?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .trailing) {
                // Ticks, evenly distributed over the rail height.
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    Rectangle()
                        .fill(.secondary.opacity(hovering ? 0.9 : 0.4))
                        .frame(width: bucket.isYearStart ? 16 : 8, height: 1.5)
                        .position(x: geo.size.width - (bucket.isYearStart ? 10 : 6),
                                  y: yFor(index: index, height: height))
                }
                if hovering, let label = hoverLabel {
                    Text(label)
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: -28)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .onHover { hovering = $0; if !$0 { hoverLabel = nil } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let (bucket, _) = bucket(atY: value.location.y, height: height) else { return }
                        hoverLabel = bucket.label
                        if bucket.firstItemPath != lastJumpedPath {
                            lastJumpedPath = bucket.firstItemPath
                            onJump(bucket.firstItemPath)
                        }
                    }
                    .onEnded { _ in lastJumpedPath = nil }
            )
        }
        .frame(width: 36)
    }

    private func yFor(index: Int, height: CGFloat) -> CGFloat {
        guard buckets.count > 1 else { return height / 2 }
        let usable = height - 24
        return 12 + usable * CGFloat(index) / CGFloat(buckets.count - 1)
    }

    private func bucket(atY y: CGFloat, height: CGFloat) -> (TimelineBucket, Int)? {
        guard !buckets.isEmpty else { return nil }
        let usable = max(height - 24, 1)
        let fraction = min(max((y - 12) / usable, 0), 1)
        let index = min(Int(round(fraction * CGFloat(buckets.count - 1))), buckets.count - 1)
        return (buckets[index], index)
    }
}
