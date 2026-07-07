import SwiftUI
import PhlookCore

/// Right-edge scrubber: spans oldest → newest media, time-linearly, with bar
/// width encoding density (volume of media at that point in time). Hover
/// shows the month under the cursor; the grid only jumps once, on release,
/// so dragging never fights the scroll view.
struct TimelineRail: View {
    let buckets: [TimelineBucket]
    let onJump: (String) -> Void
    @State private var hovering = false
    @State private var hoverLabel: String?
    @State private var currentY: CGFloat?

    private var datedBuckets: [TimelineBucket] {
        buckets.filter { $0.monthStart != nil }
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .trailing) {
                ForEach(Array(datedBuckets.enumerated()), id: \.offset) { _, bucket in
                    let minWidth: Double = bucket.isYearStart ? 10 : 6
                    let width = minWidth + 22 * bucket.densityFraction
                    Rectangle()
                        .fill(.secondary.opacity(bucket.isYearStart ? 0.85 : (hovering ? 0.85 : 0.35)))
                        .frame(width: width, height: 2)
                        .position(x: geo.size.width - width / 2,
                                  y: yFor(bucket: bucket, height: height))
                }
                if hovering, let y = currentY {
                    Rectangle()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 44, height: 1)
                        .position(x: geo.size.width - 22, y: y)
                }
                if hovering, let label = hoverLabel {
                    Text(label)
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: -40)
                        .position(x: geo.size.width, y: currentY ?? height / 2)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = true
                    currentY = location.y
                    hoverLabel = nearestBucket(toY: location.y, height: height)?.label
                case .ended:
                    hovering = false
                    hoverLabel = nil
                    currentY = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let bucket = nearestBucket(toY: value.location.y, height: height) else { return }
                        currentY = value.location.y
                        hoverLabel = bucket.label
                    }
                    .onEnded { value in
                        guard let bucket = nearestBucket(toY: value.location.y, height: height) else { return }
                        onJump(bucket.firstItemPath)
                    }
            )
        }
        .frame(width: 44)
    }

    private func yFor(bucket: TimelineBucket, height: CGFloat) -> CGFloat {
        let topInset: CGFloat = 12
        let usable = height - 24
        return topInset + usable * CGFloat(bucket.yFraction)
    }

    /// Nearest bucket by |y - bucketY|, not index math — bars aren't evenly spaced in time.
    private func nearestBucket(toY y: CGFloat, height: CGFloat) -> TimelineBucket? {
        let dated = datedBuckets
        guard !dated.isEmpty else { return nil }
        return dated.min(by: { abs(yFor(bucket: $0, height: height) - y) < abs(yFor(bucket: $1, height: height) - y) })
    }
}
