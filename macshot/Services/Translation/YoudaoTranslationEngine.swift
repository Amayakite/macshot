import Foundation

/// Youdao Translate API v3 (`openapi.youdao.com`).
///
/// Like Baidu it is signed, but with SHA-256 over a *fingerprint* of the query
/// rather than the query itself, plus a Unix `curtime`. The free tier is
/// per-minute rather than per-second limited, so requests are only lightly
/// spaced.
struct YoudaoTranslationEngine: TranslationEngine {

    static let appKeyDefaultsKey = "youdaoTranslateAppKey"
    static let appSecretDefaultsKey = "youdaoTranslateAppSecret"

    static let endpoint = URL(string: "https://openapi.youdao.com/api")!

    /// Youdao rejects queries above 5000 characters; the byte budget keeps
    /// multi-line batches far below that even with percent-encoded CJK text.
    static let maximumBytesPerRequest = 1000
    static let maximumLinesPerRequest = 20

    let provider = TranslationProvider.youdao
    let displayName = "Youdao Translate"
    let minimumRequestInterval: TimeInterval = 0.1

    let credentials: [TranslationCredential] = [
        TranslationCredential(
            defaultsKey: YoudaoTranslationEngine.appKeyDefaultsKey,
            labelKey: "App ID:",
            isSecure: false,
            placeholder: ""),
        TranslationCredential(
            defaultsKey: YoudaoTranslationEngine.appSecretDefaultsKey,
            labelKey: "Secret Key:",
            isSecure: true,
            placeholder: ""),
    ]

    /// Youdao's own codes (有道智云 v3 “支持的语言”). Unlike Baidu this vendor
    /// covers every language in the catalog.
    private static let mapping = TranslationLanguageMapping([
        "en": "en",
        "es": "es",
        "fr": "fr",
        "de": "de",
        "it": "it",
        "pt": "pt",
        "nl": "nl",
        "pl": "pl",
        "ru": "ru",
        "zh-CN": "zh-CHS",
        "zh-TW": "zh-CHT",
        "ja": "ja",
        "ko": "ko",
        "ar": "ar",
        "tr": "tr",
        "sv": "sv",
        "da": "da",
        "fi": "fi",
        "nb": "no",
        "uk": "uk",
        "cs": "cs",
        "ro": "ro",
        "hu": "hu",
        "sk": "sk",
        "bg": "bg",
        "hr": "hr",
        "id": "id",
        "hi": "hi",
        "th": "th",
        "vi": "vi",
    ])

    var languages: [TranslationLanguage] { Self.mapping.languages }

    /// Canonical code → Youdao code, or nil when Youdao cannot translate it.
    static func vendorCode(for canonical: String) -> String? {
        mapping.vendorCode(for: canonical)
    }

    func translate(
        texts: [String],
        to target: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard let vendorTarget = Self.mapping.vendorCode(for: target) else {
            completion(.failure(TranslationError.unsupportedLanguage(
                TranslationLanguageCatalog.language(for: target)?.name ?? target)))
            return
        }
        let appKey = TranslationCredentials.value(for: Self.appKeyDefaultsKey)
        let appSecret = TranslationCredentials.value(for: Self.appSecretDefaultsKey)
        guard !appKey.isEmpty, !appSecret.isEmpty else {
            completion(.failure(TranslationError.missingCredentials(displayName)))
            return
        }

        let groups = TranslationBatchPlanner.groups(
            for: texts,
            maximumBytes: Self.maximumBytesPerRequest,
            maximumLines: Self.maximumLinesPerRequest)

        TranslationBatchSender.send(
            lines: texts,
            groups: groups,
            minimumInterval: minimumRequestInterval,
            request: { lines, done in
                Self.request(lines: lines, to: vendorTarget, appKey: appKey, appSecret: appSecret, completion: done)
            },
            completion: completion
        )
    }

    // MARK: - One request

    private static func request(
        lines: [String],
        to vendorTarget: String,
        appKey: String,
        appSecret: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let query = lines.joined(separator: "\n")
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let sign = TranslationSigner.sha256Hex(
            appKey + TranslationSigner.youdaoQueryFingerprint(query) + salt + curtime + appSecret)

        TranslationHTTP.postForm(endpoint, fields: [
            ("q", query),
            ("from", "auto"),
            ("to", vendorTarget),
            ("appKey", appKey),
            ("salt", salt),
            ("sign", sign),
            ("signType", "v3"),
            ("curtime", curtime),
        ]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    completion(.success(try parseSegments(from: data)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Extracts one translated segment per requested line from a v3 response.
    /// Split out for testing, like Baidu's parser.
    static func parseSegments(from data: Data) throws -> [String] {
        struct Response: Decodable {
            let errorCode: FlexibleString?
            let translation: [String]?
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranslationError.parseError
        }

        // A v3 response always carries errorCode; "0" is the only success value.
        let code = response.errorCode?.value ?? "0"
        guard code == "0" else {
            throw TranslationError.service(describe(errorCode: code))
        }

        let segments = response.translation ?? []
        guard !segments.isEmpty else {
            throw TranslationError.emptyResult
        }
        return segments
    }

    /// Turns the vendor's numeric code into something a user can act on. The
    /// hints come from the v3 error table; unknown codes still surface the number
    /// so it can be looked up.
    static func describe(errorCode: String) -> String {
        let hints: [String: String] = [
            "103": "the text is too long to translate in one request",
            "108": "the App ID is not valid",
            "110": "this App ID is not subscribed to the text translation service",
            "202": "the secret key does not match the App ID",
            "203": "this IP address is not allowed for this App ID",
            "401": "the account has run out of credit",
            "411": "too many requests, try again in a moment",
            "412": "too many long requests, try again in a moment",
        ]
        let hint = hints[errorCode].map { " — \($0)" } ?? ""
        return "Youdao Translate error \(errorCode)\(hint)"
    }
}
