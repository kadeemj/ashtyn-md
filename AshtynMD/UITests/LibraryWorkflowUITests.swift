import XCTest

@MainActor
final class LibraryWorkflowUITests: UITestCase {
    func testChooseAndReopenLibrary() {
        launch(reset: true, onboarding: true)
        let choose = element(AccessibilityID.onboardingChooseFolder)
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.click()
        chooseSidebarItem("Notes")
        XCTAssertTrue(file(named: "Fixture Note").waitForExistence(timeout: 10))

        app.terminate()
        launch(reset: false)
        chooseSidebarItem("Notes")
        XCTAssertTrue(file(named: "Fixture Note").waitForExistence(timeout: 10))
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

        // ⌥⌘N creates where the sidebar points; plain ⌘N always captures to the
        // Inbox regardless of selection.
        app.typeKey("n", modifierFlags: [.command, .option])
        // A brand-new note has no first line yet, so it lists as "Untitled".
        XCTAssertTrue(file(named: "Untitled").waitForExistence(timeout: 10))

        chooseFileMenuItem("New Code File")
        let swiftItem = app.menuItems["Swift (.swift)"]
        XCTAssertTrue(swiftItem.waitForExistence(timeout: 5))
        swiftItem.click()
        // Code files are never parsed for a title, so the filename shows.
        XCTAssertTrue(file(named: "Untitled.swift").waitForExistence(timeout: 10))
    }

    func testNewNoteLandsInTheInbox() {
        launch()
        // Wait for the attached fixture library before sending the command;
        // ⌘N is correctly disabled while the library is still bootstrapping.
        chooseSidebarItem("Inbox")
        app.typeKey("n", modifierFlags: .command)
        // ⌘N captures to the Inbox, which is also where the app opened.
        let created = file(named: "Untitled")
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        XCTAssertTrue(
            file(withName: "Untitled.md").exists,
            created.debugDescription
        )
    }

    func testLaunchSelectsInboxAndRestoresTabs() {
        launch()
        openFixtureNote()
        XCTAssertTrue(tab(named: "Fixture Note.md").exists)

        app.terminate()
        launch(reset: false)
        // The sidebar always lands on the Inbox so the app opens ready to
        // capture, while previously open tabs still come back.
        XCTAssertTrue(tab(named: "Fixture Note.md").waitForExistence(timeout: 10))
    }

    func testOpenSeveralTabsAndRestoreState() {
        launch()
        openFixtureNote()
        chooseSidebarItem("Code")
        let source = file(withName: "sample.swift")
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
        chooseSidebarItem("Notes")
        let note = file(named: "Fixture Note")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.rightClick()
        let favorite = app.menuItems["Add to Favorites"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.click()

        chooseSidebarItem("Favorites")
        XCTAssertTrue(file(named: "Fixture Note").waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = element(AccessibilityID.searchField)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("alpha")
        // Search results now live in their own list with its own identifier.
        let result = searchResult(named: "Fixture Note")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()

        chooseSidebarItem("Recents")
        XCTAssertTrue(file(named: "Fixture Note").waitForExistence(timeout: 10))
    }

    func testTagAppearsInSidebarAndFiltersNotes() {
        launch()
        // Tagged Note.md carries #work/alpha, so both the parent and the child
        // show up, and selecting the parent still lists the note.
        chooseSidebarItem("work")
        XCTAssertTrue(file(named: "Weekly Review").waitForExistence(timeout: 10))

        chooseSidebarItem("alpha")
        XCTAssertTrue(file(named: "Weekly Review").waitForExistence(timeout: 10))
    }

    func testNoteInfoShowsStatisticsAndBacklinks() {
        launch()
        openFixtureNote()

        let infoButton = app.buttons[AccessibilityID.noteInfoInspector]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 10))
        infoButton.click()

        XCTAssertTrue(element(AccessibilityID.noteInfoStatistics)
            .waitForExistence(timeout: 10))
        let readingTime = app.staticTexts
            .matching(NSPredicate(format: "value == %@", "1 min"))
            .firstMatch
        XCTAssertTrue(readingTime.waitForExistence(timeout: 10))

        let backlinksHeading = app.staticTexts[AccessibilityID.noteInfoBacklinks]
        XCTAssertTrue(backlinksHeading.waitForExistence(timeout: 10))
        let backlink = app.buttons
            .matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                AccessibilityID.noteInfoBacklinks,
                "Weekly Review"
            ))
            .firstMatch
        XCTAssertTrue(backlink.waitForExistence(timeout: 10), app.debugDescription)
    }
}
