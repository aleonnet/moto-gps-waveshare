import Foundation

public protocol NavigationRouteProviding: Sendable {
    func route(for request: RouteRequest) async throws -> RouteEnvelope
}

@MainActor
public protocol NavigationLocationSource: AnyObject {
    func start(
        onFix: @escaping @MainActor (NavigationFix) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) throws

    func stop()
}

public enum NavigationSourceError: LocalizedError, Equatable {
    case permissionDenied

    public var errorDescription: String? {
        "background location is not allowed"
    }
}
