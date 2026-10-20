import XCTest
@testable import MOTO_GPS

/// The phone and the ESP32 share one C++ codec; the bundled golden fixture is
/// the wire contract for the optional LocaleSelection message.
final class BLELocaleSelectionTests: XCTestCase {
    func testLocalePayloadMatchesTheGoldenFixture() throws {
        let url = try XCTUnwrap(Bundle(for: AppModel.self).url(
            forResource: "ble-navigation-v1.golden", withExtension: "txt"))
        let fixture = try String(contentsOf: url, encoding: .utf8)
        let expected = try XCTUnwrap(fixture.split(separator: "\n")
            .first { $0.hasPrefix("locale.payload=") }?
            .split(separator: "=", maxSplits: 1).last.map(String.init))
        let payload = try MotoBLEProtocolCodec(maximumFrameSize: 182)
            .encodeLocalePayload(forTesting: "pt-BR")
        XCTAssertEqual(payload.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testInvalidLanguageTagsAreRejectedBeforeSending() {
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 182)
        XCTAssertThrowsError(try codec.encodeLocaleSelection("pt_BR"))
        XCTAssertThrowsError(try codec.encodeLocaleSelection(""))
        XCTAssertNoThrow(try codec.encodeLocaleSelection("zh-Hans"))
    }
}
