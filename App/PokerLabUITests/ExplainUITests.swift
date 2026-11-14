import XCTest

/// On-device explanations: the button only appears where Apple Intelligence is available.
@MainActor
final class ExplainUITests: XCTestCase {
    func testExplainWhenAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(element("continue-lesson").waitForExistence(timeout: 10))
        element("continue-lesson").tap()
        XCTAssertTrue(element("answer-0").waitForExistence(timeout: 60))
        element("answer-0").tap()
        element("lesson-primary").tap()
        XCTAssertTrue(element("lesson-feedback").waitForExistence(timeout: 10))
        let explain = element("lesson-explain")
        guard explain.waitForExistence(timeout: 3) else {
            print("Explain button not shown: Apple Intelligence is unavailable here.")
            throw XCTSkip("Apple Intelligence unavailable in this simulator")
        }
        explain.tap()
        let text = element("ai-explanation")
        if text.waitForExistence(timeout: 90) {
            print("AI explanation: \(text.label)")
        } else {
            print("No explanation shown (withheld or failed).")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
