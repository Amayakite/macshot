import Foundation

/// The canonical language list: macshot's own codes, deliberately the ones the
/// UI and `translateTargetLang` have always used (`zh-CN`, `zh-TW`, `nb`).
///
/// Every engine translates these into its vendor's codes; nothing else in the
/// app should hard-code a vendor's spelling of a language.
enum TranslationLanguageCatalog {

    /// Candidates for the target-language pickers, in display order.
    static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "en", name: "English"),
        TranslationLanguage(code: "es", name: "Spanish"),
        TranslationLanguage(code: "fr", name: "French"),
        TranslationLanguage(code: "de", name: "German"),
        TranslationLanguage(code: "it", name: "Italian"),
        TranslationLanguage(code: "pt", name: "Portuguese"),
        TranslationLanguage(code: "nl", name: "Dutch"),
        TranslationLanguage(code: "pl", name: "Polish"),
        TranslationLanguage(code: "ru", name: "Russian"),
        TranslationLanguage(code: "zh-CN", name: "Chinese (Simplified)"),
        TranslationLanguage(code: "zh-TW", name: "Chinese (Traditional)"),
        TranslationLanguage(code: "ja", name: "Japanese"),
        TranslationLanguage(code: "ko", name: "Korean"),
        TranslationLanguage(code: "ar", name: "Arabic"),
        TranslationLanguage(code: "tr", name: "Turkish"),
        TranslationLanguage(code: "sv", name: "Swedish"),
        TranslationLanguage(code: "da", name: "Danish"),
        TranslationLanguage(code: "fi", name: "Finnish"),
        TranslationLanguage(code: "nb", name: "Norwegian"),
        TranslationLanguage(code: "uk", name: "Ukrainian"),
        TranslationLanguage(code: "cs", name: "Czech"),
        TranslationLanguage(code: "ro", name: "Romanian"),
        TranslationLanguage(code: "hu", name: "Hungarian"),
        TranslationLanguage(code: "sk", name: "Slovak"),
        TranslationLanguage(code: "bg", name: "Bulgarian"),
        TranslationLanguage(code: "hr", name: "Croatian"),
        TranslationLanguage(code: "id", name: "Indonesian"),
        TranslationLanguage(code: "hi", name: "Hindi"),
        TranslationLanguage(code: "th", name: "Thai"),
        TranslationLanguage(code: "vi", name: "Vietnamese"),
    ]

    /// Target used when a stored code is unknown or unsupported by the engine
    /// the user picked, so a translation never fails just because a language
    /// disappeared from the list.
    static let fallback: TranslationLanguage = all[0]

    static func language(for code: String) -> TranslationLanguage? {
        all.first { $0.code == code }
    }

    /// Resolves a stored/requested code against an engine's own list: the code
    /// itself when the engine supports it, the engine's first language
    /// otherwise.
    static func resolvedCode(_ code: String, in languages: [TranslationLanguage]) -> String {
        if languages.contains(where: { $0.code == code }) { return code }
        return (languages.first ?? fallback).code
    }
}

/// Canonical code → one vendor's code.
///
/// An engine advertises exactly the languages it has a mapping for, so a missing
/// entry means "this engine cannot translate that language" instead of "send the
/// canonical code and hope the vendor understands it". Only mappings that match
/// the vendor's published language list are listed here: a wrong code comes back
/// as a runtime "invalid language" error, which is much worse than the language
/// simply not being offered.
struct TranslationLanguageMapping {

    private let codes: [String: String]

    init(_ codes: [String: String]) {
        self.codes = codes
    }

    func vendorCode(for canonical: String) -> String? {
        codes[canonical]
    }

    /// Catalog-ordered languages this mapping covers.
    var languages: [TranslationLanguage] {
        TranslationLanguageCatalog.all.filter { codes[$0.code] != nil }
    }
}
