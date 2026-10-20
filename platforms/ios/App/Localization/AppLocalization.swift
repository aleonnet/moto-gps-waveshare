import Foundation
import MotoNavigationCore
import Observation

/// The interface language chosen in Settings. `.system` follows iOS, including
/// the per-app language in the iOS Settings app.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case portuguese = "pt-BR"
    case chinese = "zh-Hans"

    var id: String { rawValue }
}

/// Resolves every interface string in the selected language. It is observable
/// the way the @Observable macro expands: a view whose body reads text through
/// `L(...)`, directly or from a model property, depends on the language and is
/// redrawn in place when it changes, keeping its state. The registrar records
/// reads made on the thread evaluating the body (ObservationRegistrar.access);
/// reads elsewhere are not tracked.
final class AppLocalization: Observable, @unchecked Sendable {
    static let shared = AppLocalization()
    static let defaultsKey = "MotoGPS.AppLanguage.v1"
    static let localizations = ["en", "pt-BR", "zh-Hans"]

    private struct Selection {
        let language: AppLanguage
        let localization: String
        let bundle: Bundle
    }

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let bundle: Bundle
    private var selection: Selection

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        let stored = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:))
        selection = Self.resolve(stored ?? .system, bundle: bundle)
    }

    var language: AppLanguage {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { selection.language }
    }

    /// The localization in use: "en", "pt-BR" or "zh-Hans".
    var localization: String {
        registrar.access(self, keyPath: \.localization)
        return lock.withLock { selection.localization }
    }

    var locale: Locale { Locale(identifier: localization) }

    /// What "System" resolves to, whatever is selected now: the iOS language
    /// for this app, fixed while the app runs.
    var systemLocalization: String { Self.resolve(.system, bundle: bundle).localization }

    /// BCP 47 tag sent to the round display.
    var deviceLanguageTag: String {
        let localization = localization
        return localization == "en" ? "en-US" : localization
    }

    func select(_ language: AppLanguage) {
        let resolved = Self.resolve(language, bundle: bundle)
        registrar.withMutation(of: self, keyPath: \.language) {
            registrar.withMutation(of: self, keyPath: \.localization) {
                lock.withLock { selection = resolved }
            }
        }
        if language == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    func string(_ resource: LocalizedStringResource) -> String {
        registrar.access(self, keyPath: \.localization)
        let current = lock.withLock { selection }
        // The value carries the extracted key ("Route to %@") and its
        // arguments; looking it up in one .lproj forces that language.
        return String(localized: resource.defaultValue, table: resource.table,
                      bundle: current.bundle, locale: Locale(identifier: current.localization))
    }

    private static func resolve(_ language: AppLanguage, bundle: Bundle) -> Selection {
        let localization = language == .system
            ? bundle.preferredLocalizations.first(where: localizations.contains) ?? "en"
            : language.rawValue
        let lproj = bundle.url(forResource: localization, withExtension: "lproj").flatMap(Bundle.init(url:))
        return Selection(language: language, localization: localization, bundle: lproj ?? bundle)
    }
}

/// Interface text in the selected language. Xcode extracts the literal into
/// Localizable.xcstrings because the parameter is a LocalizedStringResource.
func L(_ resource: LocalizedStringResource) -> String {
    AppLocalization.shared.string(resource)
}

/// Distances, durations and sizes in the selected language. Distances stay
/// metric like the round display and the BLE protocol.
enum NavFormatting {
    static func distance(meters: Double, locale: Locale = AppLocalization.shared.locale) -> String {
        guard meters.isFinite, meters > 0 else { return "--" }
        if meters < 1_000 {
            return Measurement(value: meters.rounded(), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(0)))
                    .locale(locale))
        }
        return Measurement(value: meters / 1_000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1)))
                .locale(locale))
    }

    /// Whole minutes, at least one, as hours and minutes.
    static func duration(seconds: Int, locale: Locale = AppLocalization.shared.locale) -> String {
        guard seconds > 0 else { return "--" }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated,
                              zeroValueUnits: .hide).locale(locale))
    }

    static func byteCount(_ bytes: Int64, locale: Locale = AppLocalization.shared.locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}

/// A message kept as its source and translated when it is shown, so one raised
/// before a language change reads in the new language.
enum AppMessage {
    case localized(LocalizedStringResource)
    case error(any Error)

    var text: String {
        switch self {
        case let .localized(resource): L(resource)
        case let .error(error): localizedMessage(for: error)
        }
    }
}

/// Errors from MotoNavigationCore are presented here because the package has
/// no access to the app's language selection.
func localizedMessage(for error: Error) -> String {
    switch error {
    case GatewayAddressError.invalidAddress:
        L("Enter a valid HTTPS gateway address without user name, password, query or #.")
    case GatewayAddressError.endpointInsteadOfBase:
        L("Enter the gateway root address, without /healthz or /v1/... paths.")
    case NavigationSourceError.permissionDenied:
        L("Background location is not allowed")
    default:
        error.localizedDescription
    }
}
