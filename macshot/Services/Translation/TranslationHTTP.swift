import Foundation

/// Shared transport for the vendors that expose a signed form-encoded HTTP API
/// (Baidu, Youdao). Google's endpoint is a GET with query items and Apple's
/// engine is not HTTP at all, so both keep their own transport.
enum TranslationHTTP {

    static func postForm(
        _ url: URL,
        fields: [(name: String, value: String)],
        timeout: TimeInterval = 15,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.name, value: $0.value) }
        // Percent-encoding through URLComponents keeps multibyte text and the
        // spaces inside a joined query from corrupting the signature input.
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(TranslationError.httpStatus(http.statusCode)))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(TranslationError.noData))
                return
            }
            completion(.success(data))
        }.resume()
    }
}

/// A JSON value that may arrive as a string or as a number.
///
/// Vendors are inconsistent — Baidu sends `"error_code": 54001` as a number in
/// some responses and as a string in others — and that difference must not turn
/// into a decode failure the user reads as "could not parse translation
/// response".
struct FlexibleString: Decodable, Equatable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self) {
            value = String(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected a string or a number")
        }
    }
}
