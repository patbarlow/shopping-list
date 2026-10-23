import XCTest

final class PriceCheckUITests: XCTestCase {
    @MainActor func testFullAppNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "app"
        app.launch()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Check price"].exists)
        XCTAssertFalse(app.navigationBars.staticTexts["Your list"].exists)
        XCTAssertFalse(app.buttons["list-check-price"].exists)
        capture(app, named: "Full app shopping list")
        app.buttons["list-section-Fruit & Veg"].tap()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForNonExistence(timeout: 5))
        app.buttons["list-section-Fruit & Veg"].tap()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Check price"].tap()
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

    @MainActor func testEmptyListAppearsAfterLoadingAndSurvivesTabSwitch() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "list-empty"
        app.launch()
        XCTAssertTrue(app.staticTexts["A fresh start."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.progressIndicators["list-loading"].exists)
        capture(app, named: "Empty list after initial load")
        app.tabBars.buttons["Check price"].tap()
        XCTAssertTrue(app.staticTexts["Good price?\nLet’s find out."].waitForExistence(timeout: 5))
        app.tabBars.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts["A fresh start."].waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["A fresh start."].exists)
    }

    @MainActor func testListLoadErrorCanRetryIntoEmptyState() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "list-error"
        app.launch()
        XCTAssertTrue(app.staticTexts["Couldn't load your list"].waitForExistence(timeout: 10))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["A fresh start."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Try again"].exists)
    }

    @MainActor func testAllCheckedItemsShowEmptyState() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "list-checked"
        app.launch()
        XCTAssertTrue(app.staticTexts["A fresh start."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Milk"].exists)
    }

    @MainActor func testSwipeDownOnBothComposersDismissesKeyboard() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "list-empty"
        app.launch()
        XCTAssertTrue(app.staticTexts["A fresh start."].waitForExistence(timeout: 10))
        app.staticTexts["Add item…"].tap()
        let listInput = app.descendants(matching: .any)["list-add-input"].firstMatch
        XCTAssertTrue(listInput.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        swipeComposerDown(listInput)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Check price"].tap()
        let priceInput = app.descendants(matching: .any)["price-check-input"].firstMatch
        priceInput.tap()
        priceInput.typeText("Red Bull")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        swipeComposerDown(priceInput)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(priceInput.value as? String, "Red Bull")
    }

    @MainActor func testCompactPhotosAndCameraFromChatAndReceipt() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "app"
        app.launch()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Check price"].tap()
        app.buttons["Photos"].tap()
        let expand = app.buttons["photos-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let close = app.buttons["Close photos"]
        XCTAssertTrue(close.isHittable)
        waitForPhotoGrid(app)
        capture(app, named: "Compact photo picker")
        expand.tap()
        XCTAssertTrue(app.buttons["Recents"].waitForExistence(timeout: 5))
        capture(app, named: "Expanded photo picker")
        close.tap()
        app.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["camera-shutter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close camera"].isHittable)
        capture(app, named: "Compact camera simulator fallback")
        app.buttons["Close camera"].tap()
        app.tabBars.buttons["List"].tap()
        app.buttons["Import receipt"].tap()
        app.buttons["Photo Library"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.buttons["Import receipt"].tap()
        if !app.buttons["Scan Receipt"].waitForExistence(timeout: 2) {
            app.buttons["Import receipt"].tap()
        }
        app.buttons["Scan Receipt"].tap()
        XCTAssertTrue(app.buttons["camera-shutter"].waitForExistence(timeout: 5))
        app.buttons["Close camera"].tap()
        XCTAssertTrue(app.staticTexts["Bananas"].isHittable)
    }

    @MainActor func testPhotoSelectionAttachesAndOpensReceiptReview() {
        // The QA simulator contains the supplied Red Bull screenshot (simctl addmedia).
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "app"
        app.launch()
        XCTAssertTrue(app.staticTexts["Bananas"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Check price"].tap()
        app.buttons["Photos"].tap()
        waitForPhotoGrid(app)
        app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 10))
        capture(app, named: "Photo attached to price check")
        app.buttons["Remove photo"].tap()
        swipeComposerDown(app.descendants(matching: .any)["price-check-input"].firstMatch)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Insights"].tap()
        app.buttons["Import receipt"].tap()
        app.buttons["Photo Library"].tap()
        waitForPhotoGrid(app)
        app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        capture(app, named: "Photo receipt review from Insights")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["insights-products"].waitForExistence(timeout: 5))
    }

    @MainActor func testReturnAddsSuccessiveItemsAndKeepsKeyboardOpen() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "list-empty"
        app.launch()
        XCTAssertTrue(app.staticTexts["A fresh start."].waitForExistence(timeout: 10))
        app.staticTexts["Add item…"].tap()
        let input = app.textFields["list-add-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Apples\n")
        XCTAssertTrue(app.staticTexts["Apples"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        input.typeText("Coffee\n")
        XCTAssertTrue(app.staticTexts["Coffee"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apples"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(input.value as? String, "Items, separated by commas")
        capture(app, named: "Two items added with Return and keyboard retained")
    }

    @MainActor func testLargeAttachmentMenuAndImageOnlyPriceCheck() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price"
        app.launch()
        let plus = app.buttons["price-check-attachments"]
        let plusFrame = plus.frame
        plus.tap()
        let menu = app.descendants(matching: .any)["price-check-attachment-menu"].firstMatch
        let photos = menu.buttons["Photos"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(photos.frame.height, 64)
        XCTAssertTrue(menu.frame.intersects(plusFrame))
        XCTAssertTrue(app.popovers.firstMatch.exists)
        capture(app, named: "Larger attachment menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.25)).tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        app.descendants(matching: .any)["price-check-input"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let keyboardPlusFrame = plus.frame
        plus.tap()
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.frame.intersects(keyboardPlusFrame))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, named: "Attachment menu overlapping plus above keyboard")
        photos.tap()
        waitForPhotoGrid(app)
        app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Good price?\nLet’s find out."].exists)
        capture(app, named: "Attached photo with focused composer")
        app.buttons["price-check-send"].tap()
        XCTAssertTrue(app.staticTexts["26% above your average."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Couldn't check just now. Try again in a moment."].exists)
        capture(app, named: "Image-only price check reply")
    }

    @MainActor func testCompactPhotoGridScrollDoesNotExpandAndCameraOptions() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price"
        app.launch()
        app.buttons["Photos"].tap()
        waitForPhotoGrid(app)
        let close = app.buttons["Close photos"]
        let grid = app.otherElements["photo-grid"].firstMatch
        let gridBefore = grid.frame
        let firstImage = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        let topBefore = firstImage.frame.minY
        let firstLabel = firstImage.label
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: close.frame.minY - 35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)))
        XCTAssertTrue(app.buttons["All Photos"].exists)
        XCTAssertFalse(app.buttons["Recents"].exists)
        XCTAssertGreaterThan(grid.frame.minY, 250)
        XCTAssertEqual(grid.frame.minY, gridBefore.minY, accuracy: 2)
        XCTAssertEqual(grid.frame.height, gridBefore.height, accuracy: 2)
        XCTAssertTrue(firstImage.label != firstLabel || abs(firstImage.frame.minY - topBefore) > 10)
        capture(app, named: "Scrolled compact photo grid")
        app.buttons["All Photos"].tap()
        XCTAssertTrue(app.buttons["Recents"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.buttons["Camera"].tap()
        app.buttons["Camera options"].tap()
        XCTAssertTrue(app.buttons["Switch camera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Flash: off"].exists)
        app.buttons["Scan receipt"].tap()
        XCTAssertTrue(app.staticTexts["camera-scan-mode"].exists)
        capture(app, named: "Shared camera with scan mode and expanded controls")
        app.buttons["Close camera"].tap()
    }

    @MainActor func testRecentPhotoDismissesOnTypingAndStaysDismissed() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price-recent"
        app.launch()
        let recent = app.buttons["Attach recent photo"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Hide recent photo"].exists)
        let input = app.descendants(matching: .any)["price-check-input"].firstMatch
        input.tap()
        input.typeText("Milk")
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5))
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        swipeComposerDown(input)
        XCTAssertTrue(app.staticTexts["Good price?\nLet’s find out."].waitForExistence(timeout: 5))
        XCTAssertFalse(recent.exists)
    }

    @MainActor func testFailedImageCheckPreservesAttachmentAndExplainsRetry() {
        let app = XCUIApplication()
        app.launchEnvironment["TROLLEY_UI_TEST"] = "price-error"
        app.launch()
        app.buttons["Photos"].tap()
        waitForPhotoGrid(app)
        app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Remove photo"].waitForExistence(timeout: 10))
        app.buttons["price-check-send"].tap()
        XCTAssertTrue(app.staticTexts["The price reader is unavailable just now. Your photo is ready to retry."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Remove photo"].exists)
        XCTAssertTrue(app.buttons["price-check-send"].isEnabled)
        XCTAssertFalse(app.staticTexts["Good price?\nLet’s find out."].exists)
    }

    @MainActor private func waitForPhotoGrid(_ app: XCUIApplication) {
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15))
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
    }

    @MainActor private func swipeComposerDown(_ input: XCUIElement) {
        let start = input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 110)))
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
