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
    #if os(watchOS)
    if let label = alertLabels[id] {
      // The native Watch confirmation exposes an accessible table row; its nested Button
      // is printed in snapshots but skipped by XCUI's optimized firstMatch button search.
      let row = app.cells.matching(NSPredicate(format: "label == %@", label)).element
      XCTAssertTrue(row.waitForExistence(timeout: 5), label)
      return row
    }
    #endif
    let identified = app.buttons[id].firstMatch
    let element = identified.exists ? identified : app.buttons[alertLabels[id] ?? id].firstMatch
    let modal = ["choose-starter", "choose-substitute", "confirm-start", "cancel-start", "pause-resume", "request-end", "close-controls", "confirm-end", "cancel-end"].contains(id)
    for _ in 0..<8 {
      let top = app.frame.minY + 36
      var bottom = app.frame.maxY - 4
      #if os(watchOS)
      if !modal { bottom -= 18 }
      #else
      let bar = app.tabBars.firstMatch
      if !modal && bar.exists && bar.isHittable { bottom = min(bottom, bar.frame.minY - 6) }
      #endif
      if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return element }
      if element.exists && element.frame.minY < top { app.swipeDown() } else { app.swipeUp() }
    }
    print("Unresolved control \(id), frame \(element.exists ? element.frame.debugDescription : "absent")")
    capture(app, "unresolved-control-" + id)
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
    let predicate = NSPredicate(format: "label == %@", "已记：" + title)
    expectation(for: predicate, evaluatedWith: e)
    waitForExpectations(timeout: 5)
  }
  private func expectQuickValues(_ score: String, goals: Int, assists: Int, in app: XCUIApplication) {
    XCTAssertEqual(app.staticTexts["quick-score"].label, "本场比分 " + score)
    XCTAssertEqual(app.staticTexts["personal-stats"].label, "进球 \(goals) · 助攻 \(assists)")
  }
  func testFourQuickButtonsReceiptGuardAndPersistentUndo() {
    let app = launch(["--ui-fixed-clock"]); start(app); quickPage(app)
    for id in ["quick-myGoal", "quick-myAssist", "quick-teamGoal", "quick-conceded"] {
      let button = app.buttons[id]
      XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.width, 44); XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }
    tap("quick-myGoal", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForExistence(timeout: 5))
    expectQuickValues("1 : 0", goals: 1, assists: 0, in: app)
    tap("quick-conceded", in: app)
    XCTAssertTrue(app.staticTexts["recording-issue"].label.contains("刚刚已记录"))
    XCTAssertTrue(app.staticTexts["personal-stats"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "进球 1")).firstMatch.exists)
    expectQuickValues("1 : 0", goals: 1, assists: 0, in: app)
    capture(app, "quick-debounced-undo")
    tap("undo-quick", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForNonExistence(timeout: 4)); tap("quick-myAssist", in: app)
    expectLast("我助攻", app); expectQuickValues("1 : 0", goals: 0, assists: 1, in: app); capture(app, "quick-assist")
    tap("undo-quick", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForNonExistence(timeout: 4)); tap("quick-teamGoal", in: app); expectLast("进球", app); expectQuickValues("1 : 0", goals: 0, assists: 0, in: app); capture(app, "quick-team-goal")
    tap("undo-quick", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForNonExistence(timeout: 4)); tap("quick-conceded", in: app); expectLast("失球", app); expectQuickValues("0 : 1", goals: 0, assists: 0, in: app); capture(app, "quick-conceded")
    XCTAssertTrue(app.buttons["undo-quick"].isHittable); XCTAssertGreaterThanOrEqual(app.buttons["undo-quick"].frame.width, 44); XCTAssertGreaterThanOrEqual(app.buttons["undo-quick"].frame.height, 44)
    app.swipeRight(); XCTAssertTrue(app.buttons["field-toggle"].waitForExistence(timeout: 5)); capture(app, "watch-main-after-quick")
  }
  func testSaveFailureRetainsScoreAndRetry() {
    let app = launch(["--ui-fail-first-score"]); start(app); quickPage(app)
    tap("quick-myGoal", in: app)
    XCTAssertTrue(app.buttons["retry-save"].waitForExistence(timeout: 5)); expectQuickValues("0 : 0", goals: 0, assists: 0, in: app); capture(app, "save-failed-original-state")
    tap("retry-save", in: app); XCTAssertTrue(app.buttons["undo-quick"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["retry-save"].exists); expectQuickValues("1 : 0", goals: 1, assists: 0, in: app); capture(app, "save-retry-committed")
  }
  #else
  func testPhoneOverviewScreenshot() {
    let app = launch(); start(app)
    XCTAssertTrue(app.staticTexts["match-score"].exists)
    capture(app, "phone-overview")
  }
  func testPhoneTabsAndLargeText() {
    let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    start(app)
    XCTAssertLessThan(app.staticTexts["match-score"].frame.height, 70, "Score must remain on one line")
    for id in ["match-clock", "field-clock"] {
      let clock = app.staticTexts[id]
      XCTAssertLessThan(clock.frame.height, 100, "Digits must remain on one line at accessibility size")
      XCTAssertGreaterThanOrEqual(clock.frame.minX, 0); XCTAssertLessThanOrEqual(clock.frame.maxX, app.frame.width)
    }
    capture(app, "phone-large-text")
    app.tabBars.buttons["历史"].tap(); XCTAssertTrue(app.staticTexts["历史"].firstMatch.exists); capture(app, "phone-history")
    app.tabBars.buttons["生涯"].tap(); XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "后续版本")).firstMatch.exists)
    app.tabBars.buttons["设置"].tap(); XCTAssertTrue(app.staticTexts["football-record"].exists)
    app.tabBars.buttons["比赛"].tap()
    tap("open-controls", in: app)
    XCTAssertTrue(app.buttons["pause-resume"].waitForExistence(timeout: 4), "Control sheet must actually open")
    tap("request-end", in: app); tap("confirm-end", in: app)
    let status = app.staticTexts["match-status"].firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5)); XCTAssertTrue(status.label.contains("待同步"))
    XCTAssertGreaterThanOrEqual(status.frame.minX, 0); XCTAssertLessThanOrEqual(status.frame.maxX, app.frame.width)
    XCTAssertLessThan(status.frame.height, 150, "Long terminal status must not be squeezed beside the field label")
    for _ in 0..<5 { if status.isHittable && status.frame.minY > 45 { break }; app.swipeDown() }
    capture(app, "phone-large-ended-status")
  }
  #endif
}
