import Foundation
import MotoNavigationCore

/// How much of a route is slowed by traffic; colours and text both derive
/// from this value, never from the displayed words.
enum RouteTrafficSummary: Equatable {
    case unknown, smooth, partlySlow, heavy
}

struct RoutePreviewCandidate: Identifiable, Equatable {
    let ordinal: Int
    let route: RoutePlan

    var id: String { "\(route.routeID)#\(ordinal)" }

    var title: String {
        switch ordinal {
        case 0: L("Recommended route")
        case 1: L("Alternative 1")
        default: L("Alternative 2")
        }
    }

    var distanceText: String { NavFormatting.distance(meters: route.totalDistanceM) }

    var durationText: String { NavFormatting.duration(seconds: Int(route.totalDurationS)) }

    var traffic: RouteTrafficSummary {
        guard !route.traffic.isEmpty, route.totalDistanceM > 0 else { return .unknown }
        let weighted = route.traffic.reduce(into: (slow: 0.0, congested: 0.0)) { result, segment in
            let length = max(0, segment.endOffsetM - segment.startOffsetM)
            switch segment.level {
            case .slow:
                result.slow += length
            case .congested, .severe:
                result.congested += length
            case .unknown, .freeFlow:
                break
            }
        }
        let congestedShare = weighted.congested / route.totalDistanceM
        let affectedShare = (weighted.slow + weighted.congested) / route.totalDistanceM
        if congestedShare >= 0.12 { return .heavy }
        if affectedShare >= 0.18 { return .partlySlow }
        return .smooth
    }

    var trafficSummary: String {
        switch traffic {
        case .unknown: L("No traffic details")
        case .smooth: L("Traffic is light")
        case .partlySlow: L("Slow in places")
        case .heavy: L("Heavy traffic")
        }
    }
}

/// Supplies the exact route selected on the preview screen to NavCore's first
/// route request. Reroutes and traffic refreshes continue to use the live
/// provider, preserving the existing deviation and traffic architecture.
final class PreviewSelectedRouteProvider: NavigationRouteProviding, @unchecked Sendable {
    private let selectedRoute: RoutePlan
    private let selectedRouteOrigin: WGS84Point
    private let liveProvider: any NavigationRouteProviding
    private let maximumOriginDriftM: Double
    private let lock = NSLock()
    private var didSupplySelectedRoute = false

    init(
        selectedRoute: RoutePlan,
        selectedRouteOrigin: WGS84Point,
        liveProvider: any NavigationRouteProviding,
        maximumOriginDriftM: Double = 120
    ) {
        self.selectedRoute = selectedRoute
        self.selectedRouteOrigin = selectedRouteOrigin
        self.liveProvider = liveProvider
        self.maximumOriginDriftM = maximumOriginDriftM
    }

    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        let shouldSupplySelectedRoute = lock.withLock {
            guard !didSupplySelectedRoute,
                  !request.isReroute,
                  request.previousRouteID == nil
            else { return false }
            didSupplySelectedRoute = true
            return true
        }
        if shouldSupplySelectedRoute,
           Self.distanceM(from: selectedRouteOrigin, to: request.origin) <= maximumOriginDriftM
        {
            return RouteEnvelope(requestID: request.requestID, route: selectedRoute)
        }
        return try await liveProvider.route(for: request)
    }

    private static func distanceM(from start: WGS84Point, to end: WGS84Point) -> Double {
        let earthRadiusM = 6_371_000.0
        let startLatitude = start.latitudeDeg * .pi / 180
        let endLatitude = end.latitudeDeg * .pi / 180
        let latitudeDelta = (end.latitudeDeg - start.latitudeDeg) * .pi / 180
        let longitudeDelta = (end.longitudeDeg - start.longitudeDeg) * .pi / 180
        let haversine = pow(sin(latitudeDelta / 2), 2) +
            cos(startLatitude) * cos(endLatitude) * pow(sin(longitudeDelta / 2), 2)
        return 2 * earthRadiusM * asin(sqrt(min(1, max(0, haversine))))
    }
}
