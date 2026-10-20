import Foundation
import MotoNavigationCore

enum AppConfiguration {
    /// The offline test gateway started by scripts/ios/run-ui-tests-with-test-gateway.sh.
    /// ATS allows plain HTTP to an unqualified host such as localhost; an IP
    /// literal is blocked since iOS 17.
    static let testGatewayURL = URL(string: "http://localhost:8787/")!

    /// A gateway on the Mac for a bench test on a real iPhone, e.g.
    /// `--moto-local-gateway http://Mac-Name.local:8787/` passed once at launch
    /// (`xcrun devicectl device process launch`), kept until `--moto-reset-gateway`.
    /// ATS allows HTTP to .local names since iOS 10 (NSAllowsLocalNetworking).
    private static let localGatewayKey = "MotoGPS.LocalGatewayURL.v1"

    /// Plain-HTTP gateways are a DEBUG bench aid only.
    static var localTestGatewayURL: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--moto-test-gateway") { return testGatewayURL }
        if let index = arguments.firstIndex(of: "--moto-local-gateway"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]), isLocalHTTP(url) {
            UserDefaults.standard.set(url.absoluteString, forKey: localGatewayKey)
        }
        return UserDefaults.standard.string(forKey: localGatewayKey)
            .flatMap(URL.init(string:)).flatMap { isLocalHTTP($0) ? $0 : nil }
        #else
        return nil
        #endif
    }

    /// HTTP is accepted only for the Mac itself or a .local name on the same network.
    static func isLocalHTTP(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
    }

    /// A gateway saved in Settings replaces the bench one for good.
    static func forgetLocalTestGateway() {
        UserDefaults.standard.removeObject(forKey: localGatewayKey)
    }

    static var gatewayBaseURL: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--moto-reset-gateway") {
            UserDefaults.standard.removeObject(forKey: GatewayConfiguration.defaultsKey)
            UserDefaults.standard.removeObject(forKey: localGatewayKey)
        }
        if let localTestGatewayURL { return localTestGatewayURL }
        #endif
        return GatewayConfiguration.resolvedURL(
            bundledAddress: Bundle.main.object(forInfoDictionaryKey: "MOTOGPSGatewayBaseURL") as? String
        ) ?? URL(string: "https://example.invalid/moto-gps/api/")!
    }
}
