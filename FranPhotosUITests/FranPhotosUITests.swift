import XCTest

/// UI smoke tests: launch, welcome screen, create-library flow surface.
final class FranPhotosUITests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsWelcome() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to FranPhotos"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Create Library…"].exists)
        XCTAssertTrue(app.buttons["Open Library…"].exists)
    }

    @MainActor
    func testImportMenuDisabledWithoutLibrary() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to FranPhotos"].waitForExistence(timeout: 15))
        let importItem = app.menuBarItems["File"].menuItems["Import…"]
        XCTAssertTrue(importItem.exists)
        XCTAssertFalse(importItem.isEnabled)
    }
}
