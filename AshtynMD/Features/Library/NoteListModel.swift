import Foundation
import Observation

/// What the sidebar can select.
enum SidebarItem: Hashable {
    /// The capture folder. Selected at launch.
    case inbox
    /// Everything active: not archived, not trashed.
    case notes
    case untagged
    case todo
    case pinned
    case favorites
    case recents
    case archive
    case trash
    case search
    /// A tag, by case-folded key.
    case tag(String)
    case folder(URL)
}

/// The middle column: which list is showing, how it is sorted, and what is
/// selected in it.
@MainActor
@Observable
final class NoteListModel {
    /// Inbox at launch, so the app opens ready to capture.
    var selection: SidebarItem? = .inbox {
        didSet {
            guard selection != oldValue else { return }
            selectedPaths = []
            onSelectionChange?()
        }
    }

    var sortOrder: LibraryStore.SortOrder = .modifiedDescending {
        didSet {
            guard sortOrder != oldValue else { return }
            onSelectionChange?()
        }
    }

    private(set) var notes: [FileRecord] = []

    /// Real list selection, by relative path.
    ///
    /// Separate from "which tab is open": the old code derived the list
    /// selection from the active tab, which conflated the two and made
    /// multi-note actions impossible.
    var selectedPaths: Set<String> = []

    /// Fired when the selection or sort changes; the composition root refreshes.
    var onSelectionChange: (() -> Void)?
    private var refreshGeneration = 0

    var selectedRecords: [FileRecord] {
        notes.filter { selectedPaths.contains($0.relativePath) }
    }

    /// Title for the middle column.
    func title(inboxFolderName: String = InboxFolder.name) -> String {
        switch selection {
        case .inbox: return inboxFolderName
        case .notes, nil: return "Notes"
        case .untagged: return "Untagged"
        case .todo: return "To-Dos"
        case .pinned: return "Pinned"
        case .favorites: return "Favorites"
        case .recents: return "Recents"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .search: return "Search"
        case .tag(let key): return "#\(key)"
        case .folder(let url): return url.lastPathComponent
        }
    }

    /// Copy for the empty state, per selection.
    var emptyState: (title: String, symbol: String, message: String) {
        switch selection {
        case .inbox:
            return ("Inbox Is Empty", "tray", "Press ⌘N to capture a note.")
        case .untagged:
            return ("Everything's Tagged", "number", "Notes without a #tag show up here.")
        case .todo:
            return ("No Open To-Dos", "checklist", "Add `- [ ] something` to a note.")
        case .pinned:
            return ("Nothing Pinned", "pin", "Pin a note to keep it at the top.")
        case .favorites:
            return ("No Favorites", "star", "Add a note to Favorites to find it fast.")
        case .recents:
            return ("Nothing Recent", "clock", "Notes you open show up here.")
        case .archive:
            return ("Archive Is Empty", "archivebox", "Archived notes are kept out of the way.")
        case .trash:
            return ("Trash Is Empty", "trash", "Trashed notes can be restored from here.")
        case .tag(let key):
            return ("No Notes Tagged #\(key)", "number", "Type #\(key) in a note to add it.")
        case .folder(let url):
            return ("No Files", "doc", "“\(url.lastPathComponent)” has no notes yet.")
        default:
            return ("No Notes", "doc.text", "Press ⌘N to write one.")
        }
    }

    // MARK: - Loading

    /// Reloads `notes` for the current selection.
    func refresh(using session: LibrarySession) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let store = session.store else {
            notes = []
            return
        }
        let selection = self.selection ?? .notes
        let order = sortOrder
        let inboxPath = InboxFolder.name
        let folderPath = { () -> String? in
            if case .folder(let url) = selection { return session.relativePath(of: url) }
            return nil
        }()

        Task {
            let refreshed: [FileRecord]
            do {
                switch selection {
                case .inbox:
                    refreshed = try await store.files(inFolder: inboxPath, sortedBy: order)
                case .notes:
                    refreshed = try await store.notes(sortedBy: order)
                case .untagged:
                    refreshed = try await store.untaggedNotes(sortedBy: order)
                case .todo:
                    refreshed = try await store.todoNotes(sortedBy: order)
                case .pinned:
                    refreshed = try await store.pinnedNotes(sortedBy: order)
                case .favorites:
                    refreshed = try await store.favorites()
                case .recents:
                    refreshed = try await store.recents()
                case .archive:
                    refreshed = try await store.archivedNotes(sortedBy: order)
                case .trash:
                    refreshed = try await store.trashedNotes(sortedBy: order)
                case .tag(let key):
                    refreshed = try await store.notes(taggedWith: key, sortedBy: order)
                case .search:
                    refreshed = []
                case .folder:
                    refreshed = try await store.files(inFolder: folderPath ?? "", sortedBy: order)
                }
            } catch {
                refreshed = []
            }
            guard generation == self.refreshGeneration else { return }
            notes = refreshed
            // Drop selections for notes that are no longer listed.
            let paths = Set(notes.map(\.relativePath))
            selectedPaths.formIntersection(paths)
        }
    }
}
