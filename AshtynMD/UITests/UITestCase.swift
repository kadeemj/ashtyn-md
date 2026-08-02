import XCTest

@MainActor
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func launch(
        reset: Bool = true,
        onboarding: Bool = false,
        standalone: Bool = false
    ) {
        app = XCUIApplication()
        // A previous macOS run can persist a closed main WindowGroup. UI
        // tests always need a fresh library window, independent of that user
        // state.
        app.launchArguments = [
            "-ui-testing",
            "-AppleKeyboardUIMode", "3",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        if reset { app.launchArguments.append("-ui-test-reset") }
        if onboarding { app.launchArguments.append("-ui-test-show-onboarding") }
        if standalone { app.launchArguments.append("-ui-test-standalone") }
        app.launch()
        app.activate()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Finds a note row by the text the user sees.
    ///
    /// Since Phase 7 that is the note's *title* (its first line), not its
    /// filename — the row's accessibility label follows the display. The
    /// filename is still available as the row's value, hence `file(withName:)`.
    func file(named title: String) -> XCUIElement {
        element(AccessibilityID.noteList)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    /// Finds a note row by its filename, for assertions that care about what is
    /// on disk rather than what is displayed.
    func file(withName name: String) -> XCUIElement {
        let list = element(AccessibilityID.noteList)
        let identified = list
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", name))
            .firstMatch
        if identified.exists || identified.waitForExistence(timeout: 1) {
            return identified
        }
        return list
            .descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", name))
            .firstMatch
    }

    /// Search results live in their own list now, so they need their own lookup.
    func searchResult(named title: String) -> XCUIElement {
        element(AccessibilityID.searchResults)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    func tab(named name: String) -> XCUIElement {
        element(AccessibilityID.tabBar)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", name))
            .firstMatch
    }

    @discardableResult
    func openFixtureNote() -> XCUIElement {
        // The app now opens on the Inbox; the fixture note sits at the library
        // root, so select Notes to see it.
        chooseSidebarItem("Notes")
        let note = file(named: "Fixture Note")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.click()
        let editor = element(AccessibilityID.editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    /// Sidebar rows carry a count in their accessibility value now, so they are
    /// matched on label rather than value. Folder rows are native file-system
    /// rows on macOS and expose their visible name as `value`, so retain a
    /// value fallback for those rows.
    func chooseSidebarItem(_ title: String) {
        app.activate()
        let labeledItem = element(AccessibilityID.sidebar)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
        if labeledItem.exists || labeledItem.waitForExistence(timeout: 1) {
            labeledItem.click()
            return
        }
        let valuedItem = element(AccessibilityID.sidebar)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", title))
            .firstMatch
        XCTAssertTrue(valuedItem.waitForExistence(timeout: 10))
        valuedItem.click()
    }

    func chooseFileMenuItem(_ title: String) {
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    func text(in editor: XCUIElement) -> String {
        editor.value as? String ?? ""
    }

    func waitForGhostText(in editor: XCUIElement) {
        let predicate = NSPredicate(
            format: "label == %@",
            "Document editor, AI suggestion: fixtureSuggestion"
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: editor
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed
        )
    }
}

@MainActor
final class UITestBootstrapTests: UITestCase {
    func testFixtureLibraryLaunchesWithoutAnOpenPanel() {
        launch()
        chooseSidebarItem("Notes")
        XCTAssertTrue(file(named: "Fixture Note").waitForExistence(timeout: 10))
    }
}
