import SwiftUI

enum MotoScreen: Hashable {
    case routePreview
    case activeNavigation
}

/// One primary flow: destination → route → ride. Device management is secondary.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @FocusState private var searchFocused: Bool
    @State private var showsDeviceDetails = false
    @State private var showsMapDownloads = false
    @State private var showsDataUse = false
    @State private var showsGatewaySettings = false
    @State private var showsLanguageSettings = false
    @State private var showsSimulationOrigin = false

    var body: some View {
        NavigationStack(path: navigationPath) {
            homeScreen
                .navigationDestination(for: MotoScreen.self) { screen in
                    switch screen {
                    case .routePreview: routePreviewScreen
                    case .activeNavigation: activeNavigationScreen
                    }
                }
        }
        .tint(.blue)
        .onChange(of: model.destinationQuery) { _, _ in model.destinationQueryDidChange() }
        .onChange(of: model.selectedPlace) { _, place in
            if place != nil { searchFocused = false }
        }
        .onChange(of: model.isNavigationActive) { _, active in
            if active { searchFocused = false }
        }
        .sheet(isPresented: $showsDeviceDetails) { deviceDetails }
        .sheet(isPresented: $showsMapDownloads) {
            MapDownloadsView(
                store: model.surroundingMap,
                gatewayBaseURL: model.mapGatewayBaseURL,
                route: model.mapDownloadRoute,
                destinationName: model.selectedPlace?.name
            )
        }
        .sheet(isPresented: $showsDataUse) { DataUseView() }
        .sheet(isPresented: $showsGatewaySettings) { GatewaySettingsView(model: model) }
        .sheet(isPresented: $showsLanguageSettings) { LanguageSettingsView(model: model) }
        .sheet(isPresented: $showsSimulationOrigin) { SimulationOriginSearchView(model: model) }
    }

    // Derive the stack from the session instead of synchronizing two mutable
    // paths with onChange. A system Back gesture uses the same cleanup as End.
    private var navigationPath: Binding<[MotoScreen]> {
        Binding(
            get: {
                if model.isNavigationActive { return [.activeNavigation] }
                if model.selectedPlace != nil { return [.routePreview] }
                return []
            },
            set: { path in
                if model.isNavigationActive, !path.contains(.activeNavigation) {
                    model.stopNavigation()
                } else if model.selectedPlace != nil, !path.contains(.routePreview) {
                    model.clearDestination()
                }
            }
        )
    }

    // MARK: - Destination search

    private var homeScreen: some View {
        List {
            if !model.isGatewayConfigured {
                Section {
                    Button { showsGatewaySettings = true } label: {
                        Label(L("Set up the navigation gateway"), systemImage: "network")
                    }
                    .accessibilityIdentifier("gateway-setup-button")
                } footer: {
                    Text(L("Enter the address of the gateway you deployed to search places and plan routes."))
                }
            }
            Section { searchField }
            if !model.destinationQuery.isEmpty {
                searchResultsSection
            } else {
                if model.recentPlaces.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label {
                                Text(L("Choose a destination"))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: { Image(systemName: "map") }
                        } description: {
                            Text(L("Search for a place or address, pick a route and ride."))
                        }
                        .padding(.vertical, 12)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    recentPlacesSection
                }
                Section {
                    deviceSummaryButton
                    mapDownloadsButton
                    demoButton
                } footer: {
                    Text(L("Once the round display is connected, guidance syncs automatically."))
                }
                Section {
                    Button { showsLanguageSettings = true } label: {
                        LabeledContent {
                            Text(model.languageName(model.language))
                        } label: {
                            Label(L("Language"), systemImage: "globe")
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .accessibilityIdentifier("language-settings-button")
                    Button { showsGatewaySettings = true } label: {
                        Label(L("Gateway settings"), systemImage: "network")
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityIdentifier("gateway-settings-button")
                    Button { showsDataUse = true } label: {
                        Label(L("Privacy & data"), systemImage: "hand.raised")
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityIdentifier("privacy-data-button")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L("Ride"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showsGatewaySettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(L("Gateway settings"))
                    .accessibilityIdentifier("gateway-settings-toolbar")
            }
            ToolbarItem(placement: .topBarTrailing) { deviceToolbarButton }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("Done")) { searchFocused = false }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            TextField(L("Search for a place or address"), text: $model.destinationQuery)
                .font(.body)
                .accessibilityIdentifier("destination-search-field")
                .accessibilityLabel(L("Search for a destination"))
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    model.submitDestinationSearch()
                    searchFocused = false
                }
            if !model.destinationQuery.isEmpty {
                Button {
                    model.clearDestination()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: 28, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Clear search"))
            }
        }
        .frame(minHeight: 44)
    }

    private var searchResultsSection: some View {
        Section {
            if model.isSearchingPlaces {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L("Searching…")).foregroundStyle(Color.secondary)
                }
                .frame(minHeight: 56)
                .accessibilityElement(children: .combine)
            } else if !model.placeResults.isEmpty {
                ForEach(Array(model.placeResults.enumerated()), id: \.offset) { index, place in
                    Button { select(place) } label: {
                        placeRow(place, symbol: "mappin.circle.fill")
                    }
                    .accessibilityIdentifier("place-result-\(index)")
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text(model.placeSearchFailure == nil ? L("Enter a place name") : L("No results"))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "magnifyingglass") }
                } description: {
                    Text(model.placeSearchFailure?.text ?? L("Type at least two characters, for example “Olympic Sports Center”."))
                } actions: {
                    if model.placeSearchFailure != nil {
                        Button(L("Search again"), action: model.submitDestinationSearch)
                    }
                }
            }
        } header: {
            Text(L("Results"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.searchScopeText)
                if model.searchLocationStatus == .permissionDenied {
                    Button(L("Turn on location in Settings"), action: openSystemSettings)
                }
            }
        }
    }

    private var recentPlacesSection: some View {
        Section {
            ForEach(Array(model.recentPlaces.enumerated()), id: \.offset) { index, place in
                Button { select(place) } label: { placeRow(place, symbol: "clock") }
                    .accessibilityIdentifier("recent-place-\(index)")
            }
        } header: {
            HStack {
                Text(L("Recent"))
                    .accessibilityIdentifier("recent-places-header")
                Spacer()
                Button(L("Clear"), action: model.clearRecentPlaces)
                    .textCase(nil)
                    .accessibilityLabel(L("Clear recent searches"))
            }
        }
    }

    private func placeRow(_ place: PlaceSearchResult, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(symbol == "clock" ? Color.secondary : .blue)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(place.name)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(placeSubtitle(place))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func select(_ place: PlaceSearchResult) {
        searchFocused = false
        model.selectPlace(place)
    }

    private var demoButton: some View {
        Button {
            searchFocused = false
            model.startDemoNavigation()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Demo navigation")).foregroundStyle(Color.primary)
                    Text(L("Try the navigation flow first"))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            } icon: {
                Image(systemName: "play.circle").foregroundStyle(.blue)
            }
            .padding(.vertical, 5)
        }
        .accessibilityIdentifier("demo-navigation-button")
    }

    // MARK: - Route selection

    private var mapDownloadsButton: some View {
        Button { showsMapDownloads = true } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Maps & offline downloads")).foregroundStyle(Color.primary)
                    Text(L("Loads the surroundings automatically and can save cities and route corridors ahead"))
                        .font(.subheadline).foregroundStyle(Color.secondary)
                }
            } icon: { Image(systemName: "map").foregroundStyle(.blue) }
            .padding(.vertical, 5)
        }
        .accessibilityIdentifier("map-downloads-button")
    }

    private var routePreviewScreen: some View {
        List {
            if let place = model.selectedPlace {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(place.name).font(.headline)
                            Text(placeSubtitle(place))
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                    }
                    .padding(.vertical, 5)
                    if model.isSimulationMode { simulationOriginRow }
                } header: {
                    if model.isSimulationMode {
                        Label(L("Simulate from"), systemImage: "play.circle.fill").textCase(nil)
                    } else {
                        Label(L("From my location"), systemImage: "location.fill").textCase(nil)
                    }
                }

                if model.isPlanningRoutePreview {
                    Section {
                        HStack(spacing: 14) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Planning the route"))
                                Text(L("Getting your location and traffic…"))
                                    .font(.subheadline)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("route-preview-loading")
                    }
                } else if model.hasRoutePreview {
                    Section {
                        RouteOverviewMap(
                            candidates: model.routePreviewCandidates,
                            selectedID: model.selectedRoutePreviewID,
                            origin: model.routePreviewOrigin,
                            destination: place.location,
                            localization: AppLocalization.shared.localization
                        )
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 220 : 270)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("route-preview-map")
                        .accessibilityLabel(L("Route overview to \(place.name)"))
                    }
                    Section {
                        ForEach(model.routePreviewCandidates) { candidate in routeOptionRow(candidate) }
                    } header: {
                        Text(L("Choose a route"))
                    } footer: {
                        Text(routeSourceFooter)
                    }
                    Section { mapDownloadsButton }
                } else if let failure = model.routePreviewFailure {
                    Section {
                        ContentUnavailableView {
                            Label {
                                Text(L("Could not plan a route"))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: { Image(systemName: "exclamationmark.triangle") }
                        } description: {
                            Text(failure.text)
                        } actions: {
                            if model.searchLocationStatus == .permissionDenied {
                                Button(L("Open Settings"), action: openSystemSettings)
                            }
                        }
                    }
                }
                if let failure = model.navigationFailure {
                    Section { failureMessage(failure.text) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("Route"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("Change")) {
                    model.clearDestination()
                    searchFocused = true
                }
                .accessibilityLabel(L("Change destination"))
                .accessibilityIdentifier("destination-change-button")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigationActionBar }
    }

    private func routeOptionRow(_ candidate: RoutePreviewCandidate) -> some View {
        let selected = candidate.id == model.selectedRoutePreviewID
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                model.selectRoutePreview(candidate.id)
            }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(candidate.title)
                        .font(.subheadline)
                        .foregroundStyle(selected ? Color.blue : .secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            routeDuration(candidate)
                            routeDistance(candidate)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            routeDuration(candidate)
                            routeDistance(candidate)
                        }
                    }
                    Label(candidate.trafficSummary, systemImage: "car.side")
                        .font(.subheadline)
                        .foregroundStyle(trafficTint(candidate))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.blue : Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("route-option-\(candidate.ordinal)")
        .accessibilityLabel(L("\(candidate.title), \(candidate.durationText), \(candidate.distanceText), \(candidate.trafficSummary)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func routeDuration(_ candidate: RoutePreviewCandidate) -> some View {
        Text(candidate.durationText)
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func routeDistance(_ candidate: RoutePreviewCandidate) -> some View {
        Text(candidate.distanceText)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(Color.secondary)
    }

    // MARK: - Ride in progress

    private var activeNavigationScreen: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: navigationSymbol)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(model.navigationFailure == nil ? Color.blue : .orange)
                        .frame(width: 76, height: 76)
                        .background(Color.blue.opacity(0.08), in: Circle())
                        .accessibilityHidden(true)
                    Text(navigationTitle)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(navigationDetail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .listRowBackground(Color.clear)
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isDemoActive ? L("Demo destination") : L("Destination"))
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Text(model.activeDestinationName).font(.headline)
                    }
                } icon: {
                    Image(systemName: "flag.checkered").foregroundStyle(.blue)
                }
                .padding(.vertical, 6)
                if dynamicTypeSize.isAccessibilitySize {
                    rideMetric(L("Time left"), value: remainingDuration)
                    rideMetric(L("Distance left"), value: remainingDistance)
                } else {
                    HStack(spacing: 24) {
                        rideMetric(L("Time left"), value: remainingDuration)
                        rideMetric(L("Distance left"), value: remainingDistance)
                    }
                }
            }
            Section(L("Navigation status")) {
                deviceSummaryButton
                statusRow(L("Phone location"), symbol: "location", value: locationStatus,
                          color: model.navigation.hasUsableFix ? .green : .secondary)
                statusRow(L("Traffic"), symbol: "car.side", value: trafficStatus, color: .secondary)
                SurroundingMapStatusRow(store: model.surroundingMap)
                Button { model.cycleMapZoom() } label: {
                    statusRow(L("Round display map"), symbol: "plus.magnifyingglass",
                              value: mapZoomText, color: .secondary)
                }
                .accessibilityIdentifier("map-zoom-toggle")
                .accessibilityValue(mapZoomText)
                .accessibilityHint(L("Switches between the street view and twice the distance"))
                Button(L("Manage offline maps")) { showsMapDownloads = true }
            }
            if model.isSimulationActive {
                Section {
                    Label(L("Location and movement are simulated along the chosen route."), systemImage: "play.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("simulation-notice")
                }
            }
            if model.isDemoActive {
                Section {
                    Label(L("Location and movement in the demo are simulated."), systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                } footer: {
                    Text(L("Road data © OpenStreetMap contributors"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("active-navigation-screen")
        .navigationTitle(model.isDemoActive ? L("Demo navigation")
            : model.isSimulationActive ? L("Simulation") : L("Navigating"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { deviceToolbarButton }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigationActionBar }
    }

    private func rideMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(title).font(.subheadline).foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(title), \(value)"))
    }

    /// Where a simulation starts; tapping it opens the start search.
    private var simulationOriginRow: some View {
        Button { showsSimulationOrigin = true } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.simulationOrigin?.name ?? L("Current location"))
                        .foregroundStyle(Color.primary)
                    if let origin = model.simulationOrigin {
                        Text(placeSubtitle(origin)).font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }
            } icon: {
                Image(systemName: "figure.walk.motion").foregroundStyle(.indigo)
            }
        }
        .accessibilityIdentifier("simulation-origin-button")
    }

    private var actionSymbol: String {
        if model.isNavigationActive { return "stop.fill" }
        return model.isSimulationMode ? "play.fill" : "location.fill"
    }

    private var actionTint: Color {
        if model.isNavigationActive { return .red }
        return model.isSimulationMode ? .indigo : .blue
    }

    private var navigationActionBar: some View {
        VStack(spacing: 10) {
            if !model.isNavigationActive {
                // The mode sits on the action it changes, so a simulation is
                // never started by mistake: the verb, icon and colour follow it.
                Picker(L("Ride mode"), selection: Binding(
                    get: { model.isSimulationMode },
                    set: { model.setSimulationMode($0) }
                )) {
                    Text(L("Navigate")).tag(false)
                    Text(L("Simulate")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("navigation-mode")
            }
            Button(action: model.toggleNavigation) {
                HStack(spacing: 9) {
                    if model.isPlanningRoutePreview {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: actionSymbol)
                    }
                    Text(model.primaryActionTitle).fixedSize(horizontal: false, vertical: true)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .controlSize(.large)
            .tint(actionTint)
            .disabled(!model.isNavigationActive && (model.selectedPlace == nil || model.isPlanningRoutePreview))
            .accessibilityIdentifier(model.isNavigationActive ? "end-navigation-action" : "primary-navigation-action")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: - Device sheet

    private var deviceToolbarButton: some View {
        Button {
            searchFocused = false
            showsDeviceDetails = true
        } label: { Image(systemName: "circle.circle") }
        .accessibilityLabel(L("My round display"))
        .accessibilityValue(deviceStatus)
        .accessibilityIdentifier("device-details-button")
    }

    private var deviceSummaryButton: some View {
        Button {
            searchFocused = false
            showsDeviceDetails = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "circle.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("My round display")).foregroundStyle(Color.primary)
                    Text(deviceStatus).font(.subheadline).foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 4)
                if model.deviceReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("device-summary-button")
    }

    private var deviceDetails: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "location.north.circle")
                            .font(.system(size: 64, weight: .ultraLight))
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                        Text(deviceName).font(.title2.weight(.semibold))
                        Text(deviceDetail)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .listRowBackground(Color.clear)
                Section {
                    statusRow(L("Connection"), symbol: "antenna.radiowaves.left.and.right", value: deviceStatus,
                              color: model.deviceReady ? .green : .secondary)
                    Button(connectionActionTitle, action: model.toggleDeviceConnection)
                        .accessibilityIdentifier("device-connection-action")
                    if case .bluetoothUnavailable = model.device.connection {
                        Button(L("Open Settings"), action: openSystemSettings)
                    }
                } footer: {
                    Text(L("Keep the round display on and near the iPhone. Once connected, the current navigation syncs automatically."))
                }
                Section(L("Location")) {
                    statusRow(L("Search location"), symbol: "location", value: searchLocationStatus, color: .secondary)
                    if model.searchLocationStatus == .permissionDenied {
                        Button(L("Turn on location in Settings"), action: openSystemSettings)
                    }
                }
            }
            .navigationTitle(L("My round display"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { showsDeviceDetails = false }
                        .accessibilityIdentifier("device-details-done")
                }
            }
            .accessibilityIdentifier("device-details-sheet")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var mapZoomText: String {
        model.mapZoomLevel == 14 ? L("Wide · about 900 m ahead") : L("Street · about 450 m ahead")
    }

    /// Credits the service that actually planned the shown routes.
    private var routeSourceFooter: String {
        model.selectedRoutePreview?.route.provider == "geoapify"
            ? L("Geoapify motorcycle routes · Map data © OpenStreetMap contributors")
            : L("AMap driving routes · Times change with traffic")
    }

    private func statusRow(_ title: String, symbol: String, value: String, color: Color) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: symbol).foregroundStyle(Color.primary)
        }
        .font(.body)
        .padding(.vertical, 4)
    }

    private func failureMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: - User-facing state

    private func placeSubtitle(_ place: PlaceSearchResult) -> String {
        let area = place.displayArea.isEmpty
            ? [place.city, place.district].filter { !$0.isEmpty }.joined(separator: " · ")
            : place.displayArea
        var parts = [area, place.address].filter { !$0.isEmpty }
        if let distance = place.distanceM, distance >= 0 {
            let distanceText = NavFormatting.distance(meters: distance)
            parts.append(L("\(distanceText) away"))
        }
        return parts.isEmpty ? L("View route") : parts.joined(separator: " · ")
    }

    private var deviceStatus: String {
        switch model.device.connection {
        case .connected: return model.deviceReady ? L("Connected") : L("Preparing")
        case .scanning: return L("Looking for the round display")
        case .connecting: return L("Connecting")
        case .failed: return L("Not connected")
        case .bluetoothUnavailable: return L("Bluetooth unavailable")
        case .idle: return L("Disconnected")
        }
    }

    private var deviceName: String {
        switch model.device.connection {
        case let .connected(name), let .connecting(name): return name
        default: return "MOTO GPS"
        }
    }

    private var deviceDetail: String {
        if let action = model.device.riderAction { return action }
        switch model.device.connection {
        case .connected:
            return model.deviceReady
                ? L("The round display is ready for guidance.")
                : L("Preparing navigation sync, please wait.")
        case .failed:
            return L("Could not connect. Make sure the round display is on and near the phone, then try again.")
        case .bluetoothUnavailable:
            return L("Turn on Bluetooth and allow MOTO GPS to use it.")
        case .scanning, .connecting:
            return L("Keep the round display on and near the phone.")
        case .idle:
            return L("Connect your round display to see guidance on the handlebar.")
        }
    }

    private var connectionActionTitle: String {
        switch model.device.connection {
        case .connected: return L("Disconnect")
        case .scanning: return L("Stop searching")
        case .connecting: return L("Cancel")
        case .failed: return L("Reconnect")
        case .idle, .bluetoothUnavailable: return L("Connect the round display")
        }
    }

    private var searchLocationStatus: String {
        switch model.searchLocationStatus {
        case .available: return L("Available")
        case .preparing: return L("Locating")
        case .permissionDenied: return L("Not allowed")
        case .unavailable: return L("Unavailable")
        }
    }

    private var navigationTitle: String {
        if model.navigationFailure != nil { return L("Navigation needs attention") }
        switch model.navigation.stateName {
        case "acquiring": return L("Getting your location")
        case "planning": return L("Planning the route")
        case "rerouting": return L("Rerouting")
        case "arrived": return L("You have arrived")
        case "navigating":
            if model.isDemoActive { return L("Demo running") }
            return model.isSimulationActive ? L("Simulation running") : L("Navigating")
        default: return L("Ready to ride")
        }
    }

    private var navigationDetail: String {
        if let failure = model.navigationFailure { return failure.text }
        if model.navigation.stateName == "navigating" {
            if model.isDemoActive { return L("Preview the ride and the guidance on the round display.") }
            return model.deviceReady
                ? L("The round display is connected; you can lock the phone and put it away.")
                : L("Once the round display connects, guidance syncs automatically.")
        }
        return model.phaseDetail
    }

    private var navigationSymbol: String {
        if model.navigationFailure != nil { return "exclamationmark.triangle" }
        switch model.navigation.stateName {
        case "arrived": return "flag.checkered"
        case "rerouting": return "arrow.triangle.2.circlepath"
        case "navigating": return "location.north.fill"
        default: return "location.magnifyingglass"
        }
    }

    private var hasNavigationEstimate: Bool {
        ["navigating", "rerouting", "arrived"].contains(model.navigation.stateName)
    }

    private var remainingDuration: String {
        hasNavigationEstimate ? model.remainingDurationText : "—"
    }

    private var remainingDistance: String {
        hasNavigationEstimate ? model.remainingDistanceText : "—"
    }

    private var locationStatus: String {
        if model.isDemoActive { return L("Demo location") }
        if model.isSimulationActive { return L("Simulated") }
        return model.navigation.hasUsableFix ? L("Available") : L("Locating")
    }

    private var trafficStatus: String {
        if model.isDemoActive { return L("Demo") }
        if model.navigation.trafficRequestInFlight { return L("Updating") }
        return model.navigation.networkName == "online" ? L("Online") : L("Offline")
    }

    private func trafficTint(_ candidate: RoutePreviewCandidate) -> Color {
        switch candidate.traffic {
        case .heavy: return .red
        case .partlySlow: return .orange
        case .smooth: return .green
        case .unknown: return .secondary
        }
    }
}
