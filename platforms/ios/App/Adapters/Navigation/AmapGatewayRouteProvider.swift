import Foundation
import MotoNavigationCore

enum AmapGatewayError: LocalizedError {
    case invalidEndpoint
    case rejected(code: String, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            L("Invalid route gateway address")
        case let .rejected(code, _):
            // The gateway's English message is for logs; the stable code
            // selects the text shown to the rider.
            switch code {
            case "NO_ROUTE": L("No route was found to this destination")
            case "RATE_LIMITED": L("Too many route requests; try again shortly")
            case "PROVIDER_TIMEOUT", "PROVIDER_UNAVAILABLE", "PROVIDER_HTTP_ERROR", "PROVIDER_INVALID_JSON":
                L("The route service is unavailable right now")
            case "SERVER_MISCONFIGURED": L("The gateway is not configured for live navigation")
            default: L("The route gateway rejected the request (\(code))")
            }
        case .invalidResponse:
            L("The route gateway returned data that could not be read")
        }
    }
}

/// Calls the project's own gateway. It never accepts or transports an AMap API key.
final class AmapGatewayRouteProvider: NavigationRouteProviding, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        let endpoint = baseURL.appending(path: "v1/routes")
        guard endpoint.scheme == "https" || endpoint.host == "127.0.0.1" || endpoint.host == "localhost" else {
            throw AmapGatewayError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AmapGatewayError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let failure = try? decoder.decode(GatewayFailureEnvelope.self, from: data) {
                throw AmapGatewayError.rejected(
                    code: failure.error.code,
                    message: failure.error.message
                )
            }
            throw AmapGatewayError.invalidResponse
        }
        return try decoder.decode(RouteEnvelope.self, from: data)
    }

    /// Fetches the candidate routes used by the confirmation screen. New
    /// gateways expose all AMap alternatives at `/v1/route-options`; older
    /// gateways are still usable and fall back to their single `/v1/routes`
    /// result. A missing alternatives endpoint is therefore not allowed to
    /// make normal navigation unavailable during a staggered deployment.
    func routeOptions(for request: RouteRequest) async throws -> [RoutePlan] {
        let endpoint = baseURL.appending(path: "v1/route-options")
        guard endpoint.scheme == "https" || endpoint.host == "127.0.0.1" || endpoint.host == "localhost" else {
            throw AmapGatewayError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AmapGatewayError.invalidResponse
        }

        if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 501 {
            let envelope = try await route(for: request)
            return [envelope.route]
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            if let failure = try? decoder.decode(GatewayFailureEnvelope.self, from: data) {
                throw AmapGatewayError.rejected(
                    code: failure.error.code,
                    message: failure.error.message
                )
            }
            throw AmapGatewayError.invalidResponse
        }

        let envelope = try decoder.decode(RouteOptionsEnvelope.self, from: data)
        guard envelope.protocolVersion == 1,
              envelope.requestID == request.requestID
        else {
            throw AmapGatewayError.invalidResponse
        }

        var seen = Set<String>()
        let routes = envelope.routes
            .filter { route in
                route.polyline.count >= 2 &&
                    route.totalDistanceM > 0 &&
                    route.totalDurationS > 0 &&
                    seen.insert(route.routeID).inserted
            }
            .prefix(3)
        guard !routes.isEmpty else {
            throw AmapGatewayError.invalidResponse
        }
        return Array(routes)
    }
}

private struct RouteOptionsEnvelope: Decodable {
    let protocolVersion: Int
    let requestID: UInt32
    let routes: [RoutePlan]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case routes
    }
}

private struct GatewayFailureEnvelope: Decodable {
    let error: GatewayFailure
}

private struct GatewayFailure: Decodable {
    let code: String
    let message: String
}
