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

private struct RouteOptionsReply: Encodable {
    let protocolVersion = 1
    let requestID: UInt32
    let routes: [RoutePlan]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case routes
    }
}

/// Captures the route preview request without a network and, when given a
/// route, answers with it.
private final class RoutePreviewRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var request: RouteRequest?
    nonisolated(unsafe) static var route: RoutePlan?
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
        let decoded = try? JSONDecoder().decode(RouteRequest.self, from: request.httpBody ?? body)
        Self.request = decoded
        var reply = Data()
        if let route = Self.route, let decoded {
            reply = (try? JSONEncoder().encode(RouteOptionsReply(requestID: decoded.requestID, routes: [route]))) ?? Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.isEmpty ? 503 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
        Self.answered?.fulfill()
    }

    override func stopLoading() {}
}

@MainActor
final class RouteSimulationTests: XCTestCase {
    private let start = PlaceSearchResult(
        id: "", name: "Rua Assis Bueno, 40", address: "", city: "Rio de Janeiro", district: "Botafogo",
        displayArea: "", location: WGS84Point(longitudeDeg: -43.1840, latitudeDeg: -22.9530), distanceM: nil)
    private let destination = PlaceSearchResult(
        id: "", name: "Shopping Rio Sul", address: "", city: "Rio de Janeiro", district: "Botafogo",
        displayArea: "", location: WGS84Point(longitudeDeg: -43.1840, latitudeDeg: -22.9500), distanceM: nil)
    // Outside the GCJ-02 rectangle the route points are plain WGS84.
    private let botafogoRoute = RoutePlan(
        routeID: "simulated-botafogo", provider: "geoapify", generatedAtMs: 1,
        totalDistanceM: 334, totalDurationS: 60,
        polyline: [GCJ02Point(longitudeDeg: -43.1840, latitudeDeg: -22.9530),
                   GCJ02Point(longitudeDeg: -43.1840, latitudeDeg: -22.9500)],
        maneuvers: [], traffic: [])

    override func setUp() {
        URLProtocol.registerClass(RoutePreviewRecorder.self)
        RoutePreviewRecorder.request = nil
        RoutePreviewRecorder.route = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RoutePreviewRecorder.self)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    /// The rider's order: destination, then Simulate, then the start.
    func testSimulationPreviewPlansFromTheChosenStartNotTheGPS() async {
        let model = AppModel(gatewayBaseURL: URL(string: "https://gateway.test/")!)
        model.selectPlace(destination)
        model.setSimulationMode(true)
        RoutePreviewRecorder.answered = expectation(description: "The simulation preview asked the gateway for a route")
        RoutePreviewRecorder.answered?.assertForOverFulfill = false
        model.selectSimulationOrigin(start)
        await fulfillment(of: [RoutePreviewRecorder.answered!], timeout: 3)
        XCTAssertEqual(RoutePreviewRecorder.request?.origin, start.location, "the preview starts where the simulation starts")
        XCTAssertEqual(RoutePreviewRecorder.request?.destination, destination.location)
    }

    func testANewDestinationStartsInRealNavigation() {
        let model = AppModel(gatewayBaseURL: URL(string: "https://gateway.test/")!)
        model.selectPlace(destination)
        model.setSimulationMode(true)
        model.selectSimulationOrigin(start)
        model.selectPlace(start)
        XCTAssertFalse(model.isSimulationMode, "a new destination starts in real navigation")
        XCTAssertNil(model.simulationOrigin, "the old simulation start does not carry over")
    }

    /// The running ride follows the simulated fixes from the chosen start, so a
    /// runtime fed by the iPhone's GPS fails here.
    func testStartingASimulationRidesFromTheChosenStartNotTheGPS() async {
        RoutePreviewRecorder.route = botafogoRoute
        let model = AppModel(gatewayBaseURL: URL(string: "https://gateway.test/")!)
        model.selectPlace(destination)
        model.setSimulationMode(true)
        model.selectSimulationOrigin(start)
        await waitUntil("the simulation preview is planned") { model.hasRoutePreview }
        model.startNavigation()
        XCTAssertTrue(model.isSimulationActive)
        await waitUntil("the ride follows the simulated rider from the chosen start") {
            let view = model.navigation
            let northM = (view.routeViewOriginLatitudeDeg - start.location.latitudeDeg) * 111_195
            let eastM = (view.routeViewOriginLongitudeDeg - start.location.longitudeDeg) * 111_195 * 0.92
            return view.hasRouteView && (northM * northM + eastM * eastM).squareRoot() < 400
        }
        model.stopNavigation()
    }

    func testSimulationStartsAtTheChosenStartAndRidesTheChosenRoute() async {
        let start = self.start.location
        let session = DemoNavigationSession()
        session.install(route: botafogoRoute)
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

    func testALostPairingStaysInFrontOfTheRiderThroughTheRetries() {
        let action = L("The round display no longer knows this iPhone. Forget MOTO GPS in Settings › Bluetooth; it then connects again.")
        var device = BLEDeviceSnapshot()
        ESP32BLECentral.recordLinkLoss(CBError(.peerRemovedPairingInformation), fallback: "fallback", in: &device)
        XCTAssertEqual(device.riderAction, action)
        device.connection = .scanning
        XCTAssertEqual(device.riderAction, action, "the reconnect loop does not hide it")
        device.connection = .connecting(name: "MOTO GPS")
        XCTAssertEqual(device.riderAction, action)
        device.connection = .connected(name: "MOTO GPS")
        XCTAssertNil(device.riderAction, "a connection ends it")
        let other = CBError(.connectionTimeout)
        ESP32BLECentral.recordLinkLoss(other, fallback: "fallback", in: &device)
        XCTAssertNil(device.riderAction, "another kind of loss replaces it")
        XCTAssertEqual(device.connection, .failed(message: other.localizedDescription))
        ESP32BLECentral.recordLinkLoss(nil, fallback: "fallback", in: &device)
        XCTAssertEqual(device.connection, .failed(message: "fallback"))
    }
}
