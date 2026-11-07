import XCTest

final class DemoScreenshots: XCTestCase {
    func testWakeRequiresFullHold() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if app.buttons["开始使用"].waitForExistence(timeout: 5) { app.buttons["开始使用"].tap() }
        let record = app.buttons["只录音"]
        for _ in 0..<5 {
            if record.isHittable, record.frame.maxY < app.buttons["statisticsDelay"].frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(record.isHittable)
        record.tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        for _ in 0..<3 {
            guard permission.waitForExistence(timeout: 3) else { break }
            let allow = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "好", "OK"])).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
        XCTAssertTrue(app.navigationBars["睡眠中"].waitForExistence(timeout: 15))
        let wake = app.buttons["wakeUp"]
        XCTAssertEqual(wake.label, "起床")
        XCTAssertTrue(wake.isHittable)
        wake.tap()
        wake.press(forDuration: 0.2)
        XCTAssertTrue(app.navigationBars["睡眠中"].exists)
        XCTAssertFalse(app.staticTexts["当晚报告"].exists)
        // Hit the capsule away from its text to verify the full-width touch target.
        wake.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["当晚报告"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.navigationBars["睡眠中"].exists)
    }

    func testDemoNightAndScreens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if app.buttons["开始使用"].waitForExistence(timeout: 5) { app.buttons["开始使用"].tap() }
        XCTAssertTrue(app.tabBars.buttons["睡前"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startSleep"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["startSleep"].frame.maxY, app.tabBars.firstMatch.frame.minY)
        shot("01-bedtime", app)
        let delayPicker = app.descendants(matching: .any).matching(identifier: "statisticsDelay").firstMatch
        for _ in 0..<4 {
            if delayPicker.isHittable { break }
            app.swipeUp()
        }
        shot("01b-bedtime-options", app)
        XCTAssertTrue(delayPicker.isHittable)
        XCTAssertTrue(app.buttons["startSleep"].isHittable)
        XCTAssertLessThanOrEqual(delayPicker.frame.maxY, app.buttons["startSleep"].frame.minY)
        delayPicker.tap()
        app.buttons["20 分钟"].tap()
        let changedDelay = expectation(for: NSPredicate(format: "label == %@", "20 分钟后开始统计 · 修改"), evaluatedWith: app.buttons["statisticsDelay"])
        wait(for: [changedDelay], timeout: 5)
        shot("01b-bedtime-options", app)
        app.terminate()
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = ios.deletingLastPathComponent().appendingPathComponent("fixtures/out")
        app.launchArguments = ["-demoNight", fixtures.appendingPathComponent("14_composite_90min.wav").path,
                               "-demoLabels", fixtures.appendingPathComponent("14_composite_90min.codex-labels.json").path]
        app.launch()
        XCTAssertTrue(app.navigationBars["睡眠中"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["wakeUp"].isHittable)
        XCTAssertGreaterThan(app.buttons["wakeUp"].frame.midY, app.frame.height / 2)
        shot("02-recording", app)
        XCTAssertTrue(app.staticTexts["当晚报告"].waitForExistence(timeout: 240))
        if app.buttons["知道了"].waitForExistence(timeout: 5) {
            app.buttons["知道了"].tap()
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.alerts.firstMatch)
            wait(for: [gone], timeout: 10)
        }
        let recorded = app.descendants(matching: .any).matching(identifier: "recordedDuration").firstMatch
        let episodes = app.descendants(matching: .any).matching(identifier: "episodeDuration").firstMatch
        XCTAssertTrue(recorded.waitForExistence(timeout: 15))
        XCTAssertTrue(recorded.isHittable)
        XCTAssertTrue(episodes.isHittable)
        XCTAssertTrue(recorded.label.contains("1 小时 30 分"))
        XCTAssertTrue(episodes.label.contains("占"))
        shot("03-report", app)
        for _ in 0..<5 {
            if app.staticTexts["时间轴"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["时间轴"].isHittable)
        shot("04-timeline", app)
        app.swipeUp()
        var pauseButton: XCUIElement?
        for _ in 0..<16 {
            pauseButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pauseJump-")).allElementsBoundByIndex.first { $0.isHittable }
            if pauseButton != nil { break }
            app.swipeUp()
        }
        let jump = try XCTUnwrap(pauseButton)
        let clipID = String(jump.identifier.dropFirst("pauseJump-".count))
        jump.tap()
        let stop = app.buttons["clipPlay-" + clipID]
        let ready = expectation(for: NSPredicate(format: "label == %@", "停止"), evaluatedWith: stop)
        wait(for: [ready], timeout: 20)
        let slider = app.sliders["clipSlider-" + clipID]
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 0.35)
        XCTAssertTrue(stop.label == "停止")
        XCTAssertTrue(jump.exists)
        shot("05-clips", app)
        stop.tap()
        for _ in 0..<16 {
            if app.buttons["诊断信息"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["诊断信息"].isHittable)
        shot("08-diagnostics-collapsed", app)
        app.buttons["诊断信息"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["分类器平均耗时"].waitForExistence(timeout: 5))
        shot("09-diagnostics-expanded", app)
        app.buttons["完成"].tap()
        app.tabBars.buttons["历史"].tap()
        XCTAssertTrue(app.staticTexts["每晚记录"].exists)
        shot("06-history", app)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["拿分贝计 App 对照一次。修改仅影响以后的夜晚。"].exists)
        shot("07-settings", app)
        app.terminate()
        app.launchArguments += ["-demoAlarmAt", "3600"]
        app.launch()
        XCTAssertTrue(app.staticTexts["当晚报告"].waitForExistence(timeout: 240))
        for _ in 0..<5 {
            if app.staticTexts["时间轴"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["时间轴"].isHittable)
        XCTAssertTrue(app.staticTexts["闹钟"].exists)
        shot("10-timeline-alarm", app)
    }
    private func shot(_ name: String, _ app: XCUIApplication) {
        let capture = app.screenshot()
        let attachment = XCTAttachment(screenshot: capture); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? capture.pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
