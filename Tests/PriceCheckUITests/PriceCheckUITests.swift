import XCTest

final class PriceCheckUITests: XCTestCase {
    @MainActor func testFullAppNavigationAndPriceShortcut() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "app"
        app.launch()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Check price"].exists)
        capture(app, named: "Full app shopping list")
        app.buttons["list-check-price"].tap()
        XCTAssertTrue(app.staticTexts["Good price?\nLet’s find out."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["List"].isHittable)
        capture(app, named: "Full app price check welcome")
        let input = app.descendants(matching: .any)["price-check-input"].firstMatch
        input.tap()
        input.typeText("Red Bull 4 x 250mL for $9.83")
        app.buttons["price-check-send"].tap()
        XCTAssertTrue(app.staticTexts["26% above your average."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Insights"].isHittable)
        capture(app, named: "Full app price comparison")
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.buttons["insights-products"].waitForExistence(timeout: 10))
        capture(app, named: "Full app insights")
        app.buttons["insights-products"].tap()
        XCTAssertTrue(app.navigationBars["Products"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Red Bull Energy Drink"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.isHittable)
        capture(app, named: "Full app products")
        app.staticTexts["Red Bull Energy Drink"].tap()
        XCTAssertTrue(app.staticTexts["Purchases"].waitForExistence(timeout: 5))
        capture(app, named: "Full app product history")
        app.tabBars.buttons["Forecast"].tap()
        XCTAssertTrue(app.staticTexts["Estimated next shop"].waitForExistence(timeout: 10))
        capture(app, named: "Full app forecast")
        app.tabBars.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture(app, named: "Full app settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Check price"].isHittable)
    }

    @MainActor func testReceiptStreamReachesReview() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "receipt"
        app.launch()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Couldn't find any items on that receipt."].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testPriceConversationSwitchingAndFollowUp() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price"
        app.launch()
        let input = app.descendants(matching: .any)["price-check-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        capture(app, named: "Price check welcome")
        input.tap()
        input.typeText("Is Red Bull 4 x 250mL for $9.83 a good price?")
        app.buttons["price-check-send"].tap()
        let result = app.staticTexts["26% above your average."]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A bit steep."].exists)
        XCTAssertFalse(app.staticTexts["Compare another product"].exists)
        capture(app, named: "Red Bull pack comparison")
        app.buttons["Per 100 mL"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "$0.98")).firstMatch.exists)
        capture(app, named: "Red Bull unit comparison")
        app.buttons["price-check-change-product"].tap()
        XCTAssertTrue(app.navigationBars["Choose product"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Milk"].waitForExistence(timeout: 5))
        capture(app, named: "Change product sheet")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Red Bull Energy Drink")).firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("What about $7?")
        app.buttons["price-check-send"].tap()
        XCTAssertTrue(app.staticTexts["Good price."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["10% below your average."].exists)
        XCTAssertTrue(app.staticTexts["What about $7?"].exists)
        // The first answer remains part of the conversation.
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["A bit steep."].exists)
    }

    @MainActor func testLargeTextPriceCheck() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let input = app.descendants(matching: .any)["price-check-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Red Bull 4 x 250mL for $9.83")
        app.buttons["price-check-send"].tap()
        XCTAssertTrue(app.staticTexts["A bit steep."].waitForExistence(timeout: 10))
        app.swipeUp()
        capture(app, named: "Price check large text")
        XCTAssertTrue(app.buttons["price-check-send"].exists)
    }

    @MainActor private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testProductSearchFiltersPurchases() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "products"
        app.launch()
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Red Bull")
        XCTAssertTrue(app.staticTexts["Red Bull Energy Drink"].exists)
        XCTAssertTrue(app.staticTexts["Milk"].waitForNonExistence(timeout: 5))
    }
}
