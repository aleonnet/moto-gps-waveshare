import XCTest
import UIKit
import CoreLocation

final class MotoGPSUITests: XCTestCase {
    private var previousLocation: XCUILocation?

    func testLiveShanghaiCitySearchShowsDownloadCoverage() throws {
        let app = launchApp()
        let maps = app.buttons["map-downloads-button"]
        XCTAssertTrue(maps.waitForExistence(timeout: 5))
        if !maps.isHittable { app.swipeUp() }
        maps.tap()
        app.buttons["map-download-city"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("上海")
        let city = app.buttons["map-city-result-310000"]
        XCTAssertTrue(city.waitForExistence(timeout: 25))
        city.tap()
        XCTAssertTrue(app.buttons["map-city-start-download"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["map-city-start-download"].isEnabled)
        keepScreenshot(of: app, named: "MOTO GPS Shanghai offline coverage")
    }

    func testMapDownloadsExposeCitySearchAndReturnHome() throws {
        let app = launchApp()
        let maps = app.buttons["map-downloads-button"]
        XCTAssertTrue(maps.waitForExistence(timeout: 5))
        if !maps.isHittable { app.swipeUp() }
        maps.tap()
        XCTAssertTrue(app.descendants(matching: .any)["map-downloads-sheet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["map-autoload-title"].exists)
        keepScreenshot(of: app, named: "MOTO GPS map downloads")
        app.buttons["map-download-city"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["map-city-empty"].exists)
        try tapSystemBack(in: app)
        app.buttons["map-downloads-done"].tap()
        XCTAssertTrue(app.textFields["destination-search-field"].waitForExistence(timeout: 3))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        previousLocation = XCUIDevice.shared.location
        refreshTestLocation()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.location = previousLocation
    }

    /// Every test talks to the offline test gateway (recorded answers on
    /// localhost:8787), started by scripts/ios/run-ui-tests-with-test-gateway.sh.
    private func launchApp(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--moto-test-gateway"] + arguments
        app.launch()
        return app
    }

    private func refreshTestLocation(latitude: Double = 36.6748039, longitude: Double = 117.1224488) {
        // Keep test location fresh across launches and appearance changes.
        // Production correctly rejects a cached fix older than 15 seconds.
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: Date()
        ))
    }

    func testDeviceDetailsPreserveDestinationSearch() throws {
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let query = "奥体中心"
        search.typeText(query)

        let detailsButton = app.buttons["device-details-button"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 3))
        detailsButton.tap()

        let sheet = app.descendants(matching: .any)["device-details-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        keepScreenshot(of: app, named: "MOTO GPS device details")

        // Device availability varies on the simulator. Inspecting the sheet
        // must preserve the search independently of its current BLE state.
        let done = app.buttons["device-details-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: sheet
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, query)
        XCTAssertFalse(app.descendants(matching: .any)["route-preview-map"].exists)
    }

    func testNativeHomeLightVisualState() throws {
        try captureHomeVisualState(
            appearance: .light,
            name: "MOTO GPS native home — light"
        )
    }

    func testNativeHomeDarkVisualState() throws {
        try captureHomeVisualState(
            appearance: .dark,
            name: "MOTO GPS native home — dark"
        )
    }

    func testNativeHomeAccessibilityXXXLVisualState() throws {
        try captureHomeVisualState(
            appearance: .light,
            arguments: [
                "-UIPreferredContentSizeCategoryName",
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            ],
            name: "MOTO GPS native home — Accessibility XXXL"
        )
    }

    func testNearbyDestinationCanBeSelectedAndReturnsToRecentSearches() throws {
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("奥体中心")

        let firstResult = app.buttons["place-result-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15))
        refreshTestLocation()
        firstResult.tap()

        let preview = app.descendants(matching: .any)["route-preview-map"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["route-option-0"].exists)

        let start = app.buttons["primary-navigation-action"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)

        try tapSystemBack(in: app)
        XCTAssertTrue(app.staticTexts["recent-places-header"].waitForExistence(timeout: 3))
    }

    func testSelectedRouteStartsNavigationAndEndsAtHome() throws {
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("奥体中心")

        let firstResult = app.buttons["place-result-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20))
        refreshTestLocation()
        firstResult.tap()

        let preview = app.descendants(matching: .any)["route-preview-map"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["route-option-0"].exists)
        XCTAssertFalse(app.buttons["end-navigation-action"].exists)

        // Explicitly start the real selected route. Selecting a search result
        // alone must remain a preview, including when no round screen is paired.
        let start = app.buttons["primary-navigation-action"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        refreshTestLocation()
        start.tap()

        let navigationScreen = app.descendants(matching: .any)["active-navigation-screen"]
        XCTAssertTrue(navigationScreen.waitForExistence(timeout: 15))
        let end = app.buttons["end-navigation-action"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(end.isEnabled)
        keepScreenshot(of: app, named: "MOTO GPS native navigation — selected destination")
        end.tap()

        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.staticTexts["recent-places-header"].exists)
        XCTAssertFalse(end.exists)
        XCTAssertFalse(navigationScreen.exists)
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(app.buttons["route-option-0"].exists)
    }

    func testRoutePreviewSwipeRightReturnsToSearch() throws {
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("奥体中心")

        let firstResult = app.buttons["place-result-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20))
        refreshTestLocation()
        firstResult.tap()

        // Wait for the pushed preview screen (start action is enough; map tiles
        // are slower and not required to prove navigation-stack back works).
        let start = app.buttons["primary-navigation-action"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))

        // Standard iOS edge swipe-back: left edge → right, below the route map
        // (about 30-63% of the height), which would take the drag as a pan.
        // A short hold lets the edge gesture claim the touch before the list does.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.75))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)

        XCTAssertTrue(app.staticTexts["recent-places-header"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["destination-search-field"].exists)
        // Preview-only content must disappear when returning to search.
        XCTAssertFalse(app.descendants(matching: .any)["route-preview-map"].exists)
        XCTAssertFalse(app.buttons["route-option-0"].exists)
    }

    func testRoutePreviewSystemBackReturnsToSearch() throws {
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("奥体中心")

        let firstResult = app.buttons["place-result-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20))
        refreshTestLocation()
        firstResult.tap()

        let start = app.buttons["primary-navigation-action"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))

        try tapSystemBack(in: app)
        XCTAssertTrue(app.staticTexts["recent-places-header"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["destination-search-field"].exists)
    }

    func testBuiltInNavigationDemoStarts() throws {
        let app = launchApp()

        let demo = app.buttons["demo-navigation-button"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()

        // Demo may briefly show acquiring/planning before navigating.
        let end = app.buttons["end-navigation-action"]
        XCTAssertTrue(end.waitForExistence(timeout: 15))
        XCTAssertTrue(end.isEnabled)
        keepScreenshot(of: app, named: "MOTO GPS native navigation — demo")
    }

    func testEndingDemoNavigationReturnsToHome() throws {
        let app = launchApp()

        let demo = app.buttons["demo-navigation-button"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()

        let end = app.buttons["end-navigation-action"]
        XCTAssertTrue(end.waitForExistence(timeout: 15))
        end.tap()

        // Ending navigation must clear the stuck route-preview state and
        // bring the rider back to the destination-search home screen.
        XCTAssertTrue(app.textFields["destination-search-field"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["demo-navigation-button"].exists)
        XCTAssertFalse(end.exists)
    }

    /// Outside mainland China the gateway answers through Geoapify; the
    /// recorded Sao Paulo search and motorcycle route reach the same preview.
    func testSaoPauloDestinationPlansARouteOutsideChina() throws {
        refreshTestLocation(latitude: -23.5505, longitude: -46.6333)
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Ibirapuera")

        let firstResult = app.buttons["place-result-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15))
        refreshTestLocation(latitude: -23.5505, longitude: -46.6333)
        firstResult.tap()

        XCTAssertTrue(app.descendants(matching: .any)["route-preview-map"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["route-option-0"].exists)
        XCTAssertFalse(app.buttons["route-option-1"].exists, "Geoapify plans one honest candidate")
        let start = app.buttons["primary-navigation-action"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        keepScreenshot(of: app, named: "MOTO GPS route preview — Sao Paulo via Geoapify")
    }

    /// A simulation is chosen on purpose, starts where the rider says and
    /// rides the planned route with simulated GPS.
    func testRouteSimulationStartsFromTheChosenStart() throws {
        refreshTestLocation(latitude: -23.5505, longitude: -46.6333)
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Ibirapuera")
        let destination = app.buttons["place-result-0"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        destination.tap()

        let mode = app.segmentedControls["navigation-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.buttons.element(boundBy: 0).isSelected, "a new destination starts in real navigation")
        mode.buttons.element(boundBy: 1).tap()

        let start = app.buttons["primary-navigation-action"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        let fromHere = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [fromHere], timeout: 15), .completed,
                       "the simulation starts from the current location without typing")
        app.buttons["simulation-origin-button"].tap()
        XCTAssertTrue(app.buttons["simulation-origin-current"].waitForExistence(timeout: 3))
        let originField = app.searchFields.firstMatch
        XCTAssertTrue(originField.waitForExistence(timeout: 3))
        originField.tap()
        originField.typeText("Ibirapuera")
        let origin = app.buttons["simulation-origin-result-1"]
        XCTAssertTrue(origin.waitForExistence(timeout: 15))
        origin.tap()

        XCTAssertTrue(app.descendants(matching: .any)["route-preview-map"].waitForExistence(timeout: 20))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        keepScreenshot(of: app, named: "MOTO GPS route simulation — ready")
        start.tap()

        XCTAssertTrue(app.descendants(matching: .any)["active-navigation-screen"].waitForExistence(timeout: 15))
        let notice = app.descendants(matching: .any)["simulation-notice"]
        for _ in 0 ..< 4 where !notice.exists { app.swipeUp() }
        XCTAssertTrue(notice.exists, "the active screen says the ride is simulated")
        keepScreenshot(of: app, named: "MOTO GPS route simulation — riding")
        app.buttons["end-navigation-action"].tap()
        XCTAssertTrue(app.textFields["destination-search-field"].waitForExistence(timeout: 5))
    }

    /// The rider switches the round display between the street scale and
    /// twice the distance; the second tap restores the first scale.
    func testMapZoomToggleSwitchesAndRestoresTheRoundDisplayScale() throws {
        let app = launchApp()
        let demo = app.buttons["demo-navigation-button"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()
        XCTAssertTrue(app.buttons["end-navigation-action"].waitForExistence(timeout: 15))

        let toggle = app.buttons["map-zoom-toggle"]
        for _ in 0 ..< 4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        let initial = toggle.value as? String
        toggle.tap()
        let switched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initial ?? ""), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 3), .completed)
        keepScreenshot(of: app, named: "MOTO GPS round display zoom switched")
        toggle.tap()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initial ?? ""), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
    }

    /// Keeps a real route-preview screenshot in the test result so layout
    /// regressions are reviewable without changing the app's runtime behavior.
    func testRoutePreviewVisualState() throws {
        let app = launchApp()

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("奥体中心")

        let firstResult = app.buttons["place-result-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15))
        refreshTestLocation()
        firstResult.tap()

        let preview = app.descendants(matching: .any)["route-preview-map"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["route-option-0"].waitForExistence(timeout: 3))
        sleep(3) // Let MapKit finish its tile and camera transition.

        keepScreenshot(of: app, named: "MOTO GPS route preview — overview")

        app.swipeUp()
        sleep(1)
        keepScreenshot(of: app, named: "MOTO GPS route preview — choices")

        if app.buttons["route-option-1"].exists {
            app.buttons["route-option-1"].tap()
            sleep(1)
            keepScreenshot(of: app, named: "MOTO GPS route preview — alternate selected")
        }
    }

    private func captureHomeVisualState(
        appearance: XCUIDevice.Appearance,
        arguments: [String] = [],
        name: String
    ) throws {
        let device = XCUIDevice.shared
        let previousAppearance = device.appearance
        device.appearance = appearance
        defer { device.appearance = previousAppearance }

        let app = launchApp(arguments)
        // XCTest may reset appearance while it launches the application.
        // Apply it to the live scene as well, then capture the rendered result.
        device.appearance = appearance
        XCTAssertEqual(device.appearance, appearance)

        let search = app.textFields["destination-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        keepScreenshot(of: app, named: name)

        // Keep the device controls reachable in every appearance/text-size
        // variant without asserting any particular Bluetooth state.
        let detailsButton = app.buttons["device-details-button"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 3))
        XCTAssertTrue(detailsButton.isHittable)
        detailsButton.tap()

        let sheet = app.descendants(matching: .any)["device-details-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        keepScreenshot(of: app, named: "\(name) — device details")

        let done = app.buttons["device-details-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        XCTAssertTrue(done.isHittable)
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: sheet
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(search.isHittable)
    }

    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapSystemBack(in app: XCUIApplication) throws {
        // Use the topmost bar: under a sheet, the first bar in the tree is the
        // home screen's, whose first button (gateway settings) is covered.
        let bars = app.navigationBars.allElementsBoundByIndex
        let backButton = (bars.last ?? app.navigationBars.firstMatch).buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 2), backButton.isHittable {
            backButton.tap()
            return
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
