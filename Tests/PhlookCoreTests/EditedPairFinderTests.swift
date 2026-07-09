import Testing
import Foundation
@testable import PhlookCore

struct EditedPairFinderTests {
    private func makeItem(path: String) -> MediaItem {
        MediaItem(path: path, hash: nil, dateTaken: nil, fileType: "video",
                  width: nil, height: nil, lastScanned: Date())
    }

    @Test func sameTimestampAndExtFormsOnePairEditedFirst() {
        let original = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_8624.MOV")
        let edited = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E8624.MOV")
        let groups = EditedPairFinder.pairs(items: [original, edited])
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
        #expect(groups[0][0].path == edited.path)
        #expect(groups[0][1].path == original.path)
    }

    @Test func differentTimestampsNoPair() {
        let original = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_8624.MOV")
        let edited = makeItem(path: "/lib/2026-01-02_10-00-00_IMG_E8624.MOV")
        #expect(EditedPairFinder.pairs(items: [original, edited]).isEmpty)
    }

    @Test func differentDigitsNoPair() {
        let original = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_8624.MOV")
        let edited = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E8625.MOV")
        #expect(EditedPairFinder.pairs(items: [original, edited]).isEmpty)
    }

    @Test func differentExtensionNoPair() {
        let original = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_8624.MOV")
        let edited = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E8624.HEIC")
        #expect(EditedPairFinder.pairs(items: [original, edited]).isEmpty)
    }

    @Test func editedOnlyWithNoOriginalYieldsNoGroup() {
        let edited = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E8624.MOV")
        #expect(EditedPairFinder.pairs(items: [edited]).isEmpty)
    }

    @Test func originalOnlyWithNoEditedYieldsNoGroup() {
        let original = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_8624.MOV")
        #expect(EditedPairFinder.pairs(items: [original]).isEmpty)
    }

    @Test func heicPhotosPairToo() {
        let original = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_1234.HEIC")
        let edited = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E1234.HEIC")
        let groups = EditedPairFinder.pairs(items: [original, edited])
        #expect(groups.count == 1)
        #expect(groups[0][0].path == edited.path)
    }

    @Test func liveMotionUnderscore3NameIsIgnored() {
        // UUID-cored live-motion resource name, not an IMG_ basename — must
        // not be mistaken for an original/edited pair partner.
        let motion = makeItem(
            path: "/lib/2026-01-01_10-00-00_3EFFF3E9-8CBA-4A2B-9D6E-123456789ABC_3.mov")
        let edited = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E8624.MOV")
        #expect(EditedPairFinder.pairs(items: [motion, edited]).isEmpty)
    }

    @Test func conventionTimestampedRealNamesFromSpec() {
        let original = makeItem(path: "/library/2026-07-08_09-15-42_IMG_8624.MOV")
        let edited = makeItem(path: "/library/2026-07-08_09-15-42_IMG_E8624.MOV")
        let groups = EditedPairFinder.pairs(items: [original, edited])
        #expect(groups.count == 1)
        #expect(groups[0].map(\.path) == [edited.path, original.path])
    }

    @Test func multipleGroupsAreIndependentAndBothOrderedEditedFirst() {
        let original1 = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_1111.MOV")
        let edited1 = makeItem(path: "/lib/2026-01-01_10-00-00_IMG_E1111.MOV")
        let original2 = makeItem(path: "/lib/2026-02-02_11-00-00_IMG_2222.HEIC")
        let edited2 = makeItem(path: "/lib/2026-02-02_11-00-00_IMG_E2222.HEIC")
        let groups = EditedPairFinder.pairs(items: [original1, edited1, original2, edited2])
        #expect(groups.count == 2)
        for group in groups {
            #expect(group[0].path.contains("IMG_E"))
        }
    }

    @Test func emptyInputYieldsNoGroups() {
        #expect(EditedPairFinder.pairs(items: []).isEmpty)
    }
}
