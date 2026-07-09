import Testing
import Foundation
@testable import PhlookCore

struct DuplicateSelectionTests {
    private func makeItem(path: String) -> MediaItem {
        MediaItem(path: path, hash: "h1", dateTaken: nil, fileType: "image",
                  width: nil, height: nil, lastScanned: Date(), fileSize: 100)
    }

    @Test func selectionIncludingKeeperExcludesIt() {
        let keeper = makeItem(path: "/lib/keeper.jpg")
        let other = makeItem(path: "/lib/other.jpg")
        let group = [keeper, other]
        let selected: Set<String> = [keeper.path, other.path]
        let result = DuplicateSelection.trashable(selected: selected, groups: [group])
        #expect(result == [other.path])
    }

    @Test func normalSelectionUnchanged() {
        let keeper = makeItem(path: "/lib/keeper.jpg")
        let other1 = makeItem(path: "/lib/other1.jpg")
        let other2 = makeItem(path: "/lib/other2.jpg")
        let group = [keeper, other1, other2]
        let selected: Set<String> = [other1.path, other2.path]
        let result = Set(DuplicateSelection.trashable(selected: selected, groups: [group]))
        #expect(result == selected)
    }

    @Test func emptySelectionYieldsEmpty() {
        let keeper = makeItem(path: "/lib/keeper.jpg")
        let group = [keeper]
        let result = DuplicateSelection.trashable(selected: [], groups: [group])
        #expect(result.isEmpty)
    }

    @Test func pathKeeperInOneGroupExcludedEvenIfSelectedViaAnotherGroup() {
        // Simulates a re-imported edited video that is a content-non-keeper
        // in one section (group A) and the edited-pair keeper in another
        // (group B). Even though group B doesn't select it, it must still
        // be excluded from trashing because it's a keeper somewhere.
        let sharedPath = "/lib/reimported.mov"
        let contentKeeper = makeItem(path: "/lib/content-keeper.mov")
        let shared = makeItem(path: sharedPath)
        let groupA = [contentKeeper, shared] // shared is non-keeper here (content duplicates)

        let editedOther = makeItem(path: "/lib/edited-other.mov")
        let groupB = [shared, editedOther] // shared is keeper here (edited pair)

        // selection includes the shared path (checked in group A) plus the
        // non-keeper of group B.
        let selected: Set<String> = [sharedPath, editedOther.path]
        let result = Set(DuplicateSelection.trashable(selected: selected, groups: [groupA, groupB]))
        #expect(!result.contains(sharedPath))
        #expect(result.contains(editedOther.path))
    }
}
