import Testing
import Foundation
@testable import PhlookCore

struct PhoneImportPlannerTests {
    let date = ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z")!

    func item(_ name: String, size: Int = 100) -> CameraItemDescriptor {
        CameraItemDescriptor(name: name, creationDate: date, fileSize: size)
    }

    @Test func identifierIsDeterministicComposite() {
        let a = item("IMG_1.HEIC", size: 123)
        #expect(a.identifier == "IMG_1.HEIC|2026-07-06T12:00:00Z|123")
        #expect(a.identifier == item("IMG_1.HEIC", size: 123).identifier)
    }

    @Test func nilDateUsesUnknownPlaceholder() {
        let a = CameraItemDescriptor(name: "X.MOV", creationDate: nil, fileSize: 5)
        #expect(a.identifier == "X.MOV|unknown|5")
    }

    @Test func pendingExcludesRecordedAndNonMedia() {
        let items = [item("IMG_1.HEIC"), item("IMG_2.MOV"), item("IMG_3.AAE"), item("IMG_4.JPG")]
        let recorded: Set<String> = [item("IMG_1.HEIC").identifier]
        let pending = PhoneImportPlanner.pending(onDevice: items, alreadyImported: recorded)
        #expect(pending.map(\.name) == ["IMG_2.MOV", "IMG_4.JPG"])   // 1 recorded, AAE non-media
    }

    @Test func allRecordedMeansNothingPending() {
        let items = [item("A.JPG"), item("B.JPG")]
        let recorded = Set(items.map(\.identifier))
        #expect(PhoneImportPlanner.pending(onDevice: items, alreadyImported: recorded).isEmpty)
    }

    @Test func subsetFiltersToSelectedIdentifiers() {
        let items = [item("A.JPG"), item("B.JPG"), item("C.JPG")]
        let selected: Set<String> = [item("A.JPG").identifier, item("C.JPG").identifier]
        let subset = PhoneImportPlanner.subset(pending: items, selectedIDs: selected)
        #expect(subset.map(\.name) == ["A.JPG", "C.JPG"])
    }

    @Test func subsetWithEmptySelectionIsEmpty() {
        let items = [item("A.JPG"), item("B.JPG")]
        #expect(PhoneImportPlanner.subset(pending: items, selectedIDs: []).isEmpty)
    }

    @Test func subsetIgnoresUnknownIdentifiers() {
        let items = [item("A.JPG")]
        let subset = PhoneImportPlanner.subset(pending: items, selectedIDs: ["nonexistent|unknown|0"])
        #expect(subset.isEmpty)
    }
}
