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
        let link = element("tool-solver")
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        app.swipeUp()
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

@MainActor
final class ToyGameUITests: XCTestCase {
    func testKuhnLabSolves() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        app.tabBars.buttons["Lab"].tap()
        let link = app.descendants(matching: .any).matching(identifier: "tool-toys").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        app.swipeUp()
        link.tap()
        let chart = app.descendants(matching: .any).matching(identifier: "toy-chart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        let iterations = app.staticTexts["5000"]
        XCTAssertTrue(iterations.waitForExistence(timeout: 60), "solve did not reach 5,000 iterations: \(chart.debugDescription)")
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("toys.png"))
        }
    }

    /// Regression: tapping Solve again after a solve finished crashed with "Index out of range"
    /// in the strategy card (rows re-rendered against the emptied strategy array).
    func testResolvingAndSwitchingGamesDoesNotCrash() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        app.tabBars.buttons["Lab"].tap()
        let link = app.descendants(matching: .any).matching(identifier: "tool-toys").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        app.swipeUp()
        link.tap()
        let solve = app.descendants(matching: .any).matching(identifier: "toy-solve").firstMatch
        XCTAssertTrue(solve.waitForExistence(timeout: 10))
        // Solve again after a finished solve (same game), then across both games.
        for game in ["Kuhn poker", "Kuhn poker", "Clairvoyance", "Kuhn poker", "Clairvoyance"] {
            XCTAssertTrue(app.staticTexts["5000"].waitForExistence(timeout: 60), "previous solve did not finish")
            app.buttons[game].tap()
            app.buttons["DCFR"].tap()
            solve.tap()
        }
        XCTAssertTrue(app.staticTexts["5000"].waitForExistence(timeout: 60))
        XCTAssertEqual(app.state, .runningForeground)
    }
}

@MainActor
final class RiverSolverUITests: XCTestCase {
    func testRiverSolveReachesTarget() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        app.tabBars.buttons["Lab"].tap()
        let link = app.descendants(matching: .any).matching(identifier: "tool-river").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        app.swipeUp()
        link.tap()
        XCTAssertTrue(app.staticTexts["Big blind, first to act"].waitForExistence(timeout: 120), "river solve did not finish")
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("river.png"))
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
