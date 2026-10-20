// Planner contract (implemented in MapTilePlanner.swift):
// MapTilePlanner.aroundGCJ02(latitudeDeg: Double, longitudeDeg: Double,
//                          radiusM: Double, zoom: Int) throws -> [MapTileID]
// Inputs and scene geometry are GCJ-02; tile IDs identify Web Mercator z15 tiles,
// or z14 while the rider has the round display zoomed out.
import Combine
import Foundation

struct MapTileID: Codable, Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int

    init(z: Int = 15, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    var isValid: Bool { (14 ... 15).contains(z) && (0 ..< 1 << z).contains(x) && (0 ..< 1 << z).contains(y) }
    var filename: String { "\(z)-\(x)-\(y).json" }
}

/// The area a city search result covers, as reported by the gateway.
enum MapAreaScope: String, Codable, Sendable {
    case city, district

    var text: String {
        switch self {
        case .city: L("Whole city")
        case .district: L("District")
        }
    }
}

/// What a saved pack covers. Names are the user's data (a city or a
/// destination); the words around them are produced when displayed, so a
/// saved pack follows the interface language.
enum MapPackLabel: Equatable, Sendable {
    case city(name: String, scope: MapAreaScope)
    case route(destination: String?)
    /// Packs saved before localization kept finished text; shown as saved.
    case legacy(name: String, detail: String)

    var title: String {
        switch self {
        case let .city(name, _): name
        case let .route(destination): L("To \(destination ?? L("destination"))")
        case let .legacy(name, _): name
        }
    }

    var detail: String {
        switch self {
        case let .city(_, scope): scope.text
        case .route: L("Selected route and about one kilometre around it")
        case let .legacy(_, detail): detail
        }
    }
}

struct MapDownloadPack: Identifiable, Equatable, Sendable {
    let id: String
    let label: MapPackLabel
    let byteCount: Int64
    let tileCount: Int
    let downloadedPercent: Int
    var isComplete: Bool { downloadedPercent == 100 }

    var detail: String {
        isComplete ? label.detail : L("\(label.detail) · \(downloadedPercent)% downloaded")
    }
}

/// Surrounding-map state; the text is produced when displayed.
enum SurroundingMapStatus: Equatable, Sendable {
    case standby, noMapHere, updatingCached, loadingOnline, readyFromCache, online
    case offlineCached, offlinePartial, unavailable

    var text: String {
        switch self {
        case .standby: L("Online maps first, offline maps as backup")
        case .noMapHere: L("No surrounding map for this location yet")
        case .updatingCached: L("Updating · Surroundings cached")
        case .loadingOnline: L("Loading the online surroundings")
        case .readyFromCache: L("Surrounding map ready · From cache")
        case .online: L("Online surrounding map")
        case .offlineCached: L("Offline map · This area is cached")
        case .offlinePartial: L("Offline map · This area is only partly covered")
        case .unavailable: L("Online map unavailable · No offline map here")
        }
    }
}

/// Download progress and results; the text, reasons included, is produced
/// when displayed.
enum MapDownloadMessage {
    case preparing
    case progress(bytes: Int64, percent: Int)
    case complete, paused, cacheCleared, manifestRecovered
    case pausedAfterError(any Error)
    case readFailed(any Error)
    case failure(any Error)

    var text: String {
        switch self {
        case .preparing: L("Preparing the download…")
        case let .progress(bytes, percent):
            L("\(NavFormatting.byteCount(bytes)) downloaded · \(percent)%")
        case .complete: L("Download complete, available offline")
        case .paused: L("Download paused; you can resume it")
        case .cacheCleared: L("Temporary cache cleared; downloaded maps kept")
        case .manifestRecovered:
            L("The offline map list was damaged; the original file was kept. Add the areas you need again.")
        case let .pausedAfterError(error):
            L("Download paused: \(localizedMessage(for: error)). The finished part was kept.")
        case let .readFailed(error): L("Could not read the offline maps: \(localizedMessage(for: error))")
        case let .failure(error): localizedMessage(for: error)
        }
    }
}

enum SurroundingMapError: LocalizedError {
    case invalidTile, invalidResponse, responseTooLarge, storageLimit, tooManyTiles, missingPack
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidTile: return L("Invalid map area")
        case .invalidResponse: return L("Invalid map data")
        case .responseTooLarge: return L("A map tile exceeds the size limit")
        case .storageLimit: return L("Offline maps reached the 512 MB limit; delete areas you no longer need")
        case .tooManyTiles: return L("The download area is too large; choose a smaller city area or route")
        case .missingPack: return L("This offline map was not found")
        case .httpStatus(let status):
            return status == 429 ? L("The map service is busy; continue later") : L("The map service is unavailable right now")
        }
    }
}

struct MapTileDocument: Codable, Sendable {
    let schemaVersion: Int
    let coordinateSystem: String
    let tile: MapTileID
    let roads: [OfflineMapRoad]
    let buildings: [OfflineMapBuilding]
    let source: OfflineMapSource

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", coordinateSystem = "coordinate_system"
        case tile, roads, buildings, source
    }

    static let maximumBytes = 8 * 1_024 * 1_024

    static func decode(_ data: Data, expectedTile: MapTileID) throws -> Self {
        guard data.count <= maximumBytes else { throw SurroundingMapError.responseTooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard expectedTile.isValid, value.tile == expectedTile,
              value.schemaVersion == 1, value.coordinateSystem == "GCJ-02",
              value.roads.count + value.buildings.count <= 12_000,
              value.source.provider.count <= 1_024,
              value.source.licence.count <= 1_024,
              value.source.attributionURL.count <= 2_048,
              value.source.retrievedAt.count <= 128,
              value.source.bboxWGS84.map({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) ?? true
        else { throw SurroundingMapError.invalidResponse }
        let roadClasses: Set<String> = ["motorway", "primary", "secondary", "residential", "service", "other"]
        let buildingClasses: Set<String> = ["generic", "landmark", "parking"]
        var pointCount = 0
        func validPoints(_ points: [OfflineMapPointE6], minimum: Int) -> Bool {
            pointCount += points.count
            return (minimum ... 2_048).contains(points.count) && pointCount <= 120_000 &&
                points.allSatisfy {
                    (-90_000_000 ... 90_000_000).contains($0.latitudeE6) &&
                    (-180_000_000 ... 180_000_000).contains($0.longitudeE6)
                }
        }
        guard value.roads.allSatisfy({ roadClasses.contains($0.roadClass) && validPoints($0.points, minimum: 2) }),
              value.buildings.allSatisfy({
                  buildingClasses.contains($0.buildingClass) && ($0.name?.count ?? 0) <= 1_024 &&
                  validPoints($0.points, minimum: 3) && $0.points.first != $0.points.last
              })
        else { throw SurroundingMapError.invalidResponse }
        return value
    }
}

/// A single disk owner serializes manifests, quota checks and shared tile writes.
/// Downloaded packs pin tiles; automatic navigation cache uses only unpinned space.
actor MapTileCache {
    typealias Loader = @Sendable (MapTileID) async throws -> Data
    private struct SavedPack: Codable {
        let id: String
        /// City or destination name (user data); nil for a route without one.
        let name: String?
        /// Present only in packs saved before localization.
        let detail: String?
        /// "city" or "route"; nil in packs saved before localization.
        let kind: String?
        let scope: MapAreaScope?
        let tiles: [MapTileID]

        init(id: String, label: MapPackLabel, tiles: [MapTileID]) {
            self.id = id
            self.tiles = tiles
            switch label {
            case let .city(name, scope):
                (self.name, detail, kind, self.scope) = (String(name.prefix(120)), nil, "city", scope)
            case let .route(destination):
                (name, detail, kind, scope) = (destination.map { String($0.prefix(120)) }, nil, "route", nil)
            case let .legacy(name, detail):
                (self.name, self.detail, kind, scope) = (name, detail, nil, nil)
            }
        }

        var label: MapPackLabel {
            switch kind {
            case "city": .city(name: name ?? "", scope: scope ?? .city)
            case "route": .route(destination: name)
            default: .legacy(name: name ?? "", detail: detail ?? "")
            }
        }
    }

    private let root: URL
    private var loader: Loader
    private var loaderGeneration: UInt64 = 0
    private let cacheLimit: Int64
    private let cacheTileLimit: Int
    private let packLimit: Int64
    private var initialized = false
    private var savedPacks: [SavedPack] = []
    private var inFlight: [MapTileID: Task<MapTileDocument, Error>] = [:]
    private struct CachedFile {
        let size: Int64
        let date: Date
    }
    private var files: [MapTileID: CachedFile] = [:]
    private var pinnedTiles: Set<MapTileID> = []
    private var pinnedBytes: Int64 = 0
    private var temporaryBytes: Int64 = 0
    private var temporaryCount = 0
    private var writeEpochs: [MapTileID: UInt64] = [:]
    private var nextBulkRequestAt = Date.distantPast
    private var manifestRecovered = false

    init(root: URL, cacheLimit: Int64 = 128 * 1_024 * 1_024, cacheTileLimit: Int = 10_000,
         packLimit: Int64 = 512 * 1_024 * 1_024, loader: @escaping Loader) {
        self.root = root
        self.cacheLimit = cacheLimit
        self.cacheTileLimit = cacheTileLimit
        self.packLimit = packLimit
        self.loader = loader
    }

    private var tilesURL: URL { root.appendingPathComponent("tiles", isDirectory: true) }
    private var manifestURL: URL { root.appendingPathComponent("packs.json") }

    private func initialize() throws {
        guard !initialized else { return }
        try FileManager.default.createDirectory(at: tilesURL, withIntermediateDirectories: true)
        var location = root
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try location.setResourceValues(resources)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                guard try fileBytes(manifestURL) <= 16 * 1_024 * 1_024 else { throw SurroundingMapError.invalidResponse }
                let data = try Data(contentsOf: manifestURL)
                savedPacks = try JSONDecoder().decode([SavedPack].self, from: data)
                guard savedPacks.count <= 256, Set(savedPacks.map(\.id)).count == savedPacks.count,
                      savedPacks.allSatisfy({ !$0.tiles.isEmpty && $0.tiles.allSatisfy(\.isValid) }),
                      Set(savedPacks.flatMap(\.tiles)).count <= 40_000
                else { throw SurroundingMapError.invalidResponse }
            } catch {
                // Keep the original manifest for recovery, while valid tiles
                // remain reusable and an unrelated download can still proceed.
                try FileManager.default.moveItem(at: manifestURL,
                    to: root.appendingPathComponent("packs.corrupt-\(UUID().uuidString).json"))
                savedPacks = []
                manifestRecovered = true
            }
        }
        for url in try FileManager.default.contentsOfDirectory(
            at: tilesURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard url.pathExtension == "json", parts.count == 3,
                  let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { continue }
            let tile = MapTileID(z: z, x: x, y: y)
            guard tile.isValid else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            files[tile] = CachedFile(size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
        }
        refreshPinAccounting()
        initialized = true
        try trimTemporaryCache()
    }

    private func saveManifest(_ packs: [SavedPack]) throws {
        let data = try JSONEncoder().encode(packs)
        guard packs.count <= 256, data.count <= 16 * 1_024 * 1_024 else { throw SurroundingMapError.tooManyTiles }
        try data.write(to: manifestURL, options: .atomic)
        savedPacks = packs
        refreshPinAccounting()
    }

    private func refreshPinAccounting() {
        pinnedTiles = Set(savedPacks.flatMap(\.tiles))
        pinnedBytes = 0
        temporaryBytes = 0
        temporaryCount = 0
        for (tile, file) in files {
            if pinnedTiles.contains(tile) { pinnedBytes += file.size }
            else { temporaryBytes += file.size; temporaryCount += 1 }
        }
    }

    private func recordFile(_ tile: MapTileID, file: CachedFile?) {
        let delta = (file?.size ?? 0) - (files[tile]?.size ?? 0)
        if pinnedTiles.contains(tile) { pinnedBytes += delta }
        else {
            temporaryBytes += delta
            temporaryCount += (file == nil ? 0 : 1) - (files[tile] == nil ? 0 : 1)
        }
        files[tile] = file
    }

    func cached(_ tile: MapTileID) throws -> MapTileDocument? {
        try initialize()
        guard tile.isValid else { throw SurroundingMapError.invalidTile }
        let url = tilesURL.appendingPathComponent(tile.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            recordFile(tile, file: nil)
            return nil
        }
        do {
            guard try fileBytes(url) <= Int64(MapTileDocument.maximumBytes) else {
                throw SurroundingMapError.responseTooLarge
            }
            return try MapTileDocument.decode(Data(contentsOf: url), expectedTile: tile)
        } catch {
            // A corrupt tile becomes a resumable missing tile, never a completed
            // pack or a persistent source of malformed BLE geometry.
            try? FileManager.default.removeItem(at: url)
            recordFile(tile, file: nil)
            return nil
        }
    }

    func replaceLoader(_ newLoader: @escaping Loader) {
        loaderGeneration &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        loader = newLoader
        nextBulkRequestAt = .distantPast
    }

    func fetch(_ tile: MapTileID, refresh: Bool) async throws -> MapTileDocument {
        let currentLoader = loaderGeneration
        try initialize()
        guard tile.isValid else { throw SurroundingMapError.invalidTile }
        if !refresh, let value = try cached(tile) { return value }
        if let request = inFlight[tile] { return try await request.value }
        if !refresh {
            let delay = max(0, nextBulkRequestAt.timeIntervalSinceNow)
            nextBulkRequestAt = Date().addingTimeInterval(delay + 0.25)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            try Task.checkCancellation()
            guard currentLoader == loaderGeneration else { throw CancellationError() }
            if let value = try cached(tile) { return value }
            if let request = inFlight[tile] { return try await request.value }
        }
        let epoch = writeEpochs[tile, default: 0]
        let request = Task<MapTileDocument, Error> { [self, loader] in
            let data = try await loader(tile)
            let document = try MapTileDocument.decode(data, expectedTile: tile)
            try Task.checkCancellation()
            guard currentLoader == loaderGeneration, writeEpochs[tile, default: 0] == epoch else {
                throw CancellationError()
            }
            try write(data, tile: tile)
            return document
        }
        inFlight[tile] = request
        defer {
            if currentLoader == loaderGeneration { inFlight[tile] = nil }
        }
        return try await request.value
    }

    func isFresh(_ tile: MapTileID) -> Bool {
        guard let file = files[tile] else { return false }
        // Refresh at most daily, including pinned city/corridor tiles. Cache
        // hits remain labelled as cached data rather than proof of connectivity.
        return Date().timeIntervalSince(file.date) < 24 * 60 * 60
    }

    func byteCount(of tile: MapTileID) -> Int64 { files[tile]?.size ?? 0 }

    func takeManifestRecovered() -> Bool {
        defer { manifestRecovered = false }
        return manifestRecovered
    }

    private func write(_ data: Data, tile: MapTileID) throws {
        if pinnedTiles.contains(tile) {
            guard pinnedBytes - (files[tile]?.size ?? 0) + Int64(data.count) <= packLimit else {
                throw SurroundingMapError.storageLimit
            }
        }
        try data.write(to: tilesURL.appendingPathComponent(tile.filename), options: .atomic)
        recordFile(tile, file: CachedFile(size: Int64(data.count), date: Date()))
        try trimTemporaryCache()
    }

    func createPack(label: MapPackLabel, tiles: [MapTileID]) throws -> String {
        try initialize()
        let unique = Array(Set(tiles)).sorted { $0.filename < $1.filename }
        guard !unique.isEmpty, unique.allSatisfy(\.isValid) else { throw SurroundingMapError.invalidTile }
        let candidate = SavedPack(id: UUID().uuidString, label: label, tiles: unique)
        if let existing = savedPacks.first(where: {
            $0.kind == candidate.kind && $0.name == candidate.name && $0.tiles == unique
        }) {
            return existing.id
        }
        let allPinned = pinnedTiles.union(unique)
        guard allPinned.count <= 40_000 else { throw SurroundingMapError.tooManyTiles }
        let total = allPinned.reduce(Int64(0)) { $0 + (files[$1]?.size ?? 0) }
        guard total <= packLimit else { throw SurroundingMapError.storageLimit }
        try saveManifest(savedPacks + [candidate])
        return candidate.id
    }

    func tiles(for id: String) throws -> [MapTileID] {
        try initialize()
        guard let pack = savedPacks.first(where: { $0.id == id }) else { throw SurroundingMapError.missingPack }
        return pack.tiles
    }

    func packs() throws -> [MapDownloadPack] {
        try initialize()
        return savedPacks.map { pack in
            var count = 0
            var bytes: Int64 = 0
            for tile in pack.tiles {
                let size = files[tile]?.size ?? 0
                if size > 0 { count += 1; bytes += size }
            }
            let percent = count == pack.tiles.count ? 100
                : min(99, Int(Double(count) / Double(pack.tiles.count) * 100))
            return MapDownloadPack(id: pack.id, label: pack.label, byteCount: bytes,
                                   tileCount: pack.tiles.count, downloadedPercent: percent)
        }
    }

    func deletePack(id: String) throws {
        try initialize()
        let removed = savedPacks.first { $0.id == id }
        let remaining = savedPacks.filter { $0.id != id }
        try saveManifest(remaining)
        let retained = Set(remaining.flatMap(\.tiles))
        for tile in removed?.tiles ?? [] where !retained.contains(tile) {
            writeEpochs[tile, default: 0] &+= 1
            let url = tilesURL.appendingPathComponent(tile.filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            recordFile(tile, file: nil)
        }
    }

    func clearTemporaryCache() throws {
        try initialize()
        for tile in inFlight.keys where !pinnedTiles.contains(tile) { writeEpochs[tile, default: 0] &+= 1 }
        try trimTemporaryCache(limit: 0)
    }

    private func trimTemporaryCache(limit: Int64? = nil) throws {
        // Byte limits count JSON payload bytes. A separate count bound prevents
        // tiny empty tiles from consuming excessive filesystem allocation.
        let byteLimit = limit ?? cacheLimit
        let countLimit = limit == 0 ? 0 : cacheTileLimit
        guard temporaryBytes > byteLimit || temporaryCount > countLimit else { return }
        let entries = files.filter { !pinnedTiles.contains($0.key) }.sorted { $0.value.date < $1.value.date }
        for (tile, _) in entries where temporaryBytes > byteLimit || temporaryCount > countLimit {
            let url = tilesURL.appendingPathComponent(tile.filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            recordFile(tile, file: nil)
        }
    }

    private func fileBytes(_ url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
}

@MainActor
final class SurroundingMapStore: ObservableObject {
    @Published private(set) var status = SurroundingMapStatus.standby
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var downloadMessage: MapDownloadMessage?
    @Published private(set) var packs: [MapDownloadPack] = []
    var onScene: ((OfflineMapSceneWindow) -> Void)?

    private let cache: MapTileCache
    private let fallback: (any OfflineMapSceneQuerying)?
    private var sceneTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var downloadGeneration: UInt64 = 0
    private var revision: UInt32 = 0
    private var lastOrigin: OfflineMapPointE6?
    private var lastPosition: (latitudeDeg: Double, longitudeDeg: Double)?
    private var retryAfter: Date?
    private var activeDownloadID: String?
    /// The round display's scale: 15 shows about 500 m around the rider, 14
    /// twice that, from z14 tiles.
    private(set) var zoomLevel: UInt8 = 15
    private var sceneRadiusM: UInt16 { zoomLevel == 14 ? 1_000 : 500 }

    init(baseURL: URL, bundle: Bundle = .main, storageURL: URL? = nil,
         loader: MapTileCache.Loader? = nil) {
        let storage = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
            .appendingPathComponent("SurroundingMaps", isDirectory: true)
        cache = MapTileCache(root: storage, loader: loader ?? Self.httpLoader(baseURL: baseURL))
        let bundled = bundle.url(forResource: "jinan-v1", withExtension: "sqlite")
        fallback = try? OfflineMapSceneCoordinator.loadIndex(
            databaseURLs: bundled.map { [$0] } ?? [],
            sampleURL: bundle.url(forResource: "jinan_map_scene_sample", withExtension: "json"))
        Task { [weak self] in await self?.reloadPacks() }
    }

    deinit {
        sceneTask?.cancel()
        downloadTask?.cancel()
    }

    func update(latitudeDeg: Double, longitudeDeg: Double) {
        guard latitudeDeg.isFinite, longitudeDeg.isFinite,
              (-85.0 ... 85.0).contains(latitudeDeg), (-180.0 ... 180.0).contains(longitudeDeg)
        else { return }
        let origin = OfflineMapPointE6(latitudeE6: Int32((latitudeDeg * 1_000_000).rounded()),
                                     longitudeE6: Int32((longitudeDeg * 1_000_000).rounded()))
        lastPosition = (latitudeDeg, longitudeDeg)
        if let lastOrigin, Self.distance(lastOrigin, origin) < 100,
           retryAfter.map({ Date() < $0 }) ?? true { return }
        let tiles: [MapTileID]
        do {
            tiles = Array(Set(try MapTilePlanner.aroundGCJ02(latitudeDeg: latitudeDeg,
                                                           longitudeDeg: longitudeDeg,
                                                           radiusM: Double(sceneRadiusM),
                                                           zoom: Int(zoomLevel))))
            guard !tiles.isEmpty, tiles.count <= 64, tiles.allSatisfy(\.isValid) else {
                throw SurroundingMapError.invalidTile
            }
        } catch {
            status = .noMapHere
            return
        }
        lastOrigin = origin
        retryAfter = nil
        generation &+= 1
        let current = generation
        sceneTask?.cancel()
        sceneTask = Task { [weak self] in
            guard let self else { return }
            var documents: [MapTileID: MapTileDocument] = [:]
            var needsRefresh: [MapTileID] = []
            for tile in tiles {
                if let document = try? await self.cache.cached(tile) { documents[tile] = document }
                let fresh = await self.cache.isFresh(tile)
                if documents[tile] == nil || !fresh { needsRefresh.append(tile) }
            }
            guard !Task.isCancelled, self.generation == current else { return }
            self.emit(documents: Array(documents.values), origin: origin,
                      includeFallback: documents.count != tiles.count)
            self.status = documents.count == tiles.count ? .updatingCached : .loadingOnline
            var failed = false
            // A small viewport normally touches 4–9 tiles. Bounded concurrency
            // keeps navigation and user-initiated downloads responsive.
            for start in stride(from: 0, to: needsRefresh.count, by: 4) {
                guard !Task.isCancelled, self.generation == current else { return }
                let batch = Array(needsRefresh[start ..< min(start + 4, needsRefresh.count)])
                let results = await withTaskGroup(of: (MapTileID, MapTileDocument?).self) { group in
                    for tile in batch {
                        group.addTask { [cache = self.cache] in
                            (tile, try? await cache.fetch(tile, refresh: true))
                        }
                    }
                    var values: [(MapTileID, MapTileDocument?)] = []
                    for await result in group { values.append(result) }
                    return values
                }
                for (tile, result) in results {
                    if let result { documents[tile] = result } else { failed = true }
                }
            }
            guard !Task.isCancelled, self.generation == current else { return }
            let complete = documents.count == tiles.count
            let hasOfflineGeometry = self.emit(documents: Array(documents.values), origin: origin, includeFallback: !complete)
            if !failed && complete {
                self.status = needsRefresh.isEmpty ? .readyFromCache : .online
                self.retryAfter = Date().addingTimeInterval(24 * 60 * 60)
            } else {
                self.retryAfter = Date().addingTimeInterval(30)
                self.status = complete ? .offlineCached : (hasOfflineGeometry ? .offlinePartial : .unavailable)
            }
            await self.reloadPacks()
        }
    }

    /// Rebuilds the surroundings at once at the new scale, from the last position.
    func setZoomLevel(_ level: UInt8) {
        guard level == 14 || level == 15, level != zoomLevel else { return }
        zoomLevel = level
        lastOrigin = nil
        retryAfter = nil
        if let lastPosition {
            update(latitudeDeg: lastPosition.latitudeDeg, longitudeDeg: lastPosition.longitudeDeg)
        }
    }

    func changeGateway(to baseURL: URL) async {
        reset()
        cancelDownload()
        await cache.replaceLoader(Self.httpLoader(baseURL: baseURL))
    }

    func reset() {
        generation &+= 1
        sceneTask?.cancel()
        sceneTask = nil
        lastOrigin = nil
        lastPosition = nil
        retryAfter = nil
        status = .standby
    }

    func download(_ label: MapPackLabel, tiles: [MapTileID]) {
        startDownload {
            try await self.cache.createPack(label: label, tiles: tiles)
        }
    }

    func resume(_ pack: MapDownloadPack) {
        startDownload { pack.id }
    }

    private func startDownload(resolveID: @escaping @MainActor () async throws -> String) {
        cancelDownload()
        downloadGeneration &+= 1
        let current = downloadGeneration
        isDownloading = true
        downloadProgress = 0
        downloadMessage = .preparing
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await resolveID()
                guard !Task.isCancelled, self.downloadGeneration == current else { return }
                self.activeDownloadID = id
                let tiles = try await self.cache.tiles(for: id)
                var verifiedBytes: Int64 = 0
                await self.reloadPacks()
                for (index, tile) in tiles.enumerated() {
                    try Task.checkCancellation()
                    _ = try await self.cache.fetch(tile, refresh: false)
                    try Task.checkCancellation()
                    guard self.downloadGeneration == current else { return }
                    self.downloadProgress = Double(index + 1) / Double(tiles.count)
                    verifiedBytes += await self.cache.byteCount(of: tile)
                    self.downloadMessage = .progress(bytes: verifiedBytes,
                                                     percent: Int(self.downloadProgress * 100))
                }
                self.downloadMessage = .complete
            } catch is CancellationError {
                if self.downloadGeneration == current { self.downloadMessage = .paused }
            } catch {
                if self.downloadGeneration == current {
                    self.downloadMessage = .pausedAfterError(error)
                }
            }
            guard self.downloadGeneration == current else { return }
            self.isDownloading = false
            self.activeDownloadID = nil
            await self.reloadPacks()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        isDownloading = false
        activeDownloadID = nil
        if downloadMessage != nil { downloadMessage = .paused }
        Task { [weak self] in await self?.reloadPacks() }
    }

    func delete(_ pack: MapDownloadPack) {
        if activeDownloadID == pack.id { cancelDownload() }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cache.deletePack(id: pack.id)
                await self.reloadPacks()
            } catch { self.downloadMessage = .failure(error) }
        }
    }

    func clearTemporaryCache() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cache.clearTemporaryCache()
                self.downloadMessage = .cacheCleared
            } catch { self.downloadMessage = .failure(error) }
        }
    }

    private func reloadPacks() async {
        do {
            packs = try await cache.packs()
            if await cache.takeManifestRecovered() { downloadMessage = .manifestRecovered }
        }
        catch { downloadMessage = .readFailed(error) }
    }

    private struct RoadKey: Hashable {
        let id: Int64?
        let kind: String
        let points: [OfflineMapPointE6]
    }

    @discardableResult
    private func emit(documents: [MapTileDocument], origin: OfflineMapPointE6, includeFallback: Bool) -> Bool {
        var roads: [OfflineMapRoad] = []
        var buildings: [OfflineMapBuilding] = []
        var roadKeys: Set<RoadKey> = []
        var buildingKeys: Set<RoadKey> = []
        let backup = includeFallback ? fallback?.query(around: origin, radiusM: sceneRadiusM, revision: 0) : nil
        for road in documents.flatMap(\.roads) + (backup?.roads ?? []) {
            if roadKeys.insert(RoadKey(id: road.osmWayID, kind: road.roadClass, points: road.points)).inserted {
                roads.append(road)
            }
        }
        for building in documents.flatMap(\.buildings) + (backup?.buildings ?? []) {
            if buildingKeys.insert(RoadKey(id: building.osmWayID, kind: building.buildingClass, points: building.points)).inserted {
                buildings.append(building)
            }
        }
        revision &+= 1
        if revision == 0 { revision = 1 }
        let document = OfflineMapSceneDocument(schemaVersion: 1, coordinateSystem: "GCJ-02",
                                              sceneRevision: revision, viewOrigin: origin, radiusM: sceneRadiusM,
                                              roads: roads, buildings: buildings,
                                              source: OfflineMapSource(provider: "map-tiles", licence: "ODbL-1.0",
                                                                       attributionURL: "https://www.openstreetmap.org/copyright",
                                                                       retrievedAt: "", bboxWGS84: nil))
        let window = InMemoryOfflineMapSceneIndex(document: document).query(around: origin, radiusM: sceneRadiusM,
                                                                             revision: revision)
        onScene?(window)
        return !window.roads.isEmpty || !window.buildings.isEmpty
    }

    private static func distance(_ first: OfflineMapPointE6, _ second: OfflineMapPointE6) -> Double {
        let latitude = Double(second.latitudeE6) / 1_000_000 * .pi / 180
        return hypot(Double(first.latitudeE6 - second.latitudeE6) * 0.111195,
                     Double(first.longitudeE6 - second.longitudeE6) * 0.111195 * cos(latitude))
    }

    private static func httpLoader(baseURL: URL) -> MapTileCache.Loader {
        { tile in
            let url = baseURL.appendingPathComponent("v1/map/tiles/\(tile.z)/\(tile.x)/\(tile.y)")
            guard url.scheme == "https" || AppConfiguration.isLocalHTTP(url) else {
                throw SurroundingMapError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for attempt in 0 ..< 3 {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw SurroundingMapError.invalidResponse }
                if http.statusCode == 429, attempt < 2 {
                    bytes.task.cancel()
                    let header = http.value(forHTTPHeaderField: "Retry-After") ?? ""
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    let requestedDelay = Double(header) ?? formatter.date(from: header)?.timeIntervalSinceNow ?? Double(attempt + 1)
                    let delay = requestedDelay.isFinite ? min(30, max(0.25, requestedDelay)) : Double(attempt + 1)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                guard (200 ..< 300).contains(http.statusCode) else { throw SurroundingMapError.httpStatus(http.statusCode) }
                guard response.expectedContentLength <= Int64(MapTileDocument.maximumBytes) else {
                    throw SurroundingMapError.responseTooLarge
                }
                var data = Data()
                data.reserveCapacity(Int(max(0, min(response.expectedContentLength, 512 * 1_024))))
                for try await byte in bytes {
                    guard data.count < MapTileDocument.maximumBytes else { throw SurroundingMapError.responseTooLarge }
                    data.append(byte)
                }
                return data
            }
            throw SurroundingMapError.invalidResponse
        }
    }
}
