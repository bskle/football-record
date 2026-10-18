import XCTest

@MainActor final class NativeAccountLifecycleUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func tap(_ id: String, _ app: XCUIApplication) {
    let control = app.buttons[id].firstMatch
    reveal(control, id, app); control.tap()
  }
  private func reveal(_ control: XCUIElement, _ id: String, _ app: XCUIApplication) {
    #if os(watchOS)
    for _ in 0..<24 {
      let frame = control.exists ? control.frame : .zero
      if control.exists && control.isHittable && frame.height > 0 && frame.minY >= app.frame.minY + 36 && frame.maxY <= app.frame.maxY - 4 { return }
      let down = frame.height > 0 && frame.minY < app.frame.minY + 36
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.40 : 0.72)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.72 : 0.40)))
    }
    #else
    for attempt in 0..<24 {
      if control.exists && control.isHittable && control.frame.height > 0 && control.frame.midY > app.frame.minY + 24 && control.frame.midY < app.frame.maxY - 24 { return }
      let upward = control.exists ? control.frame.midY > app.frame.midY : attempt % 16 < 8
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.77 : 0.36)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.40 : 0.73)))
    }
    #endif
    capture(app, "unreachable-" + id); XCTFail("Control must be actually reachable: " + id)
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    let ax = XCTAttachment(string: app.debugDescription); ax.name = name + "-accessibility"; ax.lifetime = .keepAlways; add(ax)
  }
  func testProductionRemainsUnavailable() {
    let app = XCUIApplication(); app.launchArguments = []; app.launch()
    XCTAssertTrue(app.staticTexts["account-status"].waitForExistence(timeout: 12))
    XCTAssertEqual(app.staticTexts["account-status"].label, "账号服务尚未接通")
    XCTAssertFalse(app.buttons["start-match"].exists)
    capture(app, "production-account-unavailable")
  }
  func testDevelopmentAccountAndPersistentLifecycle() {
    let app = XCUIApplication(); app.launchArguments = ["--m4-development"]; app.launch()
    XCTAssertTrue(app.staticTexts["account-status"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["m4-development-marker"].exists)
    capture(app, "development-account-before-login")
    #if os(iOS)
    let unavailableStatistics = app.switches["analytics-toggle"].firstMatch
    reveal(unavailableStatistics, "analytics-toggle", app)
    unavailableStatistics.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let dataIssue = app.staticTexts["account-lifecycle-issue"].firstMatch
    reveal(dataIssue, "account-lifecycle-issue", app)
    XCTAssertFalse(dataIssue.label.isEmpty); XCTAssertEqual(unavailableStatistics.value as? String, "0")
    XCTAssertFalse(app.staticTexts["account-issue"].exists)
    capture(app, "signed-out-statistics-failure-visible")
    #endif
    tap("account-sign-in", app)
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 20), app.debugDescription)
    tap("start-match", app); tap("choose-starter", app); tap("confirm-start", app)
    XCTAssertTrue(app.buttons["open-controls"].waitForExistence(timeout: 12))
    tap("open-controls", app); tap("request-end", app)
    #if os(watchOS)
    let row = app.cells.matching(NSPredicate(format: "label == %@", "结束并保存")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
    #else
    tap("confirm-end", app)
    #endif
    XCTAssertTrue(app.staticTexts["sync-backend-state"].waitForExistence(timeout: 10))
    capture(app, "normal-end-awaiting-two-proofs")
    tap("sync-authority", app)
    XCTAssertTrue(app.buttons["start-next-match"].waitForExistence(timeout: 20), app.debugDescription)
    capture(app, "normal-end-cloud-and-release-confirmed")
    app.terminate(); app.launch()
    XCTAssertTrue(app.buttons["start-next-match"].waitForExistence(timeout: 15))
    #if os(watchOS)
    tap("open-account", app); reveal(app.staticTexts["account-device-id"].firstMatch, "account-device-id", app); capture(app, "watch-registered-account")
    #else
    app.tabBars.buttons["设置"].tap()
    let analytics = app.switches["analytics-toggle"].firstMatch
    reveal(analytics, "analytics-toggle", app)
    XCTAssertEqual(analytics.value as? String, "0")
    tap("account-renew", app)
    let renewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == YES"), object: app.buttons["account-renew"].firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [renewed], timeout: 10), .completed)
    tap("account-migration", app); capture(app, "phone-migration-controls")
    app.navigationBars.buttons.firstMatch.tap()
    tap("account-delete", app); capture(app, "phone-independent-deletion-choices")
    for id in ["delete-local-choice", "delete-health-choice", "delete-health-confirm"] {
      let control = app.switches[id].firstMatch
      reveal(control, id, app)
      control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: control)
      XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
    }
    tap("request-account-delete", app); tap("confirm-account-delete", app)
    XCTAssertTrue(app.staticTexts["account-status"].waitForExistence(timeout: 20))
    tap("account-delete", app)
    let summary = app.staticTexts["deletion-summary"].firstMatch
    for id in ["backend", "cloud", "local", "health"] {
      let row = app.descendants(matching: .any)["deletion-" + id].firstMatch
      reveal(row, "deletion-" + id, app); XCTAssertTrue(row.exists)
      if id == "cloud" { capture(app, "phone-backend-and-cloud-results") }
    }
    XCTAssertTrue(summary.waitForExistence(timeout: 10))
    capture(app, "phone-local-and-health-results")
    #endif
  }
}

#if os(iOS)
@MainActor final class NativeAccountAccessibilityUITests: XCTestCase {
  func testSmallDarkLargeAccountActionsAreReachable() {
    continueAfterFailure = false
    let app = XCUIApplication(); app.launchArguments = ["--m4-development"]; app.launch()
    XCTAssertTrue(app.buttons["account-sign-in"].waitForExistence(timeout: 15))
    func tap(_ id: String) {
      let button = app.buttons[id].firstMatch
      for _ in 0..<30 {
        if button.exists && button.isHittable && button.frame.height > 0 && button.frame.midY > 50 && button.frame.midY < app.frame.maxY - 35 { button.tap(); return }
        let up = !button.exists || button.frame.midY > app.frame.midY
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.80 : 0.35)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.38 : 0.78)))
      }
      XCTFail("Large text control is not reachable: " + id)
    }
    func capture(_ name: String) {
      let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
      let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    capture("375-dark-maxfont-account")
    tap("account-sign-in")
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 20))
    app.tabBars.buttons["设置"].tap(); tap("account-delete")
    tap("request-account-delete"); capture("375-dark-maxfont-delete-confirmation")
    app.buttons["保留账号"].firstMatch.tap()
    capture("375-dark-maxfont-independent-choices")
  }
}
#endif

#if os(iOS)
@MainActor final class NativeAccountRecoveryUITests: XCTestCase {
  func testRenewedIdentityMustExplicitlyReloadBeforeRecording() {
    continueAfterFailure = false
    let app = XCUIApplication(); app.launchArguments = ["--m4-development"]; app.launch()
    func tap(_ id: String) {
      let button = app.buttons[id].firstMatch
      for attempt in 0..<24 {
        let frame = button.exists ? button.frame : .zero
        if button.exists && button.isHittable && frame.height > 0 && frame.midY > 40 && frame.midY < app.frame.maxY - 30 { button.tap(); return }
        let up = frame.height > 0 ? frame.midY > app.frame.midY : attempt % 16 < 8
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.77 : 0.36)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.40 : 0.73)))
      }
      XCTFail("Recovery control is not reachable: " + id)
    }
    XCTAssertTrue(app.buttons["account-sign-in"].waitForExistence(timeout: 15)); tap("account-sign-in")
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 20)); app.tabBars.buttons["设置"].tap()
    tap("account-identity-change"); app.buttons["确认身份变化"].firstMatch.tap()
    XCTAssertTrue(app.buttons["account-renew"].waitForExistence(timeout: 10)); tap("account-renew")
    let status = app.staticTexts["account-status"].firstMatch
    let verified = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "身份已验证，请重新载入记录"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 15), .completed)
    XCTAssertFalse(app.buttons["start-match"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "renewed-identity-requires-context-reload"; shot.lifetime = .keepAlways; add(shot)
    let ax = XCTAttachment(string: app.debugDescription); ax.name = "renewed-identity-requires-context-reload-accessibility"; ax.lifetime = .keepAlways; add(ax)
    tap("account-reload")
    XCTAssertTrue(app.buttons["start-match"].waitForExistence(timeout: 15))
    tap("start-match"); tap("choose-starter"); tap("confirm-start")
    XCTAssertTrue(app.staticTexts["match-status"].waitForExistence(timeout: 12))
    XCTAssertTrue(app.staticTexts["match-status"].label.contains("记录中"))
  }
}
#endif
