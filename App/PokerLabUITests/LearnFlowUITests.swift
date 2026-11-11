import XCTest

/// The Learn tab: start the current lesson, answer every question, finish.
@MainActor
final class LearnFlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Saves a screenshot when SCREENSHOT_DIR is set (used to compare against docs/design).
    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testLessonStartToFinish() {
        XCTAssertTrue(element("streak-pill").waitForExistence(timeout: 10))
        snapshot("learn")
        element("continue-lesson").tap()
        let primary = element("lesson-primary")
        XCTAssertTrue(element("answer-0").waitForExistence(timeout: 60), "lesson did not load")
        snapshot("lesson")
        var answered = 0
        while element("answer-0").exists && answered < 20 {
            XCTAssertFalse(primary.isEnabled, "Check must be disabled until an answer is picked")
            let before = primary.frame.height
            element("answer-1").tap()
            primary.tap()
            XCTAssertTrue(element("lesson-feedback").waitForExistence(timeout: 10))
            XCTAssertEqual(primary.frame.height, before, accuracy: 0.5, "primary button changed height after Check")
            if answered == 0 { snapshot("lesson-feedback") }
            primary.tap()
            answered += 1
            if element("lesson-summary").waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(element("lesson-summary").exists, "no summary after \(answered) questions")
        element("lesson-done").tap()
        XCTAssertTrue(element("continue-lesson").waitForExistence(timeout: 10))
    }

    func testTabScreenshots() {
        XCTAssertTrue(element("streak-pill").waitForExistence(timeout: 10))
        app.tabBars.buttons["Lab"].tap()
        XCTAssertTrue(element("show-math").waitForExistence(timeout: 10))
        element("show-math").tap()
        snapshot("lab")
        app.tabBars.buttons["Practice"].tap()
        XCTAssertTrue(element("drill-potOdds").waitForExistence(timeout: 10))
        snapshot("practice")
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(element("settings-button").waitForExistence(timeout: 10))
        snapshot("profile")
    }
}
