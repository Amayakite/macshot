import Foundation

/// Google's public web endpoint (`translate_a/single`, `client=gtx`).
///
/// The default engine: needs no key, covers every language in the catalog, and
/// works on macOS versions that predate Apple's Translation framework. Unlike the
/// signed Chinese APIs it asks one string per request — its multi-`q` reply
/// interleaves sentence-level segments, so splitting an answer back into lines
/// reliably is not something this endpoint supports. It also has no documented
/// rate limit, so a screenshot's lines go out together instead of in a paced
/// batch, exactly like the pre-engine implementation did.
struct GoogleTranslationEngine: TranslationEngine {

    let provider = TranslationProvider.google
    let displayName = "Google Translate"
    let credentials: [TranslationCredential] = []
    let minimumRequestInterval: TimeInterval = 0
    let maximumBytesPerRequest = 0

    var languages: [TranslationLanguage] { TranslationLanguageCatalog.all }

    func translate(
        texts: [String],
        to target: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        var results = texts
        let group = DispatchGroup()
        var firstError: Error?
        let lock = NSLock()

        for (index, text) in texts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            group.enter()
            Self.request(text: trimmed, target: target) { result in
                lock.lock()
                switch result {
                case .success(let translated):
                    results[index] = translated
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let error = firstError {
                completion(.failure(error))
            } else {
                completion(.success(results))
            }
        }
    }

    // MARK: - One request

    private static func request(
        text: String,
        target: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components.url else {
            completion(.failure(TranslationError.badURL))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(TranslationError.noData))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = json.first as? [[Any]] else {
                completion(.failure(TranslationError.parseError))
                return
            }
            let translated = segments.compactMap { $0.first as? String }.joined()
            guard !translated.isEmpty else {
                completion(.failure(TranslationError.emptyResult))
                return
            }
            completion(.success(translated))
        }.resume()
    }
}
