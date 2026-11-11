import XCTest

/// The push/fold solver on the Metal backend. The iOS Simulator allows fewer threads per
/// threadgroup than real GPUs; this used to trip a Metal validation assert and crash.
@MainActor
final class SolverUITests: XCTestCase {
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

    func testSolverOnGPUDoesNotCrash() {
        app.tabBars.buttons["Lab"].tap()
        let link = app.buttons["Push/Fold Solver"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let gpu = app.buttons["GPU (Metal)"]
        XCTAssertTrue(gpu.waitForExistence(timeout: 10))
        gpu.tap()
        let ranOn = element("solver-ran-on")
        let predicate = NSPredicate(format: "label CONTAINS 'GPU' OR label CONTAINS 'Metal'")
        expectation(for: predicate, evaluatedWith: ranOn)
        waitForExpectations(timeout: 60)
        print("Solver backend status: \(ranOn.label)")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
