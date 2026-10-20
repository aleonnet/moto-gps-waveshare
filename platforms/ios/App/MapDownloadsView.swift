import Combine
import Foundation
import MapKit
import MotoNavigationCore
import SwiftUI

struct SurroundingMapStatusRow: View {
    @ObservedObject var store: SurroundingMapStore

    var body: some View {
        LabeledContent {
            Text(store.status.text).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } label: { Label(L("Surrounding map"), systemImage: "map") }
    }
}

struct MapCity: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let scope: MapAreaScope
    let boundsWGS84: [Double]

    enum CodingKeys: String, CodingKey {
        case id, name, scope
        case boundsWGS84 = "bounds_wgs84"
    }
}

@MainActor
final class MapCitySearch: ObservableObject {
    @Published var query = ""
    @Published private(set) var cities: [MapCity] = []
    @Published private(set) var isSearching = false
    @Published private(set) var failed = false
    private let baseURL: URL
    private var task: Task<Void, Never>?
    private var generation = 0

    init(baseURL: URL) { self.baseURL = baseURL }
    deinit { task?.cancel() }

    func search() {
        task?.cancel()
        generation += 1
        let current = generation
        cities = []
        failed = false
        let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 80).contains(keywords.count) else { isSearching = false; return }
        isSearching = true
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/map/cities"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "keywords", value: keywords)]
        let url = components.url!
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200, data.count <= 1_048_576
                else { throw URLError(.badServerResponse) }
                struct Reply: Decodable { let cities: [MapCity] }
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                let valid = reply.cities.prefix(30).filter { city in
                    let b = city.boundsWGS84
                    return b.count == 4 && b.allSatisfy(\.isFinite) && b[0] < b[2] && b[1] < b[3] &&
                        b[0] >= -180 && b[2] <= 180 && b[1] >= -85 && b[3] <= 85
                }
                guard let self, self.generation == current else { return }
                self.cities = Array(valid)
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.isSearching = false
                self.failed = true
            }
        }
    }
}

struct MapDownloadsView: View {
    @ObservedObject var store: SurroundingMapStore
    let gatewayBaseURL: URL
    let route: [GCJ02Point]
    let destinationName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var planningRoute = false
    @State private var planningError: (any Error)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("Load surrounding maps automatically"))
                                .accessibilityIdentifier("map-autoload-title")
                            Text(store.status.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "network").foregroundStyle(.blue) }
                } footer: {
                    Text(L("While riding, roads and buildings around the round display load automatically. Without network, downloaded maps are used."))
                }
                Section {
                    NavigationLink {
                        MapCitySearchView(store: store, baseURL: gatewayBaseURL)
                    } label: {
                        Label(L("Download a city map"), systemImage: "building.2.crop.circle")
                    }
                    .accessibilityIdentifier("map-download-city")
                    if route.count >= 2 {
                        Button(action: downloadRoute) {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(planningRoute ? L("Working out the download area…") : L("Download around this route"))
                                    Text(destinationName ?? L("The selected route"))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "arrow.triangle.turn.up.right.diamond") }
                        }
                        .disabled(store.isDownloading || planningRoute)
                        .accessibilityIdentifier("map-download-route")
                    }
                } footer: {
                    Text(L("For rides between cities, plan the route first; only the map within about one kilometre of it is saved. Offline maps have no live traffic, and planning a new route still needs network."))
                }
                downloadStatus(store)
                if let planningError {
                    Section { Text(localizedMessage(for: planningError)).foregroundStyle(.secondary) }
                }
                Section(L("Saved")) {
                    if store.packs.isEmpty {
                        Text(L("No city or route maps downloaded yet"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.packs) { pack in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(pack.label.title).font(.headline)
                                Spacer()
                                Image(systemName: pack.isComplete ? "checkmark.circle.fill" : "pause.circle")
                                    .foregroundStyle(pack.isComplete ? Color.green : Color.secondary)
                            }
                            Text(pack.detail).font(.subheadline).foregroundStyle(.secondary)
                            Text(L("\(NavFormatting.byteCount(pack.byteCount)) · \(pack.isComplete ? L("Downloaded") : L("Not finished"))"))
                                .font(.footnote).foregroundStyle(.secondary)
                            if !pack.isComplete && !store.isDownloading {
                                Button(L("Resume download")) { store.resume(pack) }.buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(L("Delete"), role: .destructive) { store.delete(pack) }
                                .disabled(store.isDownloading)
                        }
                    }
                    Label(L("Jinan base map · Included with the app"), systemImage: "internaldrive")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Button(L("Clear the automatic cache")) { store.clearTemporaryCache() }
                        .disabled(store.isDownloading)
                } footer: {
                    Text(L("Maps you downloaded are kept. The automatic cache holds up to 128 MB and downloads up to 512 MB; data shared by cities and routes is stored once. An interrupted download can be resumed in the app."))
                }
                Section {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link(L("Protomaps map data"), destination: URL(string: "https://protomaps.com")!)
                } footer: { Text(L("How complete buildings and roads are depends on the local map data.")) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("Maps"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }.accessibilityIdentifier("map-downloads-done")
                }
            }
            .accessibilityIdentifier("map-downloads-sheet")
        }
    }

    private func downloadRoute() {
        planningRoute = true
        planningError = nil
        let points = route
        Task {
            do {
                let tiles = try await Task.detached(priority: .userInitiated) {
                    try MapTilePlanner.corridorGCJ02(points)
                }.value
                store.download(.route(destination: destinationName), tiles: tiles)
            } catch { planningError = error }
            planningRoute = false
        }
    }
}

private struct MapCitySearchView: View {
    @ObservedObject var store: SurroundingMapStore
    @StateObject private var search: MapCitySearch

    init(store: SurroundingMapStore, baseURL: URL) {
        self.store = store
        _search = StateObject(wrappedValue: MapCitySearch(baseURL: baseURL))
    }

    var body: some View {
        List {
            if search.isSearching {
                HStack { ProgressView(); Text(L("Searching cities…")).foregroundStyle(.secondary) }
            } else if search.failed {
                Text(L("Cities cannot be searched right now. Check the network and try again."))
                Button(L("Try again")) { search.search() }
            } else if search.cities.isEmpty {
                ContentUnavailableView(
                    search.query.count >= 2 ? L("No city found") : L("Add a city you ride in"),
                    systemImage: "building.2",
                    description: Text(L("Enter a city or district name, for example “Jinan”, “Shanghai” or “Lixia District”."))
                )
                .accessibilityIdentifier("map-city-empty")
            } else {
                ForEach(search.cities) { city in
                    NavigationLink {
                        MapCityDownloadView(store: store, city: city)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(city.name)
                            Text(city.scope.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("map-city-result-\(city.id)")
                }
            }
        }
        .navigationTitle(L("Download a city map"))
        .navigationBarTitleDisplayMode(.inline)
        // iOS 18 otherwise hides the field of a pushed list until the rider
        // pulls the list down, leaving this screen without a visible input.
        .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L("Search for a city or district"))
        .onChange(of: search.query) { _, _ in search.search() }
    }
}

private struct MapCityDownloadView: View {
    @ObservedObject var store: SurroundingMapStore
    let city: MapCity
    @State private var tiles: [MapTileID] = []
    @State private var planningError: (any Error)?

    var body: some View {
        List {
            Section {
                Map(initialPosition: .region(region)) {
                    MapPolygon(coordinates: corners)
                        .foregroundStyle(.blue.opacity(0.1))
                        .stroke(.blue, lineWidth: 2)
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel(L("Offline map area for \(city.name)"))
                LabeledContent(L("Area"), value: city.scope.text)
            } footer: {
                Text(L("Roads and buildings inside the blue frame are saved on the phone. The area covers the chosen city or district and may include parts of neighbouring areas at the edges."))
            }
            Section {
                if let planningError { Text(localizedMessage(for: planningError)).foregroundStyle(.secondary) }
                Button(L("Download map")) {
                    store.download(.city(name: city.name, scope: city.scope), tiles: tiles)
                }
                .disabled(tiles.isEmpty || store.isDownloading)
                .accessibilityIdentifier("map-city-start-download")
            } footer: {
                Text(L("Use Wi-Fi to download; the actual size depends on how many roads and buildings there are. If the area is too large, search for a specific district."))
            }
            downloadStatus(store)
        }
        .navigationTitle(city.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { tiles = try MapTilePlanner.boundsWGS84(city.boundsWGS84) }
            catch { planningError = error }
        }
    }

    private var region: MKCoordinateRegion {
        let b = city.boundsWGS84
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (b[1] + b[3]) / 2, longitude: (b[0] + b[2]) / 2),
            span: MKCoordinateSpan(latitudeDelta: (b[3] - b[1]) * 1.15, longitudeDelta: (b[2] - b[0]) * 1.15))
    }

    private var corners: [CLLocationCoordinate2D] {
        let b = city.boundsWGS84
        return [(b[1], b[0]), (b[1], b[2]), (b[3], b[2]), (b[3], b[0])].map {
            CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1)
        }
    }
}

@MainActor @ViewBuilder
private func downloadStatus(_ store: SurroundingMapStore) -> some View {
    if store.isDownloading {
        Section {
            ProgressView(value: store.downloadProgress)
                .accessibilityLabel(L("Map download progress"))
            Text(store.downloadMessage?.text ?? L("Downloading…")).font(.subheadline).foregroundStyle(.secondary)
            Button(L("Pause download")) { store.cancelDownload() }
        }
    } else if let message = store.downloadMessage {
        Section { Text(message.text).font(.subheadline).foregroundStyle(.secondary) }
    }
}
