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
        app.launchArguments = ["-ui-testing", "-AppleKeyboardUIMode", "3"]
        if reset { app.launchArguments.append("-ui-test-reset") }
        if onboarding { app.launchArguments.append("-ui-test-show-onboarding") }
        if standalone { app.launchArguments.append("-ui-test-standalone") }
        app.launch()
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
        element(AccessibilityID.noteList)
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
    /// matched on label rather than value.
    func chooseSidebarItem(_ title: String) {
        let item = element(AccessibilityID.sidebar)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
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
