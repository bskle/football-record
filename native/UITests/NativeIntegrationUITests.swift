import XCTest

@MainActor final class NativeIntegrationUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let png = XCTAttachment(screenshot: app.screenshot()); png.name = name; png.lifetime = .keepAlways; add(png)
    let ax = XCTAttachment(string: app.debugDescription); ax.name = name + "-accessibility"; ax.lifetime = .keepAlways; add(ax)
  }
  private func tap(_ id: String, _ app: XCUIApplication) {
    let e = app.buttons[id].firstMatch
    for _ in 0..<8 {
      if e.exists && e.isHittable && e.frame.minY >= app.frame.minY + 36 && e.frame.maxY <= app.frame.maxY - 4 { break }
      if e.exists && e.frame.minY < app.frame.minY + 36 { app.swipeDown() } else { app.swipeUp() }
    }
    XCTAssertTrue(e.exists, id); XCTAssertTrue(e.isHittable, id); e.tap()
  }
  private func start(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 10))
    tap("start-match", app); tap("choose-starter", app); tap("confirm-start", app)
    XCTAssertTrue(app.buttons["field-toggle"].waitForExistence(timeout: 8))
  }
  func testPureUISmokeUsesUnavailableCapture() {
    let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-dataset", "integration-smoke-" + UUID().uuidString]
    app.launch(); start(app)
    XCTAssertTrue(app.staticTexts["development-marker"].exists)
    XCTAssertTrue(app.otherElements["missing-metrics"].exists || app.descendants(matching: .any)["missing-metrics"].firstMatch.exists)
    capture(app, "integration-ui-only-started")
  }
  func testUISimulationRecordReopensOriginalDatabase() {
    let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-dataset", "integration-restart-" + UUID().uuidString]
    app.launch(); start(app); tap("field-toggle", app)
    XCTAssertEqual(app.buttons["field-toggle"].label, "上场")
    app.terminate(); app.launch()
    XCTAssertTrue(app.buttons["field-toggle"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["field-toggle"].label, "上场"); XCTAssertFalse(app.buttons["start-match"].exists)
    capture(app, "integration-ui-reopened-original-record")
  }
  func testDeviceAcceptancePreferenceSurvivesRelaunchWithoutStartingWorkout() {
    let app = XCUIApplication()
    let suite = "football-record-integration-acceptance-" + UUID().uuidString
    app.launchArguments = ["--integration-preferences-suite", suite, "--device-acceptance"]
    app.launch(); XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 10))
    app.terminate()
    app.launchArguments = ["--integration-preferences-suite", suite]
    app.launch(); XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 10))
    #if !os(watchOS)
    app.tabBars.buttons["设置"].tap()
    #endif
    XCTAssertEqual(app.staticTexts["integration-environment-title"].label, "真实设备验收")
    XCTAssertTrue(app.staticTexts["development-marker"].firstMatch.exists)
    capture(app, "integration-real-mode-reopened-no-workout")
  }
}
