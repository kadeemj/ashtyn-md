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

    func file(named name: String) -> XCUIElement {
        element(AccessibilityID.fileList)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
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
        let note = file(named: "Fixture Note.md")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.click()
        let editor = element(AccessibilityID.editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    func chooseSidebarItem(_ title: String) {
        let item = element(AccessibilityID.sidebar)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", title))
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
        XCTAssertTrue(file(named: "Fixture Note.md").waitForExistence(timeout: 10))
    }
}
