@preconcurrency import CoreBluetooth
import Foundation
import MotoNavigationCore
import XCTest
@testable import MOTO_GPS

/// Captures the city search request without a network.
private final class CitySearchRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var acceptLanguage: String?
    nonisolated(unsafe) static var answered: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("v1/map/cities") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.acceptLanguage = request.value(forHTTPHeaderField: "Accept-Language")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"cities":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
        Self.answered?.fulfill()
    }

    override func stopLoading() {}
}

/// Captures the route preview request without a network.
private final class RoutePreviewRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var request: RouteRequest?
    nonisolated(unsafe) static var answered: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("v1/route-options") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.request = try? JSONDecoder().decode(RouteRequest.self, from: request.httpBody ?? body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
        Self.answered?.fulfill()
    }

    override func stopLoading() {}
}

@MainActor
final class RouteSimulationTests: XCTestCase {
    func testSimulationPreviewPlansFromTheChosenStartNotTheGPS() async {
        URLProtocol.registerClass(RoutePreviewRecorder.self)
        defer { URLProtocol.unregisterClass(RoutePreviewRecorder.self) }
        RoutePreviewRecorder.request = nil
        RoutePreviewRecorder.answered = expectation(description: "The simulation preview asked the gateway for a route")
        let start = PlaceSearchResult(
            id: "", name: "Rua Assis Bueno, 40", address: "", city: "Rio de Janeiro", district: "Botafogo",
            displayArea: "", location: WGS84Point(longitudeDeg: -43.1840, latitudeDeg: -22.9530), distanceM: nil)
        let destination = PlaceSearchResult(
            id: "", name: "Shopping Rio Sul", address: "", city: "Rio de Janeiro", district: "Botafogo",
            displayArea: "", location: WGS84Point(longitudeDeg: -43.1770, latitudeDeg: -22.9570), distanceM: nil)
        let model = AppModel(gatewayBaseURL: URL(string: "https://gateway.test/")!)
        model.setSimulationMode(true)
        model.selectSimulationOrigin(start)
        model.selectPlace(destination)
        await fulfillment(of: [RoutePreviewRecorder.answered!], timeout: 3)
        XCTAssertEqual(RoutePreviewRecorder.request?.origin, start.location, "the preview starts where the simulation starts")
        XCTAssertEqual(RoutePreviewRecorder.request?.destination, destination.location)
    }

    func testSimulationStartsAtTheChosenStartAndRidesTheChosenRoute() async {
        // Outside the GCJ-02 rectangle the route points are plain WGS84.
        let start = WGS84Point(longitudeDeg: -43.1840, latitudeDeg: -22.9530)
        let route = RoutePlan(
            routeID: "simulated-botafogo", provider: "geoapify", generatedAtMs: 1,
            totalDistanceM: 400, totalDurationS: 60,
            polyline: [GCJ02Point(longitudeDeg: -43.1840, latitudeDeg: -22.9530),
                       GCJ02Point(longitudeDeg: -43.1840, latitudeDeg: -22.9500)],
            maneuvers: [], traffic: [])
        let session = DemoNavigationSession()
        session.install(route: route)
        let source = DemoNavigationLocationSource(session: session, origin: start)
        var fixes: [NavigationFix] = []
        let moved = expectation(description: "The simulated rider moves along the route")
        moved.assertForOverFulfill = false
        try? source.start(onFix: { fix in
            fixes.append(fix)
            if fixes.count == 10 { moved.fulfill() }
        }, onFailure: { _ in })
        await fulfillment(of: [moved], timeout: 3)
        source.stop()

        XCTAssertEqual(fixes[0].coordinate, start, "the first fix is the chosen start, not the Jinan demo")
        for fix in fixes.dropFirst() {
            XCTAssertEqual(fix.coordinate.longitudeDeg, -43.1840, accuracy: 1e-6)
            // The GCJ-02 inverse is a bisection, exact to ~1e-11°, not bit for bit.
            XCTAssertTrue((-22.9530 - 1e-6 ... -22.9500 + 1e-6).contains(fix.coordinate.latitudeDeg), "\(fix.coordinate.latitudeDeg)")
        }
        XCTAssertGreaterThan(fixes.last!.coordinate.latitudeDeg, start.latitudeDeg, "it rides north along the route")
    }

    func testCitySearchCarriesTheAppLanguage() async {
        URLProtocol.registerClass(CitySearchRecorder.self)
        defer { URLProtocol.unregisterClass(CitySearchRecorder.self) }
        CitySearchRecorder.acceptLanguage = nil
        CitySearchRecorder.answered = expectation(description: "City search reached the gateway")
        let search = MapCitySearch(baseURL: URL(string: "https://gateway.test/")!)
        search.query = "Campinas"
        search.search()
        await fulfillment(of: [CitySearchRecorder.answered!], timeout: 3)
        XCTAssertEqual(CitySearchRecorder.acceptLanguage, AppLocalization.shared.deviceLanguageTag)
    }

    func testALostPairingTellsTheRiderWhatToDo() {
        let lost = ESP32BLECentral.connectionFailureMessage(CBError(.peerRemovedPairingInformation), fallback: "fallback")
        XCTAssertEqual(lost, L("The round display no longer knows this iPhone. Forget MOTO GPS in Settings › Bluetooth; it then connects again."))
        let other = CBError(.connectionTimeout)
        XCTAssertEqual(ESP32BLECentral.connectionFailureMessage(other, fallback: "fallback"), other.localizedDescription)
        XCTAssertEqual(ESP32BLECentral.connectionFailureMessage(nil, fallback: "fallback"), "fallback")
    }
}
