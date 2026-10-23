import XCTest

final class PriceCheckUITests: XCTestCase {
    @MainActor func testReceiptStreamReachesReview() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "receipt"
        app.launch()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Couldn't find any items on that receipt."].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testQuestionToComparisonAndHistory() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price"
        app.launch()
        let input = app.descendants(matching: .any)["price-check-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Is Red Bull 4 x 250mL for $9.83 a good price?")
        app.buttons["price-check-send"].tap()
        let search = app.textFields["price-check-product-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.swipeUp()
        let product = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Red Bull Energy Drink")).firstMatch
        XCTAssertTrue(product.waitForExistence(timeout: 5))
        product.tap()
        let result = app.staticTexts["26% more than last time"]
        if !result.isHittable { app.swipeDown() }
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["$0.98"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Red Bull price comparison"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
