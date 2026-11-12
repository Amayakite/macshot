import Foundation

/// Baidu Translate open API (`fanyi-api.baidu.com`).
///
/// Requires an App ID + secret key from the Baidu developer console; every
/// request carries `md5(appid + query + salt + secret)` instead of the secret.
/// The free tier allows roughly one request per second, which is what
/// `minimumRequestInterval` paces.
struct BaiduTranslationEngine: TranslationEngine {

    static let appIDKey = "baiduTranslateAppID"
    static let secretKey = "baiduTranslateSecretKey"

    /// Baidu accepts both GET and POST; POST keeps long, multi-line queries out
    /// of access logs and proxies' URL limits.
    static let endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!

    let provider = TranslationProvider.baidu
    let displayName = "Baidu Translate"
    /// Baidu's free tier allows about one request per second.
    let minimumRequestInterval: TimeInterval = 1.05
    /// Baidu documents a 6000-byte query limit. Percent-encoding can triple the
    /// size of CJK text, so the budget stays well under it.
    let maximumBytesPerRequest = 1000
    let maximumLinesPerRequest = 20

    let credentials: [TranslationCredential] = [
        TranslationCredential(
            defaultsKey: BaiduTranslationEngine.appIDKey,
            labelKey: "App ID:",
            isSecure: false,
            placeholder: "20240101000000000"),
        TranslationCredential(
            defaultsKey: BaiduTranslationEngine.secretKey,
            labelKey: "Secret Key:",
            isSecure: true,
            placeholder: ""),
    ]

    /// Baidu's own codes (百度翻译开放平台 “语言列表”). Only verified entries are
    /// listed: a wrong code fails at runtime with 58001, which reads to the user
    /// as a broken app rather than an unsupported language.
    private static let mapping = TranslationLanguageMapping([
        "en": "en",
        "zh-CN": "zh",
        "zh-TW": "cht",
        "ja": "jp",
        "ko": "kor",
        "fr": "fra",
        "es": "spa",
        "pt": "pt",
        "it": "it",
        "de": "de",
        "ru": "ru",
        "ar": "ara",
        "th": "th",
        "nl": "nl",
        "pl": "pl",
        "bg": "bul",
        "cs": "cs",
        "da": "dan",
        "fi": "fin",
        "hu": "hu",
        "ro": "rom",
        "sv": "swe",
        "vi": "vie",
    ])

    var languages: [TranslationLanguage] { Self.mapping.languages }

    /// Canonical code → Baidu code, or nil when Baidu cannot translate it.
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
        let appID = TranslationCredentials.value(for: Self.appIDKey)
        let secret = TranslationCredentials.value(for: Self.secretKey)
        guard !appID.isEmpty, !secret.isEmpty else {
            completion(.failure(TranslationError.missingCredentials(displayName)))
            return
        }

        let groups = TranslationBatchPlanner.groups(
            for: texts,
            maximumBytes: maximumBytesPerRequest,
            maximumLines: maximumLinesPerRequest)

        TranslationBatchSender.send(
            lines: texts,
            groups: groups,
            minimumInterval: minimumRequestInterval,
            request: { lines, done in
                Self.request(lines: lines, to: vendorTarget, appID: appID, secret: secret, completion: done)
            },
            completion: completion
        )
    }

    // MARK: - One request

    private static func request(
        lines: [String],
        to vendorTarget: String,
        appID: String,
        secret: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let query = lines.joined(separator: "\n")
        let salt = String(Int.random(in: 100_000_000...999_999_999))
        let sign = TranslationSigner.md5Hex(appID + query + salt + secret)

        TranslationHTTP.postForm(endpoint, fields: [
            ("q", query),
            ("from", "auto"),
            ("to", vendorTarget),
            ("appid", appID),
            ("salt", salt),
            ("sign", sign),
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

    /// Extracts one translated segment per requested line.
    ///
    /// Split out from the request so it can be tested against recorded
    /// responses: the failure modes here (numeric vs string error codes,
    /// per-line `src`/`dst` pairs) are what actually breaks in the field.
    static func parseSegments(from data: Data) throws -> [String] {
        struct Response: Decodable {
            struct Item: Decodable {
                let src: String?
                let dst: String?
            }
            let transResult: [Item]?
            let errorCode: FlexibleString?
            let errorMessage: String?

            enum CodingKeys: String, CodingKey {
                case transResult = "trans_result"
                case errorCode = "error_code"
                case errorMessage = "error_msg"
            }
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranslationError.parseError
        }

        // "52000" is Baidu's success code when the field is present at all.
        if let code = response.errorCode?.value, code != "52000" {
            let detail = response.errorMessage.map { ": \($0)" } ?? ""
            throw TranslationError.service("Baidu Translate error \(code)\(detail)")
        }

        let segments = (response.transResult ?? []).compactMap { $0.dst }
        guard !segments.isEmpty else {
            throw TranslationError.emptyResult
        }
        return segments
    }
}
