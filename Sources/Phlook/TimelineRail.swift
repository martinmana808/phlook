import SwiftUI
import PhlookCore

/// Right-edge scrubber: spans oldest → newest media, time-linearly, with a
/// full-height track giving the rail a visual spine, year labels for
/// orientation, and density bars (perceptually scaled so sparse months stay
/// visible) anchored to the track. Hover shows the month under the cursor;
/// the grid only jumps once, on release, so dragging never fights the scroll
/// view.
struct TimelineRail: View {
    let buckets: [TimelineBucket]
    let onJump: (String) -> Void
    @State private var hovering = false
    @State private var hoverLabel: String?
    @State private var currentY: CGFloat?

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var datedBuckets: [TimelineBucket] {
        buckets.filter { $0.monthStart != nil }
    }

    /// Track sits close to the trailing edge; bars extend leftward from it,
    /// labels sit further left, both within the rail's own frame.
    private func trackX(width: CGFloat) -> CGFloat { width - 10 }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = geo.size.width
            let tx = trackX(width: width)
            ZStack(alignment: .trailing) {
                // Full-height track: the rail always reads as a complete timeline.
                Rectangle()
                    .fill(.secondary.opacity(hovering ? 0.5 : 0.25))
                    .frame(width: 1, height: height)
                    .position(x: tx, y: height / 2)

                ForEach(Array(datedBuckets.enumerated()), id: \.offset) { _, bucket in
                    let barWidth = 8 + 24 * sqrt(bucket.densityFraction)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary.opacity(bucket.isYearStart ? 0.85 : (hovering ? 0.85 : 0.35)))
                        .frame(width: barWidth, height: 2)
                        .position(x: tx - barWidth / 2, y: yFor(bucket: bucket, height: height))
                }

                ForEach(visibleYearLabels(height: height), id: \.bucket.id) { entry in
                    Text(Self.yearFormatter.string(from: entry.bucket.monthStart!))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1.0 : 0.55)
                        .position(x: tx - 18, y: entry.y)
                }

                if hovering, let y = currentY {
                    Rectangle()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 44, height: 1)
                        .position(x: tx - 22, y: y)
                }
                if hovering, let label = hoverLabel {
                    Text(label)
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: -40)
                        .position(x: width, y: currentY ?? height / 2)
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
        .frame(width: 56)
    }

    private func yFor(bucket: TimelineBucket, height: CGFloat) -> CGFloat {
        let topInset: CGFloat = 12
        let usable = height - 24
        return topInset + usable * CGFloat(bucket.yFraction)
    }

    /// Year-start buckets to actually label: skips any that would land within
    /// 12pt of the previously rendered label, so dense decades don't collide.
    private func visibleYearLabels(height: CGFloat) -> [(bucket: TimelineBucket, y: CGFloat)] {
        var result: [(bucket: TimelineBucket, y: CGFloat)] = []
        var lastY: CGFloat?
        for bucket in datedBuckets where bucket.isYearStart {
            let y = yFor(bucket: bucket, height: height)
            if let lastY, abs(y - lastY) < 12 { continue }
            result.append((bucket, y))
            lastY = y
        }
        return result
    }

    /// Nearest bucket by |y - bucketY|, not index math — bars aren't evenly spaced in time.
    private func nearestBucket(toY y: CGFloat, height: CGFloat) -> TimelineBucket? {
        let dated = datedBuckets
        guard !dated.isEmpty else { return nil }
        return dated.min(by: { abs(yFor(bucket: $0, height: height) - y) < abs(yFor(bucket: $1, height: height) - y) })
    }
}

private extension TimelineBucket {
    /// Stable per-bucket identity for ForEach (label + firstItemPath is
    /// unique across a library's buckets).
    var id: String { "\(label)#\(firstItemPath)" }
}
