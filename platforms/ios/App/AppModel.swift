import Combine
import Foundation
import MotoNavigationCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var navigation = MotoNavCoreBridge().snapshot
    @Published private(set) var device = BLEDeviceSnapshot()
    @Published private(set) var navigationFailure: AppMessage?
    @Published private(set) var isNavigationActive = false
    @Published private(set) var isDemoActive = false

    @Published var destinationQuery = ""
    @Published private(set) var placeResults: [PlaceSearchResult] = []
    @Published private(set) var selectedPlace: PlaceSearchResult?
    @Published private(set) var recentPlaces: [PlaceSearchResult] = []
    @Published private(set) var isSearchingPlaces = false
    @Published private(set) var placeSearchFailure: AppMessage?
    @Published private(set) var searchLocationStatus: SearchLocationBiasStatus = .preparing
    @Published private(set) var routePreviewCandidates: [RoutePreviewCandidate] = []
    @Published private(set) var selectedRoutePreviewID: String?
    @Published private(set) var routePreviewOrigin: WGS84Point?
    @Published private(set) var isPlanningRoutePreview = false
    @Published private(set) var routePreviewFailure: AppMessage?

    private let bluetooth = ESP32BLECentral()
    private let liveLocation = CoreLocationNavigationSource()
    private let searchLocation = SearchLocationBiasSource()
    private var liveRouteProvider: AmapGatewayRouteProvider
    private var placeProvider: AmapGatewayPlaceProvider
    private let mediaController = AppleMusicRemoteController()
    let surroundingMap: SurroundingMapStore
    @Published private(set) var mapGatewayBaseURL: URL
    @Published private(set) var isUpdatingGateway = false
    private var runtime: SharedNavigationRuntime?
    private var placeSearchTask: Task<Void, Never>?
    private var routePreviewTask: Task<Void, Never>?
    private var routePreviewRequestID: UInt32 = 1
    private var routePreviewGeneration: UInt64 = 0

    private static let recentPlacesKey = "MotoGPS.RecentPlaces.v1"

    /// Views reading it redraw when the language changes; see AppLocalization.
    var language: AppLanguage { AppLocalization.shared.language }

    init(gatewayBaseURL: URL = AppConfiguration.gatewayBaseURL) {
        liveRouteProvider = AmapGatewayRouteProvider(baseURL: gatewayBaseURL)
        placeProvider = AmapGatewayPlaceProvider(baseURL: gatewayBaseURL)
        mapGatewayBaseURL = gatewayBaseURL
        surroundingMap = SurroundingMapStore(baseURL: gatewayBaseURL)
        recentPlaces = Self.loadRecentPlaces()

        surroundingMap.onScene = { [weak self] scene in
            self?.bluetooth.sendMapScene(scene)
        }

        bluetooth.onSnapshotChange = { [weak self] snapshot in
            self?.device = snapshot
        }
        bluetooth.onDeviceCommand = { [weak self] command in
            guard let self else { return .failed }
            switch command.kind {
            case 0:
                guard let runtime = self.runtime else { return .invalidState }
                return runtime.selectDisplayPage(rawValue: command.page)
                    ? .accepted
                    : .unsupported
            case 16 ... 19:
                return self.mediaController.handleDeviceCommand(kind: command.kind)
            default:
                return .unsupported
            }
        }
        mediaController.onStateChange = { [weak self] state in
            self?.bluetooth.sendMediaState(state)
        }
        bluetooth.sendLanguage(AppLocalization.shared.deviceLanguageTag)
        searchLocation.onLocationChange = { [weak self] point in
            guard let self else { return }
            let query = self.destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if point != nil, self.selectedPlace == nil, query.count >= 2 {
                // A fresh one-shot fix may arrive after a nationwide request
                // has already started. Replace it with a location-biased search
                // without requesting location again and creating a callback loop.
                self.schedulePlaceSearch(query: query, delay: .zero)
            }
            if point != nil, self.selectedPlace != nil,
               self.isPlanningRoutePreview, self.routePreviewTask == nil
            {
                self.beginRoutePreviewRequestIfPossible()
            }
        }
        searchLocation.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.searchLocationStatus = status
            guard self.isPlanningRoutePreview,
                  self.routePreviewTask == nil,
                  self.searchLocation.latestPoint == nil
            else { return }
            if status == .permissionDenied {
                self.failRoutePreview("Your current location is needed to plan a route. Allow location in Settings.")
            } else if status == .unavailable {
                self.failRoutePreview("Your location is unavailable right now. Move to an open area and try again.")
            }
        }

        #if DEBUG
        // Offline UI checks must not request device permissions or contact services.
        if ProcessInfo.processInfo.arguments.contains("--moto-ui-offline") { return }
        #endif
        searchLocation.prepare()
        mediaController.start()
        bluetooth.connect()

        #if DEBUG
        // Command-line-only hook for a repeatable phone-to-round-screen smoke
        // test. Normal App launches and the visible demo control are unchanged.
        if ProcessInfo.processInfo.arguments.contains("--moto-demo-on-launch") {
            Task { @MainActor [weak self] in
                self?.startDemoNavigation()
            }
        }
        #endif
    }

    deinit {
        placeSearchTask?.cancel()
        routePreviewTask?.cancel()
    }

    var isGatewayConfigured: Bool {
        (try? GatewayConfiguration.normalizedURL(mapGatewayBaseURL.absoluteString)) != nil
    }

    func selectLanguage(_ language: AppLanguage) {
        AppLocalization.shared.select(language)
        // Views redraw through L(); the media text and the round display are
        // outside SwiftUI and follow explicitly.
        mediaController.refreshLocalizedText()
        bluetooth.sendLanguage(AppLocalization.shared.deviceLanguageTag)
    }

    /// The language's own name, e.g. "Português (Brasil)"; for System, the
    /// language iOS currently selects.
    func languageName(_ language: AppLanguage) -> String {
        let code = language == .system ? AppLocalization.shared.systemLocalization : language.rawValue
        let locale = Locale(identifier: code)
        let name = (locale.localizedString(forIdentifier: code) ?? code).capitalized(with: locale)
        return language == .system ? L("System (\(name))") : name
    }

    func saveGatewayAddress(_ address: String) async throws {
        guard !isNavigationActive, !isUpdatingGateway else {
            throw GatewaySettingsError.navigationActive
        }
        let url = try GatewayConfiguration.normalizedURL(address)
        isUpdatingGateway = true
        defer { isUpdatingGateway = false }
        clearDestination()
        await surroundingMap.changeGateway(to: url)
        liveRouteProvider = AmapGatewayRouteProvider(baseURL: url)
        placeProvider = AmapGatewayPlaceProvider(baseURL: url)
        mapGatewayBaseURL = url
        try GatewayConfiguration.save(url.absoluteString)
    }

    var deviceReady: Bool {
        if case .connected = device.connection {
            return device.negotiatedProtocol == "V1"
        }
        return false
    }

    /// Navigation can start before BLE is ready. The central retains the newest
    /// snapshot and synchronizes it when the round display reconnects.
    var canStartNavigation: Bool {
        selectedPlace != nil && selectedRoutePreview != nil && !isPlanningRoutePreview
    }

    var selectedRoutePreview: RoutePreviewCandidate? {
        guard let selectedRoutePreviewID else { return nil }
        return routePreviewCandidates.first { $0.id == selectedRoutePreviewID }
    }

    var mapDownloadRoute: [GCJ02Point] {
        if isNavigationActive { return runtime?.activeRoutePolyline ?? [] }
        return selectedRoutePreview?.route.polyline ?? []
    }

    var hasRoutePreview: Bool {
        !routePreviewCandidates.isEmpty
    }

    var searchBiasAvailable: Bool {
        searchLocationStatus == .available
    }

    var phaseDetail: String {
        if let navigationFailure { return navigationFailure.text }
        if isDemoActive, navigation.stateName == "navigating" {
            return deviceReady
                ? L("Real Jinan road network syncing · Roads © OpenStreetMap contributors")
                : L("Real Jinan road network running · Roads © OpenStreetMap contributors")
        }
        switch navigation.stateName {
        case "acquiring": return L("Keep precise location turned on")
        case "planning": return L("Reading the live AMap route and traffic")
        case "navigating":
            return deviceReady
                ? L("You can lock the phone and put it in your pocket")
                : L("The phone keeps navigating; the round display syncs once connected")
        case "rerouting": return L("The new route syncs to the round display once it is ready")
        case "arrived": return L("This navigation is complete")
        default: return L("After you choose a destination, the route is sent to the round display over Bluetooth")
        }
    }

    var remainingDistanceText: String {
        NavFormatting.distance(meters: navigation.remainingDistanceM)
    }

    var remainingDurationText: String {
        NavFormatting.duration(seconds: Int(navigation.remainingDurationS))
    }

    var primaryActionTitle: String {
        if isNavigationActive { return L("End navigation") }
        if isPlanningRoutePreview { return L("Planning the route") }
        if selectedPlace == nil { return L("Choose a destination first") }
        if selectedRoutePreview == nil { return L("Plan the route again") }
        return L("Start navigation")
    }

    var activeDestinationName: String {
        isDemoActive ? L("MOTO GPS demo route") : (selectedPlace?.name ?? L("Destination"))
    }

    var searchScopeText: String {
        switch searchLocationStatus {
        case .available:
            return L("Sorted by distance from your location")
        case .preparing:
            return L("Getting your location; searching nationwide for now")
        case .permissionDenied:
            return L("Location not allowed; searching nationwide")
        case .unavailable:
            return L("Location unavailable; searching nationwide for now")
        }
    }

    func destinationQueryDidChange() {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        navigationFailure = nil
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedPlace?.name == query {
            // Selecting a POI writes its canonical name back into the field.
            // That programmatic change must not immediately launch another
            // search and temporarily disable the Start Navigation action.
            placeSearchTask?.cancel()
            placeResults = []
            isSearchingPlaces = false
            return
        }
        if selectedPlace?.name != query {
            selectedPlace = nil
            clearRoutePreviewState()
        }
        schedulePlaceSearch(query: query, delay: .milliseconds(480))
    }

    func submitDestinationSearch() {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        searchLocation.refresh()
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        schedulePlaceSearch(query: query, delay: .zero)
    }

    func selectPlace(_ place: PlaceSearchResult) {
        guard !isUpdatingGateway else { return }
        placeSearchTask?.cancel()
        isSearchingPlaces = false
        placeSearchFailure = nil
        navigationFailure = nil
        selectedPlace = place
        destinationQuery = place.name
        placeResults = []
        remember(place)
        planRoutePreview()
    }

    func clearDestination() {
        guard !isNavigationActive else { return }
        placeSearchTask?.cancel()
        destinationQuery = ""
        selectedPlace = nil
        placeResults = []
        isSearchingPlaces = false
        placeSearchFailure = nil
        navigationFailure = nil
        clearRoutePreviewState()
    }

    func clearRecentPlaces() {
        recentPlaces = []
        UserDefaults.standard.removeObject(forKey: Self.recentPlacesKey)
    }

    func toggleNavigation() {
        if isNavigationActive {
            stopNavigation()
        } else if selectedRoutePreview == nil {
            planRoutePreview()
        } else {
            startNavigation()
        }
    }

    func startNavigation() {
        guard !isUpdatingGateway, isGatewayConfigured else {
            navigationFailure = .localized("Enter the service address in Gateway settings first")
            return
        }
        guard let selectedPlace else {
            navigationFailure = .localized("Choose a destination from the search results first")
            return
        }
        guard let selectedRoutePreview else {
            navigationFailure = .localized("Plan the route and choose one first")
            return
        }
        guard let routePreviewOrigin else {
            navigationFailure = .localized("The route start is no longer valid; plan the route again")
            planRoutePreview()
            return
        }

        routePreviewTask?.cancel()
        routePreviewTask = nil
        surroundingMap.reset()
        runtime?.stop()
        let runtime = SharedNavigationRuntime(
            locationSource: liveLocation,
            routeProvider: PreviewSelectedRouteProvider(
                selectedRoute: selectedRoutePreview.route,
                selectedRouteOrigin: routePreviewOrigin,
                liveProvider: liveRouteProvider
            )
        )
        bind(runtime)
        self.runtime = runtime
        isDemoActive = false
        navigationFailure = nil
        let started = runtime.start(
            destination: selectedPlace.location,
            destinationPOIID: selectedPlace.id.isEmpty ? nil : selectedPlace.id
        )
        isNavigationActive = started
        if !started {
            self.runtime = nil
        }
    }

    func startDemoNavigation() {
        guard !isNavigationActive, !isUpdatingGateway else { return }
        surroundingMap.reset()
        runtime?.stop()
        let demoSession = DemoNavigationSession()
        let runtime = SharedNavigationRuntime(
            locationSource: DemoNavigationLocationSource(session: demoSession),
            routeProvider: DemoNavigationRouteProvider(
                liveProvider: liveRouteProvider,
                session: demoSession
            )
        )
        bind(runtime)
        self.runtime = runtime
        navigationFailure = nil
        isDemoActive = true
        let started = runtime.start(
            destination: JinanDemoFixture.requestedDestinationWGS84,
            destinationPOIID: JinanDemoFixture.destinationPOIID
        )
        isNavigationActive = started
        if !started {
            isDemoActive = false
            self.runtime = nil
        }
    }

    func stopNavigation() {
        runtime?.stop()
        runtime = nil
        isNavigationActive = false
        isDemoActive = false
        navigationFailure = nil
        surroundingMap.reset()
        // Ending navigation used to leave selectedPlace set, so the app stuck
        // on route preview with no obvious way back to the home/search screen.
        // Match the web shell: end → back to destination search.
        clearDestination()
    }

    func selectRoutePreview(_ id: String) {
        guard routePreviewCandidates.contains(where: { $0.id == id }) else { return }
        selectedRoutePreviewID = id
        navigationFailure = nil
    }

    func planRoutePreview() {
        guard !isNavigationActive, !isUpdatingGateway, selectedPlace != nil else { return }
        guard isGatewayConfigured else {
            failRoutePreview("Enter the service address in Gateway settings first")
            return
        }
        routePreviewGeneration &+= 1
        routePreviewTask?.cancel()
        routePreviewTask = nil
        routePreviewCandidates = []
        selectedRoutePreviewID = nil
        routePreviewOrigin = nil
        routePreviewFailure = nil
        navigationFailure = nil
        isPlanningRoutePreview = true

        if searchLocationStatus == .permissionDenied {
            failRoutePreview("Your current location is needed to plan a route. Allow location in Settings.")
            return
        }
        if searchLocation.refreshForRoutePlanning() {
            // Always wait for this new one-shot fix. Reusing the location that
            // biased an earlier POI search can build a route from home after
            // the rider has already moved elsewhere.
            return
        }
        beginRoutePreviewRequestIfPossible()
    }

    func toggleDeviceConnection() {
        bluetooth.toggleConnection()
    }

    private func bind(_ runtime: SharedNavigationRuntime) {
        runtime.onSnapshot = { [weak self] snapshot in
            self?.navigation = snapshot
            if snapshot.stateName == "navigating" || snapshot.stateName == "arrived" {
                self?.navigationFailure = nil
            }
            self?.bluetooth.sendNavigationSnapshot(snapshot)
            if snapshot.hasRouteView {
                self?.surroundingMap.update(
                    latitudeDeg: snapshot.routeViewOriginLatitudeDeg,
                    longitudeDeg: snapshot.routeViewOriginLongitudeDeg
                )
            }
        }
        runtime.onFailure = { [weak self] error in
            self?.navigationFailure = .error(error)
        }
    }

    private func beginRoutePreviewRequestIfPossible() {
        guard routePreviewTask == nil,
              isPlanningRoutePreview,
              let place = selectedPlace,
              let origin = searchLocation.latestPoint
        else { return }

        let placeIdentity = Self.placeIdentity(place)
        routePreviewRequestID &+= 1
        if routePreviewRequestID == 0 { routePreviewRequestID = 1 }
        let request = RouteRequest(
            requestID: routePreviewRequestID,
            origin: origin,
            destination: place.location,
            destinationPOIID: place.id.isEmpty ? nil : place.id
        )
        let routeProvider = liveRouteProvider
        let generation = routePreviewGeneration
        routePreviewTask = Task { @MainActor [weak self, routeProvider] in
            defer {
                if self?.routePreviewGeneration == generation {
                    self?.routePreviewTask = nil
                }
            }
            do {
                let routes = try await routeProvider.routeOptions(for: request)
                try Task.checkCancellation()
                guard let self,
                      let currentPlace = self.selectedPlace,
                      Self.placeIdentity(currentPlace) == placeIdentity
                else { return }
                let candidates = routes.enumerated().map {
                    RoutePreviewCandidate(ordinal: $0.offset, route: $0.element)
                }
                guard let first = candidates.first else {
                    self.failRoutePreview("AMap returned no usable route. Try again later.")
                    return
                }
                self.routePreviewCandidates = candidates
                self.selectedRoutePreviewID = first.id
                self.routePreviewOrigin = origin
                self.routePreviewFailure = nil
                self.isPlanningRoutePreview = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failRoutePreview("Route planning failed. Check the network and try again.")
            }
        }
    }

    private func failRoutePreview(_ message: LocalizedStringResource) {
        routePreviewTask?.cancel()
        routePreviewTask = nil
        routePreviewCandidates = []
        selectedRoutePreviewID = nil
        routePreviewOrigin = nil
        isPlanningRoutePreview = false
        routePreviewFailure = .localized(message)
    }

    private func clearRoutePreviewState() {
        routePreviewGeneration &+= 1
        routePreviewTask?.cancel()
        routePreviewTask = nil
        routePreviewCandidates = []
        selectedRoutePreviewID = nil
        routePreviewOrigin = nil
        isPlanningRoutePreview = false
        routePreviewFailure = nil
    }

    private func schedulePlaceSearch(query: String, delay: Duration) {
        placeSearchTask?.cancel()
        placeSearchFailure = nil

        guard !isUpdatingGateway, isGatewayConfigured else {
            placeResults = []
            isSearchingPlaces = false
            if query.count >= 2 { placeSearchFailure = .localized("Enter the service address in Gateway settings first") }
            return
        }
        guard query.count >= 2 else {
            placeResults = []
            isSearchingPlaces = false
            return
        }
        guard selectedPlace?.name != query else {
            placeResults = []
            isSearchingPlaces = false
            return
        }

        // Never leave a previous query tappable while the next request is in
        // flight; selecting stale rows can start navigation to the wrong POI.
        placeResults = []
        isSearchingPlaces = true
        placeSearchTask = Task { @MainActor [weak self] in
            do {
                if delay != .zero {
                    try await Task.sleep(for: delay)
                }
                guard let self else { return }
                let places = try await self.placeProvider.search(
                    keywords: query,
                    near: self.searchLocation.latestPoint
                )
                try Task.checkCancellation()
                guard self.destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                self.placeResults = Self.deduplicated(places)
                self.isSearchingPlaces = false
                self.placeSearchFailure = self.placeResults.isEmpty
                    ? .localized("Nothing found. Try a more complete place name.")
                    : nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.placeResults = []
                self.isSearchingPlaces = false
                self.placeSearchFailure = .localized("Place search failed. Check the network and try again.")
            }
        }
    }

    private func remember(_ place: PlaceSearchResult) {
        let key = Self.placeIdentity(place)
        recentPlaces.removeAll { Self.placeIdentity($0) == key }
        // Distance belongs to one location fix, not to the place itself. Keep
        // the exact destination but do not show a stale distance after the
        // rider moves or relaunches the app.
        recentPlaces.insert(
            PlaceSearchResult(
                id: place.id,
                name: place.name,
                address: place.address,
                city: place.city,
                district: place.district,
                displayArea: place.displayArea,
                location: place.location,
                distanceM: nil
            ),
            at: 0
        )
        if recentPlaces.count > 8 {
            recentPlaces.removeLast(recentPlaces.count - 8)
        }
        if let data = try? JSONEncoder().encode(recentPlaces) {
            UserDefaults.standard.set(data, forKey: Self.recentPlacesKey)
        }
    }

    private static func loadRecentPlaces() -> [PlaceSearchResult] {
        guard let data = UserDefaults.standard.data(forKey: recentPlacesKey),
              let places = try? JSONDecoder().decode([PlaceSearchResult].self, from: data)
        else { return [] }
        return Array(deduplicated(places).prefix(8))
    }

    private static func deduplicated(_ places: [PlaceSearchResult]) -> [PlaceSearchResult] {
        var seen = Set<String>()
        return places.filter { seen.insert(placeIdentity($0)).inserted }
    }

    private static func placeIdentity(_ place: PlaceSearchResult) -> String {
        if !place.id.isEmpty { return "id:\(place.id)" }
        return "geo:\(place.name)|\(place.location.longitudeDeg)|\(place.location.latitudeDeg)"
    }

}

private enum GatewaySettingsError: LocalizedError {
    case navigationActive
    var errorDescription: String? { L("End navigation before changing the gateway address.") }
}
