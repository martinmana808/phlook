import SwiftUI
import PhlookCore

/// Right-edge scrubber: a slim hover zone spanning oldest → newest media,
/// time-linearly. Invisible when idle — no bars, no spine, no year labels.
/// On hover/drag it shows a floating "MMM yyyy" capsule at cursor height plus
/// a thin indicator line; the grid only jumps once, on gesture end, so
/// dragging never fights the scroll view.
struct TimelineRail: View {
    let buckets: [TimelineBucket]
    let onJump: (String) -> Void
    @State private var hovering = false
    @State private var hoverLabel: String?
    @State private var currentY: CGFloat?

    private var datedBuckets: [TimelineBucket] {
        buckets.filter { $0.monthStart != nil }
    }

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Year-start buckets thinned so labels never overlap (≥ 22pt apart).
    private func yearLabels(height: CGFloat) -> [(y: CGFloat, text: String)] {
        var result: [(CGFloat, String)] = []
        var lastY: CGFloat = -.greatestFiniteMagnitude
        for bucket in datedBuckets where bucket.isYearStart {
            guard let date = bucket.monthStart else { continue }
            let y = yFor(bucket: bucket, height: height)
            guard y - lastY >= 22 else { continue }
            lastY = y
            result.append((y, Self.yearFormatter.string(from: date)))
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = geo.size.width
            ZStack(alignment: .trailing) {
                // Always-present, near-invisible hit layer: without a real (non-empty)
                // subview here the ZStack collapses to zero size when neither overlay
                // below is showing, so .onContinuousHover / the drag gesture never fire
                // and the capsule can never appear on the very first hover.
                Rectangle()
                    .fill(.white.opacity(0.001))
                    .frame(width: width, height: height)

                // Year labels along the rail — no spine, just the years so the
                // strip reads as a timeline. Faint when idle, clear on hover.
                ForEach(yearLabels(height: height), id: \.y) { label in
                    Text(label.text)
                        .font(.system(size: 9, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary.opacity(hovering ? 0.9 : 0.45))
                        .position(x: width - 18, y: label.y)
                }
                // A short tick at each year label, right-aligned, as a subtle anchor.
                ForEach(yearLabels(height: height), id: \.y) { label in
                    Rectangle()
                        .fill(.secondary.opacity(hovering ? 0.7 : 0.3))
                        .frame(width: 6, height: 1)
                        .position(x: width - 4, y: label.y)
                }

                if hovering, let y = currentY {
                    Rectangle()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 44, height: 1)
                        .position(x: width - 22, y: y)
                }
                if hovering, let label = hoverLabel {
                    Text(label)
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: -48)
                        .position(x: width, y: currentY ?? height / 2)
                }
            }
            .contentShape(Rectangle())
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
                        hovering = true
                        currentY = value.location.y
                        hoverLabel = bucket.label
                    }
                    .onEnded { value in
                        guard let bucket = nearestBucket(toY: value.location.y, height: height) else { return }
                        onJump(bucket.firstItemPath)
                    }
            )
        }
        .frame(width: 46)
    }

    private func yFor(bucket: TimelineBucket, height: CGFloat) -> CGFloat {
        let topInset: CGFloat = 12
        let usable = height - 24
        return topInset + usable * CGFloat(bucket.yFraction)
    }

    /// Nearest bucket by |y - bucketY|, not index math — buckets aren't evenly spaced in time.
    private func nearestBucket(toY y: CGFloat, height: CGFloat) -> TimelineBucket? {
        let dated = datedBuckets
        guard !dated.isEmpty else { return nil }
        return dated.min(by: { abs(yFor(bucket: $0, height: height) - y) < abs(yFor(bucket: $1, height: height) - y) })
    }
}
