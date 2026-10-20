import XCTest

/// The interface follows the language chosen in the app, or the iOS language
/// when "System" is selected, and switches in place from Settings.
final class LocalizationUITests: XCTestCase {
    private static let languageKey = "MotoGPS.AppLanguage.v1"

    /// The home title, a demo row and the settings row, so the navigation
    /// bar, the list and the settings section are all covered.
    private static let expectations: [String: [String]] = [
        "en": ["Ride", "Demo navigation", "Language"],
        "pt-BR": ["Rodar", "Navegação de demonstração", "Idioma"],
        "zh-Hans": ["出发", "演示导航", "语言"],
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEveryLanguageChosenInTheAppTranslatesTheHomeScreen() throws {
        for (language, texts) in Self.expectations {
            let app = XCUIApplication()
            app.launchArguments = ["--moto-ui-offline", "-\(Self.languageKey)", language]
            app.launch()
            assertHome(app, shows: texts, language: language)
            app.terminate()
        }
    }

    func testSystemLanguageIsUsedWhenTheAppFollowsTheSystem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--moto-ui-offline", "-\(Self.languageKey)", "system",
                               "-AppleLanguages", "(pt-BR)"]
        app.launch()
        assertHome(app, shows: Self.expectations["pt-BR"]!, language: "system pt-BR")
    }

    /// The choice applies at once and the open settings sheet is redrawn in
    /// place; rebuilding the interface would close it.
    func testLanguageSwitchesInPlaceFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--moto-ui-offline", "-AppleLanguages", "(en)"]
        app.launch()
        let settings = app.buttons["language-settings-button"]
        scrollUntilHittable(settings, in: app)
        settings.tap()
        for language in ["zh-Hans", "en", "pt-BR"] {
            let option = app.buttons["language-option-\(language)"]
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            let title = Self.expectations[language]![2]
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3),
                          "switched to \(language): settings sheet closed or not redrawn")
            XCTAssertTrue(option.isSelected, "switched to \(language): option not selected")
        }
        app.buttons["language-settings-done"].tap()
        assertHome(app, shows: Self.expectations["pt-BR"]!, language: "switched to pt-BR")
        // Leave the simulator following the system language.
        scrollUntilHittable(settings, in: app)
        settings.tap()
        app.buttons["language-option-system"].tap()
        app.buttons["language-settings-done"].tap()
    }

    /// The settings rows sit below the fold; List creates them only once
    /// scrolled into view.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0 ..< 6 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element) not reachable", file: file, line: line)
    }

    private func assertHome(_ app: XCUIApplication, shows texts: [String], language: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars[texts[0]].waitForExistence(timeout: 5),
                      "\(language): title \(texts[0]) missing", file: file, line: line)
        for text in texts.dropFirst() {
            let element = app.staticTexts[text]
            if !element.exists { app.swipeUp() }
            XCTAssertTrue(element.waitForExistence(timeout: 3),
                          "\(language): \(text) missing", file: file, line: line)
        }
        app.swipeDown()
    }
}
