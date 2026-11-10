import XCTest

/// End-to-end checks of the main training flow. The app is launched with `-uiTesting`, which
/// uses an in-memory store and disables Live Activities.
@MainActor
final class DrillFlowUITests: XCTestCase {
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

    private func openDrill(_ kind: String) {
        app.tabBars.buttons["Train"].tap()
        let row = element("drill-\(kind)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    func testTabsExist() {
        for tab in ["Today", "Lab", "Train", "Progress"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 10), "missing tab \(tab)")
        }
    }

    func testEquityQuizAnswerAndAdvance() {
        openDrill("equityQuiz")
        let submit = element("submit-answer")
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        element("equity-slider").adjust(toNormalizedSliderPosition: 0.6)
        submit.tap()
        XCTAssertTrue(element("result-banner").waitForExistence(timeout: 15), "no feedback after answering")
        element("next-spot").tap()
        XCTAssertTrue(element("submit-answer").waitForExistence(timeout: 15), "second spot did not load")
    }

    func testPotOddsDecisionShowsResult() {
        openDrill("potOdds")
        let call = element("call")
        XCTAssertTrue(call.waitForExistence(timeout: 15))
        call.tap()
        XCTAssertTrue(element("result-banner").waitForExistence(timeout: 15))
    }

    func testEndingSessionShowsSummary() {
        openDrill("equityQuiz")
        XCTAssertTrue(element("submit-answer").waitForExistence(timeout: 15))
        element("submit-answer").tap()
        XCTAssertTrue(element("result-banner").waitForExistence(timeout: 15))
        element("end-session").tap()
        XCTAssertTrue(element("session-summary").waitForExistence(timeout: 10))
        element("session-done").tap()
        XCTAssertTrue(element("drill-equityQuiz").waitForExistence(timeout: 10), "Done should return to the drill list")
    }

    func testFullTenSpotSession() {
        openDrill("potOdds")
        for i in 1...10 {
            let fold = element("fold")
            XCTAssertTrue(fold.waitForExistence(timeout: 15), "spot \(i) did not load")
            fold.tap()
            let next = element("next-spot")
            XCTAssertTrue(next.waitForExistence(timeout: 15))
            next.tap()
        }
        XCTAssertTrue(element("session-summary").waitForExistence(timeout: 10))
    }
}
