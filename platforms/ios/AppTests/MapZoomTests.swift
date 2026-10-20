import Foundation
import XCTest
@testable import MOTO_GPS

/// The round display shows 15 (street scale) or 14 (twice the distance). The
/// phone owns the scale: it asks for z14 tiles, sends a 1 km scene and the
/// shared MapZoom message that the ESP32 decodes with the same C++ codec.
@MainActor
final class MapZoomTests: XCTestCase {
    func testPlannerUsesZ14TilesOnlyWhenAsked() throws {
        let street = try MapTilePlanner.aroundGCJ02(latitudeDeg: -23.5505, longitudeDeg: -46.6333, radiusM: 500)
        let wide = try MapTilePlanner.aroundGCJ02(latitudeDeg: -23.5505, longitudeDeg: -46.6333,
                                                  radiusM: 1_000, zoom: 14)
        XCTAssertTrue(street.allSatisfy { $0.z == 15 && $0.isValid })
        XCTAssertTrue(wide.allSatisfy { $0.z == 14 && $0.isValid })
        XCTAssertTrue(wide.contains(MapTileID(z: 14, x: 6069, y: 9295)))
        XCTAssertLessThanOrEqual(wide.count, 9)
        XCTAssertFalse(MapTileID(z: 13, x: 1, y: 1).isValid)
        XCTAssertFalse(MapTileID(z: 14, x: 16_384, y: 0).isValid)
    }

    func testZoomedOutSurroundingsUseZ14TilesAndAOneKilometreScene() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moto-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The first wide scene comes from the empty cache before any download,
        // so wait for the z14 request itself.
        let z14Requested = expectation(description: "A z14 tile requested")
        z14Requested.assertForOverFulfill = false
        let store = SurroundingMapStore(baseURL: URL(string: "https://example.invalid/")!, storageURL: root,
                                        loader: { tile in
            XCTAssertTrue(tile.z == 14 || tile.z == 15)
            if tile.z == 14 { z14Requested.fulfill() }
            return try JSONEncoder().encode(MapTileDocument(
                schemaVersion: 1, coordinateSystem: "GCJ-02", tile: tile, roads: [], buildings: [],
                source: OfflineMapSource(provider: "test-fixture", licence: "ODbL-1.0",
                                         attributionURL: "https://www.openstreetmap.org/copyright",
                                         retrievedAt: "2026-10-20", bboxWGS84: nil)))
        })
        var radii: [UInt16] = []
        let wideScene = expectation(description: "A scene at the zoomed-out radius")
        wideScene.assertForOverFulfill = false  // Cached, then downloaded.
        store.onScene = { scene in
            radii.append(scene.radiusM)
            if scene.radiusM == 1_000 { wideScene.fulfill() }
        }
        store.update(latitudeDeg: -23.5505, longitudeDeg: -46.6333)
        // The switch rebuilds the surroundings from the last position at once.
        store.setZoomLevel(14)
        await fulfillment(of: [wideScene, z14Requested], timeout: 3)
        XCTAssertEqual(store.zoomLevel, 14)
        XCTAssertTrue(radii.allSatisfy { $0 == 500 || $0 == 1_000 })
        store.reset()
    }

    func testMapZoomPayloadMatchesTheGoldenFixtureAndRejectsOtherLevels() throws {
        let url = try XCTUnwrap(Bundle(for: AppModel.self).url(
            forResource: "ble-navigation-v1.golden", withExtension: "txt"))
        let fixture = try String(contentsOf: url, encoding: .utf8)
        let expected = try XCTUnwrap(fixture.split(separator: "\n")
            .first { $0.hasPrefix("mapzoom.payload=") }?
            .split(separator: "=", maxSplits: 1).last.map(String.init))
        let codec = MotoBLEProtocolCodec(maximumFrameSize: 182)
        let payload = try codec.encodeMapZoomPayload(forTesting: 14)
        XCTAssertEqual(payload.map { String(format: "%02x", $0) }.joined(), expected)
        XCTAssertNoThrow(try codec.encodeMapZoom(15))
        XCTAssertThrowsError(try codec.encodeMapZoom(13))
    }
}

/// The bench gateway (DEBUG, plain HTTP to the Mac's .local name) must give way
/// for good once the rider saves a gateway in Settings.
final class LocalTestGatewayTests: XCTestCase {
    private let key = "MotoGPS.LocalGatewayURL.v1"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testReadingNeverStoresAndSavingSettingsForgetsTheBenchGateway() {
        UserDefaults.standard.set("http://bench-mac.local:8788/", forKey: key)
        XCTAssertEqual(AppConfiguration.localTestGatewayURL, URL(string: "http://bench-mac.local:8788/"))
        AppConfiguration.forgetLocalTestGateway()
        XCTAssertNil(AppConfiguration.localTestGatewayURL)
        XCTAssertNil(UserDefaults.standard.string(forKey: key), "reading must not write it back")
    }

    func testOnlyLocalNamesMayUsePlainHTTP() {
        for (address, allowed) in [("http://bench-mac.local:8788/", true), ("http://localhost:8787/", true),
                                   ("http://192.168.1.10:8788/", false), ("http://example.com/", false),
                                   ("https://bench-mac.local/", false)] {
            XCTAssertEqual(AppConfiguration.isLocalHTTP(URL(string: address)!), allowed, address)
        }
        UserDefaults.standard.set("http://example.com/", forKey: key)
        XCTAssertNil(AppConfiguration.localTestGatewayURL)
    }
}
