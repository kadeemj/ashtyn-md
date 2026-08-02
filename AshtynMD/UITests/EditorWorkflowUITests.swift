import AppKit
import XCTest

@MainActor
final class EditorWorkflowUITests: UITestCase {
    func testPastePreservesCharactersAndLineBreaks() {
        launch()
        let editor = openFixtureNote()
        let pasted = "  alpha()\n\tbeta = \"🙂\"\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasted, forType: .string)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(text(in: editor), pasted)
    }

    func testMarkdownModeRestores() {
        launch()
        _ = openFixtureNote()
        let picker = element(AccessibilityID.modePicker)
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.radioButtons["Preview"].click()
        XCTAssertTrue(element(AccessibilityID.previewWebView).waitForExistence(timeout: 10))

        app.terminate()
        launch(reset: false)
        XCTAssertTrue(tab(named: "Fixture Note.md").waitForExistence(timeout: 10))
        XCTAssertTrue(element(AccessibilityID.previewWebView).waitForExistence(timeout: 10))
        let restoredPicker = element(AccessibilityID.modePicker)
        XCTAssertEqual(
            (restoredPicker.radioButtons["Preview"].value as? NSNumber)?.intValue,
            1
        )
    }

    func testImagePasteInsertsRelativeLink() {
        launch()
        let editor = openFixtureNote()
        let imageData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setData(imageData, forType: .png))
        editor.click()
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(
            text(in: editor).contains("](Assets/image-"),
            editor.debugDescription
        )
    }

    func testMockGhostTextAcceptAndDismiss() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        app.typeKey(" ", modifierFlags: [.control, .option])
        waitForGhostText(in: editor)
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(text(in: editor).hasSuffix("fixtureSuggestion"))

        app.typeKey(" ", modifierFlags: [.control, .option])
        waitForGhostText(in: editor)
        editor.typeKey(.escape, modifierFlags: [])
        editor.typeKey(.tab, modifierFlags: [])
        let acceptedCount = text(in: editor)
            .components(separatedBy: "fixtureSuggestion").count - 1
        XCTAssertEqual(acceptedCount, 1)
    }

    func testWikiLinkAutocompleteSelectsSuggestion() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeText("[[Week")

        let suggestion = element(AccessibilityID.wikiLinkSuggestion(0))
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), suggestion.debugDescription)
        suggestion.click()

        XCTAssertTrue(
            text(in: editor).contains("[[Weekly Review]]"),
            editor.debugDescription
        )
    }

    func testWikiLinkCreateNoteInsertsLinkAndCreatesFile() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeText("[[Brand New Note")

        let createRow = element(AccessibilityID.wikiLinkCreateNote)
        XCTAssertTrue(createRow.waitForExistence(timeout: 5), createRow.debugDescription)
        createRow.click()

        XCTAssertTrue(
            text(in: editor).contains("[[Brand New Note]]"),
            editor.debugDescription
        )

        chooseSidebarItem("Notes")
        XCTAssertTrue(file(named: "Brand New Note").waitForExistence(timeout: 10))
    }

    func testStandaloneDocumentLaunch() {
        launch(standalone: true)
        XCTAssertTrue(
            app.descendants(matching: .any)["Standalone.md"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(element(AccessibilityID.editor).waitForExistence(timeout: 10))
    }

    func testLargeFileOpenAnywayKeepsAIDisabled() {
        launch()
        // The fixture lives at the library root; launch defaults to Inbox.
        chooseSidebarItem("Notes")
        let large = file(named: "Large.md")
        XCTAssertTrue(large.waitForExistence(timeout: 10))
        large.click()
        let openAnyway = element(AccessibilityID.openLargeFileAnyway)
        XCTAssertTrue(openAnyway.waitForExistence(timeout: 10))
        openAnyway.click()
        XCTAssertTrue(element(AccessibilityID.largeFileMode).waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts[
                "Large-file mode: AI is off and Markdown preview updates manually."
            ].exists
        )
    }
}
