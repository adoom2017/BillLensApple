import XCTest

/// 模拟器端到端冒烟：在干净的模拟器上手动新增 / 编辑账单、订阅、资产，并检查列表结果。
@MainActor
final class ManualEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() async throws {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .deleteOnSuccess
        add(shot)
    }

    func testCreateAndEditRecord() {
        openTab("账单")
        tap(app.buttons["添加账单"])
        type("18.80", into: app.textFields["金额"])
        type("UITest面馆", into: app.textFields["商户"])
        save()

        showAllRecords()
        let row = app.staticTexts["UITest面馆"].firstMatch
        XCTAssertTrue(scrollUntilVisible(row), "新增的账单应出现在列表中")

        row.tap()
        XCTAssertTrue(app.navigationBars["编辑账单"].waitForExistence(timeout: 5))
        replace(app.textFields["金额"], with: "26.50")
        save()
        XCTAssertTrue(scrollUntilVisible(text(containing: "26.50")), "修改后的金额应刷新到列表")
        XCTAssertFalse(text(containing: "18.80").exists, "旧金额不应再出现")
    }

    func testCreateSubscriptionChargesToday() {
        openTab("订阅")
        tap(app.buttons["添加订阅"])
        type("25", into: app.textFields["金额"])
        type("UITest会员", into: app.textFields["商户"])
        XCTAssertTrue(text(containing: "保存后立即记录").exists, "首次扣费默认今天，应提示立即记账")
        save()
        XCTAssertTrue(app.staticTexts["UITest会员"].firstMatch.waitForExistence(timeout: 5), "新订阅应出现在列表中")

        // 首次扣费日为今天：账单页应出现这笔扣费。
        openTab("账单")
        showAllRecords()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["UITest会员"].firstMatch), "今天的首期扣费应已入账")
    }

    func testCreateAssetAndUpdateValuation() {
        openTab("资产")
        tap(app.buttons["添加资产"])
        type("UITest银行", into: app.textFields["名称"])
        type("1000", into: app.textFields["当前金额"])
        save()

        let row = app.staticTexts["UITest银行"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "新资产应出现在列表中")
        row.tap()

        let update = app.buttons["更新估值"]
        scrollTo(update)
        update.tap()
        XCTAssertTrue(app.navigationBars["更新估值"].waitForExistence(timeout: 5))
        replace(app.textFields["当前金额"], with: "2500")
        save()
        XCTAssertTrue(text(containing: "2,500").waitForExistence(timeout: 5), "资产详情应显示新的估值")
    }

    func testInvalidAmountKeepsFormOpenWithError() {
        openTab("账单")
        tap(app.buttons["添加账单"])
        type("0", into: app.textFields["金额"])
        save()
        XCTAssertTrue(text(containing: "金额必须是大于 0").waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["添加账单"].exists, "校验失败时表单应保持打开")
    }

    func testSettingsOffersHotmailConnectionWhenClientIDIsConfigured() {
        tap(app.buttons["设置"])
        let connect = app.buttons["连接 Hotmail"]
        XCTAssertTrue(scrollUntilVisible(connect), "已配置 Client ID 时应提供连接按钮")
        XCTAssertFalse(text(containing: "未配置微软应用 ID").exists)

        let icloud = app.buttons["连接 iCloud 邮箱"]
        XCTAssertTrue(scrollUntilVisible(icloud), "应提供 iCloud 邮箱连接")
        icloud.tap()
        XCTAssertTrue(app.textFields["icloud.address"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["icloud.password"].exists)
        let sheetBar = app.navigationBars["连接 iCloud 邮箱"]
        XCTAssertFalse(sheetBar.buttons["连接"].isEnabled, "未填写时不能连接")
        tap(sheetBar.buttons["取消"])

        let range = app.steppers["mailbox.lookbackMonths"]
        XCTAssertTrue(scrollUntilVisible(range), "应可调整同步范围")
        XCTAssertTrue(text(containing: "最近 3 个月").exists, "默认同步最近 3 个月")
        range.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(text(containing: "最近 4 个月").waitForExistence(timeout: 2))
    }

    // MARK: Helpers

    private func openTab(_ title: String) {
        tap(app.tabBars.buttons[title])
    }

    private func showAllRecords() {
        let all = app.buttons["全部明细"]
        if all.waitForExistence(timeout: 3) { all.tap() }
    }

    private func save() {
        tap(app.navigationBars.buttons["保存"])
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "找不到 \(element)", file: file, line: line)
        element.tap()
    }

    private func type(_ value: String, into field: XCUIElement) {
        tap(field)
        field.typeText(value)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        // 金额右对齐：点最右侧让光标落在末尾，退格才能删掉原值。
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(value)
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// 列表懒加载：屏幕外的行不在无障碍树里，需要滚动后才能找到。
    private func scrollUntilVisible(_ element: XCUIElement) -> Bool {
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1.5), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func scrollTo(_ element: XCUIElement) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }
}
