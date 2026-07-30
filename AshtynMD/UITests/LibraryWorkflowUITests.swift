import XCTest

@MainActor
final class LibraryWorkflowUITests: UITestCase {
    func testChooseAndReopenLibrary() {
        launch(reset: true, onboarding: true)
        let choose = element(AccessibilityID.onboardingChooseFolder)
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.click()
        XCTAssertTrue(file(named: "Fixture Note.md").waitForExistence(timeout: 10))

        app.terminate()
        launch(reset: false)
        XCTAssertTrue(file(named: "Fixture Note.md").waitForExistence(timeout: 10))
        XCTAssertFalse(element(AccessibilityID.onboardingChooseFolder).exists)
    }

    func testCreateNestedFolderAndMultipleFileTypes() {
        launch()
        chooseSidebarItem("Library")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["New Folder"].waitForExistence(timeout: 10))
        chooseSidebarItem("New Folder")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["New Folder"].waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(file(named: "Untitled.md").waitForExistence(timeout: 10))
        chooseFileMenuItem("New Code File")
        let swiftItem = app.menuItems["Swift (.swift)"]
        XCTAssertTrue(swiftItem.waitForExistence(timeout: 5))
        swiftItem.click()
        XCTAssertTrue(file(named: "Untitled.swift").waitForExistence(timeout: 10))
    }

    func testOpenSeveralTabsAndRestoreState() {
        launch()
        openFixtureNote()
        chooseSidebarItem("Code")
        let source = file(named: "sample.swift")
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        XCTAssertTrue(tab(named: "Fixture Note.md").exists)
        XCTAssertTrue(tab(named: "sample.swift").exists)

        app.terminate()
        launch(reset: false)
        XCTAssertTrue(tab(named: "Fixture Note.md").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(named: "sample.swift").waitForExistence(timeout: 10))
    }

    func testSearchFavoriteAndReopenRecentNote() {
        launch()
        let note = file(named: "Fixture Note.md")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.rightClick()
        let favorite = app.menuItems["Add to Favorites"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.click()

        chooseSidebarItem("Favorites")
        XCTAssertTrue(file(named: "Fixture Note.md").waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = element(AccessibilityID.searchField)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("alpha")
        let result = file(named: "Fixture Note.md")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()

        chooseSidebarItem("Recents")
        XCTAssertTrue(file(named: "Fixture Note.md").waitForExistence(timeout: 10))
    }
}
