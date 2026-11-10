import XCTest

final class DrillFlowUITests: XCTestCase {
    func testLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Train"].waitForExistence(timeout: 10))
    }
}
