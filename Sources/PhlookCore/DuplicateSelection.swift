import Foundation

/// Pure selection→trash logic for the Duplicates view.
///
/// Multiple duplicate-group sections (e.g. "identical content" and "edited
/// pairs") can share one selection set. A path that is the protected keeper
/// (first item) in one group may appear as a selectable non-keeper in a
/// *different* group. This helper guarantees that no keeper — from any group
/// — is ever trashed, regardless of how the selection was built.
public enum DuplicateSelection {
    /// Paths safe to trash: the selection minus every group's keeper
    /// (first item) across all provided groups. Guarantees no keeper is ever
    /// trashed, even if it was selected via a different group's row.
    public static func trashable(selected: Set<String>, groups: [[MediaItem]]) -> [String] {
        let keepers = Set(groups.compactMap { $0.first?.path })
        return Array(selected.subtracting(keepers))
    }
}
