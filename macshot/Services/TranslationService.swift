import Foundation

/// Routing front-end for translation.
///
/// Everything else in the app (the overlay tool, the OCR window, the
/// `macshot://ocr-translate` URL handler) asks this type for a translation and
/// works only with canonical language codes. Engines, credentials, vendor
/// language codes, request budgets and rate limits live in
/// `Services/Translation/`; nothing outside that folder needs to know which
/// vendor is active.
enum TranslationService {

    private static let providerDefaultsKey = "translationProvider"
    private static let targetLanguageDefaultsKey = "translateTargetLang"

    // MARK: - Provider

    /// The selected engine.
    ///
    /// Reads are validated: a stored value for an engine this system cannot run
    /// (Apple below macOS 15) falls back to the default exactly like a missing
    /// value does, so an upgraded or downgraded install never lands on an engine
    /// that cannot translate.
    static var provider: TranslationProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: providerDefaultsKey) ?? ""
            let stored = TranslationProvider(rawValue: raw) ?? TranslationEngineRegistry.fallbackProvider
            return TranslationEngineRegistry.resolved(stored)
        }
        set {
            UserDefaults.standard.set(TranslationEngineRegistry.resolved(newValue).rawValue,
                                      forKey: providerDefaultsKey)
        }
    }

    /// Whether Apple's on-device engine exists on this system (macOS 15+).
    static var appleTranslationAvailable: Bool {
        TranslationEngineRegistry.engine(for: .apple) != nil
    }

    /// The engine backing `provider`. The registry holds Google unconditionally,
    /// so this only falls back if the registry is empty — never a crash for the
    /// callers that translate on a background OCR queue.
    static var currentEngine: TranslationEngine {
        TranslationEngineRegistry.engine(for: provider) ?? GoogleTranslationEngine()
    }

    /// Engines this build can offer, in settings-picker order.
    static var availableEngines: [TranslationEngine] {
        TranslationEngineRegistry.engines
    }

    // MARK: - Target language

    /// The target language, in macshot's canonical codes.
    ///
    /// Clamped to what the current engine supports: switching from Youdao (which
    /// knows Slovak) to Baidu (which does not) must not leave a target the engine
    /// would reject. The stored value is left untouched, so switching back
    /// restores the user's earlier choice.
    static var targetLanguage: String {
        get {
            let stored = UserDefaults.standard.string(forKey: targetLanguageDefaultsKey)
                ?? TranslationLanguageCatalog.fallback.code
            return TranslationLanguageCatalog.resolvedCode(stored, in: currentEngine.languages)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: targetLanguageDefaultsKey)
        }
    }

    /// Languages the given engine can actually be asked for, in display order.
    static func supportedLanguages(for provider: TranslationProvider) -> [TranslationLanguage] {
        (TranslationEngineRegistry.engine(for: provider) ?? GoogleTranslationEngine()).languages
    }

    /// Canonical codes with their Apple language pack installed, for the language
    /// picker. Empty for engines that need no packs.
    @available(macOS 15.0, *)
    static func installedAppleLanguages(completion: @escaping ([String: Bool]) -> Void) {
        AppleTranslationEngine.installedLanguageCodes(completion: completion)
    }

    // MARK: - Translate a batch of strings (auto-detected source language)

    /// Translates multiple strings with the selected engine.
    ///
    /// Always calls back on the main queue, whatever queue the engine answered
    /// on, and always returns one entry per input: blank inputs come back
    /// unchanged so callers keep their line-for-line mapping.
    static func translateBatch(
        texts: [String],
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !texts.isEmpty else {
            completion(.success([]))
            return
        }

        let engine = currentEngine
        let target = TranslationLanguageCatalog.resolvedCode(targetLang, in: engine.languages)
        engine.translate(texts: texts, to: target) { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
