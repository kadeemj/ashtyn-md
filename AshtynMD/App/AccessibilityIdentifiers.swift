enum AccessibilityID {
    static let onboardingChooseFolder = "onboarding.choose-folder"
    static let sidebar = "library.sidebar"
    /// The note list. Before Phase 7 this identifier was also applied to the
    /// search results list, so tests could not tell the two apart.
    static let fileList = "library.file-list"
    static let noteList = "library.note-list"
    static let searchResults = "library.search-results"
    static let tagTree = "library.tag-tree"
    static let searchField = "library.search-field"
    static let tabBar = "document.tab-bar"
    static let editor = "document.editor"
    static let modePicker = "markdown.mode-picker"
    static let renderPreview = "markdown.render-preview"
    static let previewWebView = "markdown.preview"
    static let openLargeFileAnyway = "document.open-anyway"
    static let largeFileMode = "document.large-file-mode"
    static let conflictCompare = "conflict.compare"
    static let moveToFolderSheet = "library.move-to-folder"
    static let noteInfoInspector = "document.note-info-inspector"
    static let noteInfoStatistics = "document.note-info-statistics"
    static let noteInfoReadingTime = "document.note-info-reading-time"
    static let noteInfoTasks = "document.note-info-tasks"
    static let noteInfoTags = "document.note-info-tags"
    static let noteInfoBacklinks = "document.note-info-backlinks"
    static let noteInfoLinks = "document.note-info-links"
    static let wikiLinkAutocomplete = "document.wiki-link-autocomplete"
    static let wikiLinkSuggestionPrefix = "document.wiki-link-suggestion"

    static func wikiLinkSuggestion(_ index: Int) -> String {
        "\(wikiLinkSuggestionPrefix).\(index)"
    }
}
