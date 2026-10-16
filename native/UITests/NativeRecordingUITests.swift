import XCTest

@MainActor final class NativeRecordingUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func launch(_ flags: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-dataset", "acceptance-" + UUID().uuidString] + flags
    app.launch()
    if flags.contains("--ui-scenario") {
      XCTAssertTrue(app.staticTexts["development-marker"].waitForExistence(timeout: 10))
    } else { XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 10)) }
    XCTAssertTrue(app.staticTexts["development-marker"].exists)
    return app
  }
  private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
    let alertLabels = ["cancel-end": "继续比赛", "confirm-end": "结束并保存"]
    let element = app.buttons[alertLabels[id] ?? id]
    for _ in 0..<5 { if element.exists && element.isHittable { return element }; app.swipeUp() }
    return element
  }
  private func tap(_ id: String, in app: XCUIApplication) {
    let e = reveal(id, in: app); XCTAssertTrue(e.exists, id); XCTAssertTrue(e.isHittable, id); XCTAssertTrue(e.isEnabled, id); e.tap()
  }
  private func start(_ app: XCUIApplication, substitute: Bool = false) {
    tap("start-match", in: app)
    tap(substitute ? "choose-substitute" : "choose-starter", in: app)
    tap("confirm-start", in: app)
    XCTAssertTrue(app.buttons["field-toggle"].waitForExistence(timeout: 8))
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
  }
  func testLaunchRecordingEntry() { let app = launch(); capture(app, "recording-entry") }
  func testCancelledStartAndSubstituteConfirmation() {
    let app = launch(); tap("start-match", in: app); tap("choose-substitute", in: app); tap("cancel-start", in: app)
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 4)); XCTAssertFalse(app.buttons["field-toggle"].exists)
    start(app, substitute: true); XCTAssertEqual(app.buttons["field-toggle"].label, "上场")
    tap("field-toggle", in: app); XCTAssertEqual(app.buttons["field-toggle"].label, "下场")
    capture(app, "substitute-entered-missing-metrics")
  }
  func testPauseBenchAndEndConfirmation() {
    let app = launch(); start(app)
    XCTAssertEqual(app.buttons["field-toggle"].label, "下场")
    tap("field-toggle", in: app); XCTAssertEqual(app.buttons["field-toggle"].label, "上场")
    tap("open-controls", in: app); tap("pause-resume", in: app)
    XCTAssertTrue(app.staticTexts["match-status"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["match-status"].label.contains("已暂停"))
    capture(app, "paused-bench")
    tap("open-controls", in: app); tap("pause-resume", in: app)
    tap("open-controls", in: app); tap("request-end", in: app); capture(app, "end-confirmation-before-cancel"); tap("cancel-end", in: app)
    XCTAssertTrue(app.buttons["field-toggle"].waitForExistence(timeout: 5))
    tap("open-controls", in: app); tap("request-end", in: app); tap("confirm-end", in: app)
    let status = app.staticTexts["match-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 5)); XCTAssertTrue(status.label.contains("待同步"))
    XCTAssertFalse(app.buttons["start-match"].exists); capture(app, "ended-pending-sync")
  }
  func testOtherDeviceReadOnlyAndRecoveryGap() {
    let other = launch(["--ui-scenario", "other-device"])
    XCTAssertTrue(other.buttons["field-toggle"].waitForExistence(timeout: 8)); XCTAssertFalse(other.buttons["field-toggle"].isEnabled)
    capture(other, "other-device-read-only")
    other.terminate()
    let gap = launch(["--ui-scenario", "capture-gap"])
    let warning = gap.staticTexts["capture-warning"]
    XCTAssertTrue(warning.waitForExistence(timeout: 8)); XCTAssertTrue(warning.label.contains("缺口"))
    for _ in 0..<3 { if warning.isHittable { break }; gap.swipeUp() }
    capture(gap, "recovery-gap-no-samples")
  }
  func testRecoveryFailuresNeverSelectOrCreateMatch() {
    for scenario in ["multiple-candidates", "identity-unavailable", "blocked-diagnostics"] {
      let app = launch(["--ui-scenario", scenario])
      XCTAssertTrue(app.staticTexts["recording-issue"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["start-match"].isEnabled); XCTAssertFalse(app.buttons["field-toggle"].exists)
      capture(app, scenario); app.terminate()
    }
  }
  #if os(watchOS)
  private func quickPage(_ app: XCUIApplication) {
    app.swipeLeft()
    XCTAssertTrue(app.buttons["quick-myGoal"].waitForExistence(timeout: 5))
  }
  private func expectLast(_ title: String, _ app: XCUIApplication) {
    let e = app.staticTexts["last-quick"]
    let predicate = NSPredicate(format: "label CONTAINS %@", title)
    expectation(for: predicate, evaluatedWith: e)
    waitForExpectations(timeout: 5)
  }
  func testFourQuickButtonsReceiptGuardAndPersistentUndo() {
    let app = launch(["--ui-fixed-clock"]); start(app); quickPage(app)
    for id in ["quick-myGoal", "quick-myAssist", "quick-teamGoal", "quick-conceded"] {
      let button = app.buttons[id]
      XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.width, 44); XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }
    tap("quick-myGoal", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForExistence(timeout: 5))
    tap("quick-conceded", in: app)
    XCTAssertTrue(app.staticTexts["recording-issue"].label.contains("刚刚已记录"))
    XCTAssertTrue(app.staticTexts["personal-stats"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "进球 1")).firstMatch.exists)
    capture(app, "quick-debounced-undo")
    tap("undo-quick", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForNonExistence(timeout: 4)); tap("quick-myAssist", in: app)
    expectLast("我助攻", app); capture(app, "quick-assist")
    tap("undo-quick", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForNonExistence(timeout: 4)); tap("quick-teamGoal", in: app); expectLast("进球", app); capture(app, "quick-team-goal")
    tap("undo-quick", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForNonExistence(timeout: 4)); tap("quick-conceded", in: app); expectLast("失球", app); capture(app, "quick-conceded")
    XCTAssertTrue(app.buttons["undo-quick"].isHittable); XCTAssertGreaterThanOrEqual(app.buttons["undo-quick"].frame.width, 44); XCTAssertGreaterThanOrEqual(app.buttons["undo-quick"].frame.height, 44)
    app.swipeRight(); XCTAssertTrue(app.buttons["field-toggle"].waitForExistence(timeout: 5)); capture(app, "watch-main-after-quick")
  }
  func testSaveFailureRetainsScoreAndRetry() {
    let app = launch(["--ui-fail-first-score"]); start(app); quickPage(app)
    tap("quick-myGoal", in: app)
    XCTAssertTrue(app.buttons["retry-save"].waitForExistence(timeout: 5)); capture(app, "save-failed-original-state")
    tap("retry-save", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["retry-save"].exists); capture(app, "save-retry-committed")
  }
  #else
  func testPhoneTabsAndLargeText() {
    let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    start(app); capture(app, "phone-large-text")
    app.tabBars.buttons["历史"].tap(); XCTAssertTrue(app.staticTexts["历史"].exists); capture(app, "phone-history")
    app.tabBars.buttons["生涯"].tap(); XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "后续版本")).firstMatch.exists)
    app.tabBars.buttons["设置"].tap(); XCTAssertTrue(app.staticTexts["football-record"].exists)
  }
  #endif
}
