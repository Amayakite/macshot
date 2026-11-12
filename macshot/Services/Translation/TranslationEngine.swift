import Foundation

/// A translation backend, identified by a stable persisted raw value.
///
/// The raw values are written to `UserDefaults["translationProvider"]`, so they
/// are part of the on-disk format: renaming a case silently snaps existing
/// installs back to the default engine. To add a backend, append a case here and
/// add it to `TranslationEngineRegistry`.
enum TranslationProvider: String, CaseIterable {
    /// Apple's on-device Translation framework (macOS 15+).
    case apple = "apple"
    /// Google's web endpoint: no key needed, most languages, needs the network.
    case google = "google"
    /// Baidu Translate open API. Signed, free tier limited to 1 QPS.
    case baidu = "baidu"
    /// Youdao Translate API v3. Signed.
    case youdao = "youdao"
}

/// One language macshot can translate into, in macshot's own code space.
///
/// `code` is what `translateTargetLang` stores and what every caller passes
/// around (`zh-CN`, `zh-TW`, `nb`, …). Vendors get their own spellings through
/// `TranslationLanguageMapping`, never from the caller.
struct TranslationLanguage: Hashable {
    let code: String
    let name: String
}

/// A credential an engine needs before it can run.
struct TranslationCredential: Hashable {
    /// `UserDefaults` key. Names contain `secret`/`apikey` so
    /// `SettingsPortability` keeps them out of exported settings files even
    /// though macshot stores them like any other preference.
    let defaultsKey: String
    /// Unlocalized label key, resolved through `L(…)` by the settings UI so the
    /// engine layer never depends on the active app language.
    let labelKey: String
    /// Whether the field should hide its contents while typing.
    let isSecure: Bool
    let placeholder: String
}

/// One translation backend.
///
/// Engines own everything that differs between vendors — credentials, language
/// codes, request budgets, rate limits — so callers only ever deal with
/// canonical language codes and a completion handler. `TranslationService` is
/// the router; nothing outside `Services/Translation` should call an engine
/// directly.
///
/// Adding an engine is four steps and touches no UI code:
/// 1. Append a case to `TranslationProvider` (the raw value is persisted, so pick
///    a stable string).
/// 2. Add a `struct …: TranslationEngine` with its `TranslationLanguageMapping`,
///    credential list and request policy — `BaiduTranslationEngine` is the
///    smallest complete example.
/// 3. Add it to `TranslationEngineRegistry.allEngines`.
/// 4. Name every credential key so `SettingsPortability.looksSecret` catches it
///    (`…Secret`, `…APIKey`) and list any non-secret half of the pair in
///    `SettingsPortability.excludedKeys`.
/// The settings window, the language pickers and every capture path then offer it
/// automatically.
protocol TranslationEngine {
    var provider: TranslationProvider { get }

    /// Brand name for the engine picker. Brand names stay untranslated, so this
    /// is deliberately *not* routed through `L(…)`.
    var displayName: String { get }

    /// Whether the engine can run on this system at all (Apple needs macOS 15).
    var isAvailable: Bool { get }

    /// Canonical languages this engine accepts, in catalog order. The language
    /// pickers list exactly this, so an engine is never handed a language it
    /// cannot ask its vendor for.
    var languages: [TranslationLanguage] { get }

    /// Credentials the user has to paste in Settings. Empty when none are needed.
    var credentials: [TranslationCredential] { get }

    /// Minimum spacing between requests inside one batch. Baidu's free tier
    /// allows 1 QPS, so its chunks leave about a second apart.
    var minimumRequestInterval: TimeInterval { get }

    /// Longest raw (unencoded) query put in a single request. Multi-line queries
    /// are joined with newlines before this is measured.
    var maximumBytesPerRequest: Int { get }

    /// Translates `texts` in order.
    ///
    /// Blank entries are echoed back unchanged so callers keep their
    /// line-for-line mapping. The completion may fire on any queue —
    /// `TranslationService` re-hops to the main queue for callers.
    func translate(
        texts: [String],
        to target: String,
        completion: @escaping (Result<[String], Error>) -> Void
    )
}

extension TranslationEngine {
    var isAvailable: Bool { true }

    /// Whether every credential this engine asks for is filled in.
    var isConfigured: Bool {
        credentials.allSatisfy { !TranslationCredentials.value(for: $0.defaultsKey).isEmpty }
    }
}

// MARK: - Credentials

/// Credential storage for the engines that need a key.
///
/// Values live in `UserDefaults` like every other macshot preference. The key
/// names are chosen so `SettingsPortability.looksSecret` refuses to export them,
/// and the matching app-id keys are listed in `SettingsPortability.excludedKeys`
/// so an exported settings file never carries half a credential pair.
enum TranslationCredentials {
    static func value(for defaultsKey: String) -> String {
        (UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func set(_ value: String, for defaultsKey: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }
}

// MARK: - Registry

/// The engines this build can offer, in the order the settings picker shows them.
enum TranslationEngineRegistry {

    /// Created once: engines are stateless value types, and rebuilding them per
    /// keystroke of the settings window would only churn allocations.
    private static let allEngines: [TranslationEngine] = [
        AppleTranslationEngine(),
        GoogleTranslationEngine(),
        BaiduTranslationEngine(),
        YoudaoTranslationEngine(),
    ]

    /// Engines usable on this system. Apple drops out below macOS 15, where the
    /// Translation framework does not exist.
    static var engines: [TranslationEngine] {
        allEngines.filter { $0.isAvailable }
    }

    /// Engine for a stored provider value, or nil when this system cannot run it.
    static func engine(for provider: TranslationProvider) -> TranslationEngine? {
        allEngines.first { $0.provider == provider && $0.isAvailable }
    }

    /// Engine used when nothing is stored yet, or when the stored engine is
    /// unavailable: Google needs no key and runs on every supported macOS.
    static let fallbackProvider: TranslationProvider = .google

    /// Coerces a stored/selected provider into one this system can run.
    static func resolved(_ provider: TranslationProvider) -> TranslationProvider {
        engine(for: provider) == nil ? fallbackProvider : provider
    }
}

// MARK: - Errors

/// Failures a user can actually run into. Messages are shown verbatim in the
/// overlay, the OCR window and the settings test row, so they have to say what
/// went wrong and, where possible, what to do about it.
enum TranslationError: LocalizedError {
    case badURL
    case noData
    case httpStatus(Int)
    case parseError
    case emptyResult
    /// The engine needs credentials the user has not entered yet.
    case missingCredentials(String)
    /// The target language is not one this engine can ask its vendor for.
    case unsupportedLanguage(String)
    /// The vendor rejected the request and named the reason (its own error code).
    case service(String)
    /// Apple's framework failed; the payload is already user-readable advice.
    case appleTranslation(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid translation URL"
        case .noData:
            return "No response from translation service"
        case .httpStatus(let code):
            return "Translation service returned HTTP \(code)"
        case .parseError:
            return "Could not parse translation response"
        case .emptyResult:
            return "Translation returned empty result"
        case .missingCredentials(let engine):
            return "\(engine) needs an App ID and secret key. Add them in Settings > Capture > Translation."
        case .unsupportedLanguage(let language):
            return "This translation engine cannot translate into \(language). Pick another language or engine in Settings."
        case .service(let message):
            return message
        case .appleTranslation(let message):
            return message
        }
    }
}
