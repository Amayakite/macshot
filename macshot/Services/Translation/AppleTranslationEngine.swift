import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

/// Apple's on-device Translation framework (macOS 15+).
///
/// Faster than the network engines and works offline, but only for language
/// pairs whose system language packs are installed, which is why the language
/// picker asks `installedLanguageCodes(completion:)` before listing anything.
struct AppleTranslationEngine: TranslationEngine {

    let provider = TranslationProvider.apple
    let displayName = "Apple (on-device)"
    let credentials: [TranslationCredential] = []
    let minimumRequestInterval: TimeInterval = 0
    let maximumBytesPerRequest = 0

    /// Apple has no fixed language table to query: any pair the system can pair
    /// up is fair game, and the installed ones are discovered at runtime.
    var languages: [TranslationLanguage] { TranslationLanguageCatalog.all }

    var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    func translate(
        texts: [String],
        to target: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard #available(macOS 15.0, *) else {
            completion(.failure(TranslationError.appleTranslation(
                "Apple translation needs macOS 15 or newer. Pick another engine in Settings.")))
            return
        }

        // Auto-detect the source language: without it Apple shows a "Choose
        // Language" dialog, which an overlay cannot host.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: " "))

        guard let detected = recognizer.dominantLanguage else {
            // Ambiguous or single-word input. Report on the main thread — this is
            // called from a background OCR queue and the completion mutates
            // overlay UI.
            DispatchQueue.main.async {
                completion(.failure(TranslationError.appleTranslation(
                    "Could not detect source language. Try selecting more text.")))
            }
            return
        }

        let configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: detected.rawValue),
            target: Self.appleLocale(from: target))

        // TranslationBridge adds a SwiftUI view, which requires the main thread.
        DispatchQueue.main.async {
            TranslationBridge.shared.translate(
                texts: texts, configuration: configuration, completion: completion)
        }
    }

    /// Maps macshot's canonical codes onto Apple's `Locale.Language` identifiers.
    /// Only the codes whose spelling differs need an entry.
    @available(macOS 15.0, *)
    static func appleLocale(from code: String) -> Locale.Language {
        switch code {
        case "zh-CN": return Locale.Language(identifier: "zh-Hans")
        case "zh-TW": return Locale.Language(identifier: "zh-Hant")
        case "nb": return Locale.Language(identifier: "no")
        default: return Locale.Language(identifier: code)
        }
    }

    // MARK: - Installed language packs

    /// Canonical code → installed-language status, cached for the session.
    ///
    /// Only cached once at least one language comes back installed: right after
    /// launch the framework can report every language as missing, and caching
    /// that would leave the picker empty until the next launch.
    private static var cachedAvailability: [String: Bool]?

    /// Reports which canonical languages have their language pack installed.
    /// Called on the main queue.
    @available(macOS 15.0, *)
    static func installedLanguageCodes(completion: @escaping ([String: Bool]) -> Void) {
        if let cached = cachedAvailability {
            completion(cached)
            return
        }

        Task {
            let availability = LanguageAvailability()
            let locals = TranslationLanguageCatalog.all.map { language in
                (code: language.code, locale: appleLocale(from: language.code))
            }

            // Find one installed pair, then test every other language against
            // that known-good "probe" — O(n) instead of O(n²).
            var installed: [String: Bool] = [:]
            var probe: (code: String, locale: Locale.Language)?

            outer: for (index, language) in locals.enumerated() {
                for other in locals[(index + 1)...] {
                    let status = await availability.status(from: language.locale, to: other.locale)
                    if status == .installed {
                        installed[language.code] = true
                        installed[other.code] = true
                        probe = (language.code, language.locale)
                        break outer
                    }
                }
            }

            if let probe = probe {
                for language in locals where installed[language.code] != true {
                    // Check both directions: probe→language may be unsupported
                    // while language→probe is fine.
                    let toStatus = await availability.status(from: probe.locale, to: language.locale)
                    let fromStatus = await availability.status(from: language.locale, to: probe.locale)
                    installed[language.code] = (toStatus == .installed || fromStatus == .installed)
                }
                installed[probe.code] = true
            }

            for language in locals where installed[language.code] == nil {
                installed[language.code] = false
            }

            await MainActor.run {
                if installed.values.contains(true) {
                    cachedAvailability = installed
                }
                completion(installed)
            }
        }
    }
}

// MARK: - SwiftUI bridge for Apple Translation

/// Uses a hidden SwiftUI view with `.translationTask()` to obtain a
/// `TranslationSession`. This is the supported way to use the Translation
/// framework from AppKit.
@available(macOS 15.0, *)
@MainActor
final class TranslationBridge: ObservableObject {
    static let shared = TranslationBridge()

    @Published var config: TranslationSession.Configuration?
    private var hostingView: NSView?
    private var pendingTexts: [String] = []
    private var pendingCompletion: ((Result<[String], Error>) -> Void)?
    private var translationID: UUID?

    func translate(
        texts: [String],
        configuration: TranslationSession.Configuration,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        // Cancel any in-flight translation before starting a new one
        if pendingCompletion != nil {
            cleanup()
        }

        let thisID = UUID()
        translationID = thisID
        pendingTexts = texts
        pendingCompletion = completion

        // Create hidden SwiftUI view and attach to a window
        let view = TranslationBridgeView(bridge: self)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: -1, y: -1, width: 1, height: 1)
        if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            window.contentView?.addSubview(hosting)
        }
        hostingView = hosting

        // Setting config triggers .translationTask
        config = configuration

        // Timeout: if session doesn't respond in 10s, report error
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.translationID == thisID, self.pendingCompletion != nil else { return }
            let completion = self.pendingCompletion
            self.cleanup()
            completion?(.failure(TranslationError.appleTranslation(
                "Apple Translation timed out. The language pack may need to be downloaded in System Settings.")))
        }
    }

    fileprivate func sessionReady(_ session: TranslationSession) {
        // Ignore stale sessions from cancelled translations
        guard pendingCompletion != nil else { return }
        let texts = pendingTexts
        let completion = pendingCompletion
        let activeID = translationID
        Task {
            do {
                var results = Array(repeating: "", count: texts.count)
                for (index, text) in texts.enumerated() {
                    // Bail if a new translation was started while we're iterating
                    let stillActive = await MainActor.run { self.translationID == activeID }
                    guard stillActive else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        results[index] = text
                        continue
                    }
                    let response = try await session.translate(trimmed)
                    results[index] = response.targetText
                }
                await MainActor.run {
                    guard self.translationID == activeID else { return }
                    self.cleanup()
                    completion?(.success(results))
                }
            } catch {
                await MainActor.run {
                    guard self.translationID == activeID else { return }
                    self.cleanup()
                    let message = "Apple Translation failed: \(error.localizedDescription). "
                        + "You can switch to another translation engine in Settings."
                    completion?(.failure(TranslationError.appleTranslation(message)))
                }
            }
        }
    }

    private func cleanup() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        pendingTexts = []
        pendingCompletion = nil
        config = nil
    }
}

@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.config) { session in
                await MainActor.run {
                    bridge.sessionReady(session)
                }
            }
    }
}
