import Observation
import XCTest
@testable import MOTO_GPS

final class AppLocalizationTests: XCTestCase {
    private var localization: AppLocalization!

    override func setUp() {
        let defaults = UserDefaults(suiteName: "AppLocalizationTests")!
        defaults.removePersistentDomain(forName: "AppLocalizationTests")
        localization = AppLocalization(defaults: defaults)
    }

    func testSelectedLanguageResolvesFromItsOwnLocalization() {
        localization.select(.portuguese)
        XCTAssertEqual(localization.string("Done"), "Concluído")
        XCTAssertEqual(localization.deviceLanguageTag, "pt-BR")
        localization.select(.chinese)
        XCTAssertEqual(localization.string("Done"), "完成")
        XCTAssertEqual(localization.deviceLanguageTag, "zh-Hans")
        localization.select(.english)
        XCTAssertEqual(localization.string("Done"), "Done")
        XCTAssertEqual(localization.deviceLanguageTag, "en-US")
    }

    func testParametersKeepTheirPlaceInEveryLanguage() {
        let name = "Jinan"
        localization.select(.portuguese)
        XCTAssertEqual(localization.string("Route overview to \(name)"), "Visão geral da rota até Jinan")
        localization.select(.chinese)
        XCTAssertEqual(localization.string("Route overview to \(name)"), "前往Jinan的路线全览")
        let percent = 42
        XCTAssertEqual(localization.string("\("1 MB") downloaded · \(percent)%"), "已下载 1 MB · 42%")
    }

    /// SwiftUI redraws a view when a property its body read changes; reading
    /// text must therefore register the language, also through L() called
    /// from a model property.
    func testReadingTextTracksTheLanguage() {
        let direct = expectation(description: "string() tracked")
        withObservationTracking { _ = localization.string("Done") } onChange: { direct.fulfill() }
        localization.select(.portuguese)
        wait(for: [direct], timeout: 0)

        AppLocalization.shared.select(.english)
        defer { AppLocalization.shared.select(.system) }
        let nested = expectation(description: "L() inside a model property tracked")
        withObservationTracking { _ = MapPackLabel.route(destination: nil).title } onChange: { nested.fulfill() }
        AppLocalization.shared.select(.chinese)
        wait(for: [nested], timeout: 0)
    }

    func testStoredMessagesAreTranslatedWhenShown() {
        AppLocalization.shared.select(.english)
        defer { AppLocalization.shared.select(.system) }
        let text = AppMessage.localized("Enter the service address in Gateway settings first")
        let error = AppMessage.error(LocationPermissionError.off)
        XCTAssertEqual(text.text, "Enter the service address in Gateway settings first")
        AppLocalization.shared.select(.portuguese)
        XCTAssertEqual(text.text, "Informe primeiro o endereço do serviço nos ajustes do gateway")
        XCTAssertEqual(error.text, "O acesso à localização está desligado. Permita a localização “Sempre” nos Ajustes.")
    }

    func testSystemNamesTheIOSLanguageWhateverIsSelected() {
        let system = localization.systemLocalization
        for language in [AppLanguage.english, .portuguese, .chinese] {
            localization.select(language)
            XCTAssertEqual(localization.systemLocalization, system, "System followed the choice \(language)")
        }
    }

    func testMapDownloadReasonsAreTranslatedWhenShown() {
        AppLocalization.shared.select(.english)
        defer { AppLocalization.shared.select(.system) }
        let message = MapDownloadMessage.pausedAfterError(SurroundingMapError.storageLimit)
        AppLocalization.shared.select(.portuguese)
        XCTAssertEqual(message.text, "Download pausado: Os mapas offline chegaram ao limite de 512 MB; "
            + "apague áreas que não usa mais. A parte concluída foi mantida.")
        XCTAssertEqual(MapDownloadMessage.failure(SurroundingMapError.storageLimit).text,
                       "Os mapas offline chegaram ao limite de 512 MB; apague áreas que não usa mais")
    }

    func testSelectionIsStoredAndSystemClearsIt() {
        let defaults = UserDefaults(suiteName: "AppLocalizationTests")!
        localization.select(.chinese)
        XCTAssertEqual(defaults.string(forKey: AppLocalization.defaultsKey), "zh-Hans")
        XCTAssertEqual(AppLocalization(defaults: defaults).language, .chinese)
        localization.select(.system)
        XCTAssertNil(defaults.string(forKey: AppLocalization.defaultsKey))
    }

    func testDistancesAndDurationsFollowTheLanguage() {
        let pt = Locale(identifier: "pt-BR"), en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(NavFormatting.distance(meters: 1_234, locale: pt), "1,2 km")
        XCTAssertEqual(NavFormatting.distance(meters: 1_234, locale: en), "1.2 km")
        XCTAssertEqual(NavFormatting.distance(meters: 1_234, locale: zh), "1.2公里")
        XCTAssertEqual(NavFormatting.distance(meters: 849.6, locale: pt), "850 m")
        XCTAssertEqual(NavFormatting.distance(meters: 0, locale: pt), "--")
        XCTAssertEqual(NavFormatting.duration(seconds: 13 * 60, locale: pt), "13 min")
        XCTAssertEqual(NavFormatting.duration(seconds: 13 * 60, locale: zh), "13分钟")
        XCTAssertEqual(NavFormatting.duration(seconds: 65 * 60, locale: en), "1 hr, 5 min")
        XCTAssertEqual(NavFormatting.duration(seconds: 65 * 60, locale: zh), "1小时5分钟")
        XCTAssertEqual(NavFormatting.duration(seconds: 0, locale: pt), "--")
    }

    func testSavedPacksAreDescribedInTheCurrentLanguage() {
        AppLocalization.shared.select(.portuguese)
        defer { AppLocalization.shared.select(.system) }
        XCTAssertEqual(MapPackLabel.city(name: "Jinan", scope: .district).detail, "Distrito")
        XCTAssertEqual(MapPackLabel.route(destination: "Praça").title, "Até Praça")
        AppLocalization.shared.select(.chinese)
        XCTAssertEqual(MapPackLabel.route(destination: nil).title, "前往目的地")
        // Packs saved before localization keep their stored words.
        XCTAssertEqual(MapPackLabel.legacy(name: "前往A", detail: "所选路线及沿途约一公里").detail,
                       "所选路线及沿途约一公里")
    }
}
