import XCTest

@MainActor final class NativeIntegrationUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let png = XCTAttachment(screenshot: app.screenshot()); png.name = name; png.lifetime = .keepAlways; add(png)
    let ax = XCTAttachment(string: app.debugDescription); ax.name = name + "-accessibility"; ax.lifetime = .keepAlways; add(ax)
  }
  private func tap(_ id: String, _ app: XCUIApplication) {
    let e = app.buttons[id].firstMatch
    #if os(watchOS)
    revealOnWatch(e, id: id, app: app)
    #else
    for _ in 0..<8 {
      if e.exists && e.isHittable && e.frame.minY >= app.frame.minY + 36 && e.frame.maxY <= app.frame.maxY - 4 { break }
      if e.exists && e.frame.minY < app.frame.minY + 36 { app.swipeDown() } else { app.swipeUp() }
    }
    #endif
    XCTAssertTrue(e.exists, id); XCTAssertTrue(e.isHittable, id); e.tap()
  }
  #if os(watchOS)
  private func revealOnWatch(_ element: XCUIElement, id: String, app: XCUIApplication) {
    // Small drags avoid overshooting an entire 45mm page. Offscreen snapshots
    // may have a zero frame; only a nonzero frame can prove the target is above.
    for _ in 0..<20 {
      let frame = element.exists ? element.frame : .zero
      if element.exists && element.isHittable && frame.minY >= app.frame.minY + 36 && frame.maxY <= app.frame.maxY - 4 { return }
      let down = id == "environment-close" || (frame.height > 0 && frame.minY < app.frame.minY + 36)
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.40 : 0.72))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.72 : 0.40))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    capture(app, "unresolved-watch-" + id)
  }
  private func showWatchIdentity(_ identity: XCUIElement, app: XCUIApplication) {
    // Return to a known page origin before seeking this text in either direction.
    revealOnWatch(app.buttons["environment-close"].firstMatch, id: "environment-close", app: app)
    revealOnWatch(identity, id: "device-local-identity", app: app)
    XCTAssertTrue(identity.isHittable)
  }
  #endif
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
  func testEnvironmentSwitchRebuildsStoppedContextAndKeepsActualLocalIdentity() {
    let app = XCUIApplication()
    app.launchArguments = ["--integration-preferences-suite", "football-record-integration-acceptance-" + UUID().uuidString, "--device-acceptance"]
    app.launch(); XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 10))
    #if !os(watchOS)
    app.tabBars.buttons["设置"].tap()
    #endif
    tap("open-environment", app)
    let identity = app.staticTexts["device-local-identity"]
    XCTAssertTrue(identity.waitForExistence(timeout: 5))
    let original = identity.label
    #if os(watchOS)
    showWatchIdentity(identity, app: app)
    capture(app, "integration-device-initial-identity")
    #endif
    XCTAssertNotNil(UUID(uuidString: original))
    XCTAssertTrue(app.staticTexts["device-pair-status"].firstMatch.label.contains("未配置"))
    tap("environment-ui", app)
    XCTAssertEqual(app.staticTexts["integration-mode"].label, "纯界面演练")
    tap("environment-device", app)
    XCTAssertTrue(identity.waitForExistence(timeout: 5)); XCTAssertEqual(identity.label, original)
    XCTAssertEqual(app.staticTexts["integration-mode"].label, "真实设备验收")
    #if os(watchOS)
    showWatchIdentity(identity, app: app)
    #endif
    capture(app, "integration-device-context-rebuilt-stable-identity")
    tap("environment-close", app)
    #if !os(watchOS)
    app.tabBars.buttons["比赛"].tap()
    #endif
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["start-match"].isEnabled, "shutdown model must never be reused")
    #if os(watchOS)
    revealOnWatch(app.buttons["start-match"].firstMatch, id: "start-match", app: app)
    XCTAssertTrue(app.buttons["start-match"].isHittable)
    #endif
    capture(app, "integration-device-context-rebuilt-ready-unpaired")
  }

}
