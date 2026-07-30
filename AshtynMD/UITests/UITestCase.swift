import XCTest

final class UITestBootstrapTests: XCTestCase {
    func testFixtureLibraryLaunchesWithoutAnOpenPanel() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-test-reset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].waitForExistence(timeout: 10))
    }
}
