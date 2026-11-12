import Foundation

/// Groups a batch of texts into as few requests as a vendor allows.
///
/// A request per line is what the original Google engine did, and it is fine for
/// an endpoint with no rate limit. It is not fine for the signed Chinese APIs:
/// Baidu's free tier allows 1 QPS, so a 40-line screenshot would take 40 seconds
/// and most of it would come back as "too many requests". Every engine here
/// accepts a newline-separated query and answers per line, so lines are packed
/// up to the engine's byte and line budget instead.
enum TranslationBatchPlanner {

    /// Index groups into `texts`, in order.
    ///
    /// Blank entries are skipped: engines echo them without asking the vendor, so
    /// sending whitespace would only waste budget and shift the answer's line
    /// numbering. A single text longer than `maximumBytes` still gets a group of
    /// its own — truncating the user's text would silently change what they
    /// asked to have translated.
    static func groups(
        for texts: [String],
        maximumBytes: Int,
        maximumLines: Int
    ) -> [[Int]] {
        let byteBudget = max(1, maximumBytes)
        let lineBudget = max(1, maximumLines)

        var groups: [[Int]] = []
        var current: [Int] = []
        var currentBytes = 0

        for (index, text) in texts.enumerated() where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // +1 for the newline that will join this line to the previous one.
            let cost = text.utf8.count + 1
            let wouldOverflow = !current.isEmpty && currentBytes + cost > byteBudget
            if wouldOverflow || current.count >= lineBudget {
                groups.append(current)
                current = []
                currentBytes = 0
            }
            current.append(index)
            currentBytes += cost
        }

        if !current.isEmpty { groups.append(current) }
        return groups
    }
}

/// Maps a vendor's answer for one request back onto the lines that were sent.
///
/// Vendors split long sentences into several segments, so a multi-line answer is
/// only trustworthy when its segment count matches the line count. Guessing
/// otherwise would shift a translated line onto the wrong source line — worse
/// than asking again.
enum TranslationBatchReconciler {

    /// One translation per sent line, or nil when the answer cannot be mapped
    /// unambiguously.
    static func reconcile(segments: [String], sentCount: Int) -> [String]? {
        guard sentCount > 0 else { return [] }
        // Nothing came back: keep the caller's original text rather than
        // replacing it with nothing.
        guard !segments.isEmpty else { return nil }
        if segments.count == sentCount { return segments }
        // One line in, several sentence segments out: they belong to that one
        // line, so stitch them back together instead of dropping everything
        // after the first sentence.
        if sentCount == 1 { return [segments.joined()] }
        return nil
    }
}

/// Sends the batches of one translation call one at a time, spaced by
/// `minimumInterval`.
///
/// Serial on purpose: parallel requests are exactly what trips a vendor's
/// per-second counter, and the batches are already packed to keep their count
/// low. Stops at the first failure instead of burning the remaining budget on
/// requests that will fail the same way.
enum TranslationSequentialDispatcher {

    static func dispatch<T>(
        count: Int,
        minimumInterval: TimeInterval,
        send: @escaping (Int, @escaping (Result<T, Error>) -> Void) -> Void,
        completion: @escaping (Result<[T], Error>) -> Void
    ) {
        guard count > 0 else {
            completion(.success([]))
            return
        }

        var results: [T?] = Array(repeating: nil, count: count)

        func sendAt(_ index: Int) {
            guard index < count else {
                // Only reached once every index above has filled its slot, so the
                // unwrap below cannot fail.
                completion(.success(results.map { $0! }))
                return
            }
            send(index) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let value):
                    results[index] = value
                    if index + 1 < count, minimumInterval > 0 {
                        DispatchQueue.global(qos: .userInitiated)
                            .asyncAfter(deadline: .now() + minimumInterval) { sendAt(index + 1) }
                    } else {
                        sendAt(index + 1)
                    }
                }
            }
        }

        sendAt(0)
    }
}

/// Sends one request per planned group, then repairs any group whose answer could
/// not be mapped line-for-line by asking the vendor again one line at a time.
///
/// The repair pass costs the affected lines a second round trip, but it only runs
/// when a vendor's segmentation did not line up, and it keeps a translated line
/// from landing on the wrong source line.
enum TranslationBatchSender {

    /// - Parameters:
    ///   - lines: every text the caller passed, blanks included. Blanks are
    ///     echoed back verbatim.
    ///   - groups: index groups of the non-blank lines, from `TranslationBatchPlanner`.
    ///   - request: one vendor round trip for a list of lines.
    static func send(
        lines: [String],
        groups: [[Int]],
        minimumInterval: TimeInterval,
        request: @escaping ([String], @escaping (Result<[String], Error>) -> Void) -> Void,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        var results = lines
        guard !groups.isEmpty else {
            completion(.success(results))
            return
        }

        TranslationSequentialDispatcher.dispatch(
            count: groups.count,
            minimumInterval: minimumInterval,
            send: { index, done in
                request(groups[index].map { lines[$0] }, done)
            },
            completion: { batchResult in
                switch batchResult {
                case .failure(let error):
                    completion(.failure(error))

                case .success(let batches):
                    var unmatched: [Int] = []
                    for (batchIndex, group) in groups.enumerated() {
                        if let reconciled = TranslationBatchReconciler.reconcile(
                            segments: batches[batchIndex], sentCount: group.count) {
                            for (offset, lineIndex) in group.enumerated() {
                                results[lineIndex] = reconciled[offset]
                            }
                        } else {
                            unmatched.append(contentsOf: group)
                        }
                    }

                    guard !unmatched.isEmpty else {
                        completion(.success(results))
                        return
                    }

                    TranslationSequentialDispatcher.dispatch(
                        count: unmatched.count,
                        minimumInterval: minimumInterval,
                        send: { index, done in
                            request([lines[unmatched[index]]], done)
                        },
                        completion: { repairResult in
                            switch repairResult {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let singleLineAnswers):
                                for (offset, lineIndex) in unmatched.enumerated() {
                                    let segments = singleLineAnswers[offset]
                                    // One line in, so every segment belongs to it.
                                    // Nothing back at all keeps the original text.
                                    results[lineIndex] = segments.isEmpty
                                        ? lines[lineIndex]
                                        : segments.joined()
                                }
                                completion(.success(results))
                            }
                        }
                    )
                }
            }
        )
    }
}
