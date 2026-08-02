import XCTest

@MainActor
final class KeyboardAccessibilityUITests: UITestCase {
    func testKeyboardSearchAndOpen() {
        launch()
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = element(AccessibilityID.searchField)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("alpha")
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element(AccessibilityID.editor).waitForExistence(timeout: 10))
    }

    func testKeyboardCreateSaveAndCloseTab() {
        launch()
        app.typeKey("n", modifierFlags: .command)
        let editor = element(AccessibilityID.editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("# Keyboard note")
        editor.typeKey("s", modifierFlags: .command)
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(editor.waitForExistence(timeout: 2))
    }

    func testKeyboardEditorCommands() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeText("\nkeyboardLine")
        editor.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(text(in: editor).hasSuffix("keyboardLine\nkeyboardLine"))
        editor.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(
            text(in: editor).hasSuffix("keyboardLine\n<!-- keyboardLine -->")
        )
        editor.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertFalse(text(in: editor).hasSuffix("<!-- keyboardLine -->"))
    }

    func testKeyboardPreviewModeAndCompletionDismissal() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        app.typeKey(" ", modifierFlags: [.control, .option])
        waitForGhostText(in: editor)
        editor.typeKey(.escape, modifierFlags: [])
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(text(in: editor).contains("fixtureSuggestion"))

        app.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(element(AccessibilityID.previewWebView).waitForExistence(timeout: 10))
    }
}
