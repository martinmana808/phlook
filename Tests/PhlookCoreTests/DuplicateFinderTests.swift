import Testing
import Foundation
@testable import PhlookCore

struct DuplicateFinderTests {
    private func makeItem(path: String, hash: String?, size: Int?, scanned: Date = Date()) -> MediaItem {
        MediaItem(path: path, hash: hash, dateTaken: nil, fileType: "image",
                  width: nil, height: nil, lastScanned: scanned, fileSize: size)
    }

    @Test func twoByteIdenticalItemsFormOneGroup() {
        let a = makeItem(path: "/lib/a.jpg", hash: "h1", size: 100)
        let b = makeItem(path: "/lib/b.jpg", hash: "h1", size: 100)
        let groups = DuplicateFinder.groups(items: [a, b]) { _ in "full1" }
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }

    @Test func quickHashCollisionSplitsAndExcludesSingletons() {
        let a = makeItem(path: "/lib/a.jpg", hash: "h1", size: 100)
        let b = makeItem(path: "/lib/b.jpg", hash: "h1", size: 100)
        let groups = DuplicateFinder.groups(items: [a, b]) { path in
            path.contains("a") ? "fullA" : "fullB"
        }
        #expect(groups.isEmpty)
    }

    @Test func threeIdenticalFormGroupOfThreeKeeperFirst() {
        let convention = makeItem(path: "/lib/2026-01-01_10-00-00_x.jpg", hash: "h1", size: 100,
                                   scanned: Date())
        let other1 = makeItem(path: "/lib/IMG_0001.jpg", hash: "h1", size: 100,
                               scanned: Date())
        let other2 = makeItem(path: "/lib/IMG_0002.jpg", hash: "h1", size: 100,
                               scanned: Date())
        let groups = DuplicateFinder.groups(items: [other1, other2, convention]) { _ in "full1" }
        #expect(groups.count == 1)
        #expect(groups[0].count == 3)
        #expect(groups[0][0].path == convention.path)
    }

    @Test func singletonsExcluded() {
        let a = makeItem(path: "/lib/a.jpg", hash: "h1", size: 100)
        let groups = DuplicateFinder.groups(items: [a]) { _ in "full1" }
        #expect(groups.isEmpty)
    }

    @Test func nilHashOrSizeExcluded() {
        let a = makeItem(path: "/lib/a.jpg", hash: nil, size: 100)
        let b = makeItem(path: "/lib/b.jpg", hash: "h1", size: nil)
        let c = makeItem(path: "/lib/c.jpg", hash: "", size: 100)
        let groups = DuplicateFinder.groups(items: [a, b, c]) { _ in "full1" }
        #expect(groups.isEmpty)
    }

    @Test func keeperOrderingPrefersConventionNameThenEarliestScanThenShortestPath() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        let nonConventionEarly = makeItem(path: "/lib/zzzzzzzzzzzzzzz.jpg", hash: "h1", size: 100, scanned: earlier)
        let nonConventionLate = makeItem(path: "/lib/aaa.jpg", hash: "h1", size: 100, scanned: later)
        let conventionNamed = makeItem(path: "/lib/2026-01-01_10-00-00_a.jpg", hash: "h1", size: 100, scanned: later)
        let groups = DuplicateFinder.groups(items: [nonConventionEarly, nonConventionLate, conventionNamed]) { _ in "full1" }
        #expect(groups.count == 1)
        #expect(groups[0][0].path == conventionNamed.path)
        // among the two non-convention items, earliest lastScanned wins second place
        #expect(groups[0][1].path == nonConventionEarly.path)
    }

    @Test func emptyInputYieldsNoGroups() {
        let groups = DuplicateFinder.groups(items: []) { _ in "full1" }
        #expect(groups.isEmpty)
    }
}
