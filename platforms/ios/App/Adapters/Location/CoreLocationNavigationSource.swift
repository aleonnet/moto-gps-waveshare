import CoreLocation
import MotoNavigationCore

/// Permission failures reported while navigating; the text is read when shown.
enum LocationPermissionError: LocalizedError {
    case off
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .off: L("Location access is off. Allow “Always” location in Settings.")
        case .unconfirmed: L("This system cannot confirm the location permission")
        }
    }
}

@MainActor
final class CoreLocationNavigationSource: NSObject, NavigationLocationSource {
    private static let maximumFixAgeS: TimeInterval = 15
    private let manager = CLLocationManager()
    private var onFix: (@MainActor (NavigationFix) -> Void)?
    private var onFailure: (@MainActor (any Error) -> Void)?
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Keep fixes flowing even while the bike is parked: with a 2 m
        // distance filter Core Location stops reporting when the rider
        // stands still, leaving the last non-zero speed frozen on the
        // handlebar gauge. kCLDistanceFilterNone keeps ~1 Hz updates so
        // the speed decays to zero within a couple of seconds.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        #if os(iOS)
        manager.showsBackgroundLocationIndicator = true
        #endif
    }

    func start(
        onFix: @escaping @MainActor (NavigationFix) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) throws {
        self.onFix = onFix
        self.onFailure = onFailure
        wantsUpdates = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
        case .restricted, .denied:
            throw NavigationSourceError.permissionDenied
        @unknown default:
            throw LocationPermissionError.unconfirmed
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        onFix = nil
        onFailure = nil
    }
}

extension CoreLocationNavigationSource: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsUpdates else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .restricted, .denied:
            onFailure?(LocationPermissionError.off)
        case .notDetermined:
            break
        @unknown default:
            onFailure?(LocationPermissionError.unconfirmed)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = Date()
        guard let location = locations
            .filter({
                $0.horizontalAccuracy >= 0 &&
                    $0.coordinate.latitude.isFinite &&
                    $0.coordinate.longitude.isFinite &&
                    abs($0.timestamp.timeIntervalSince(now)) <= Self.maximumFixAgeS
            })
            .max(by: { $0.timestamp < $1.timestamp })
        else { return }

        onFix?(
            NavigationFix(
                coordinate: WGS84Point(
                    longitudeDeg: location.coordinate.longitude,
                    latitudeDeg: location.coordinate.latitude
                ),
                altitudeM: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracyM: location.horizontalAccuracy,
                speedMps: location.speed >= 0 ? location.speed : nil,
                courseDeg: location.course >= 0 ? location.course : nil,
                timestamp: location.timestamp
            )
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let locationError = error as? CLError
        if locationError?.code == .locationUnknown { return }
        onFailure?(error)
    }
}
