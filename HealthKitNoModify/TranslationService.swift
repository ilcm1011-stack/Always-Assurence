import Foundation
import NaturalLanguage

struct TranslationRequest: Codable {
    let sourceText: String
    let sourceLanguage: String
    let targetLanguage: String
}

/// Translation service for the cross-language handover screen.
///
/// History: the previous version pointed at a placeholder REST endpoint
/// (`https://api.example.com/translate`) that never returned anything
/// usable, which is why on-device users always fell through to the very
/// small offline phrase dictionary and saw the awful "[離線備援翻譯]"
/// prefix. This version routes translations through the OpenRouter
/// vision/chat API that's already wired up for the other scanners, so
/// real sentences round-trip correctly between Traditional Chinese,
/// English, and Indonesian. The offline dictionary is still used as a
/// last-resort fallback when the network is unavailable.
final class TranslationService {

    // For testing only.
    // Do NOT hardcode API keys in production apps.
    // Prefer calling your own backend instead.
    private static let openRouterAPIKey =
        "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"

    private static let openRouterURL =
        URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Translate `text` into the given target language (display name like
    /// "印尼文" / "英文" / "中文"). If `sourceLanguage` is supplied it is
    /// used verbatim; otherwise the language is auto-detected.
    static func translate(
        _ text: String,
        from sourceLanguage: String? = nil,
        to language: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(.success("")) }
            return
        }

        let sourceLanguageCode: String
        if let supplied = sourceLanguage,
           !supplied.isEmpty,
           supplied != "自動偵測" {
            sourceLanguageCode = languageCode(for: supplied)
        } else {
            sourceLanguageCode = detectSourceLanguage(for: trimmed)
        }
        let targetCode = languageCode(for: language)

        let complete: (Result<String, Error>) -> Void = { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }

        // Same-language short-circuit so we don't spend a network call
        // (and a model token) just to echo the user's input back.
        if sourceLanguageCode == targetCode {
            complete(.success(trimmed))
            return
        }

        Task {
            do {
                let translated = try await openRouterTranslate(
                    text: trimmed,
                    sourceCode: sourceLanguageCode,
                    targetCode: targetCode
                )
                complete(.success(translated))
            } catch {
                // Network / API failure → fall back to the bundled offline
                // dictionary instead of bubbling an opaque error to the UI.
                let fallback = offlineTranslate(trimmed,
                                                from: sourceLanguageCode,
                                                to: targetCode)
                complete(.success(fallback))
            }
        }
    }

    /// Convenience for the existing call-sites that don't supply a source
    /// language — keeps backwards compatibility.
    static func translate(
        _ text: String,
        to language: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        translate(text, from: nil, to: language, completion: completion)
    }

    // MARK: - OpenRouter call

    private static func openRouterTranslate(
        text: String,
        sourceCode: String,
        targetCode: String
    ) async throws -> String {
        let sourceName = languageDisplayName(for: sourceCode)
        let targetName = languageDisplayName(for: targetCode)

        let prompt = """
        You are a professional medical-care translator. Translate the
        text below from \(sourceName) to \(targetName).

        Strict rules:
        - Output ONLY the translated text. No prefix, no quotes, no
          commentary, no explanation, no language label, no markdown.
        - Preserve numbers, times, medication names, and dosage units
          exactly as they appear.
        - Keep the meaning and tone faithful — this is a caregiver
          handover note, so clarity matters more than literal style.

        Text to translate:
        \(text)
        """

        let body = OpenRouterTranslationRequest(
            model: "openrouter/free",
            messages: [
                OpenRouterTranslationMessage(role: "user", content: prompt)
            ],
            temperature: 0.0
        )

        var request = URLRequest(url: openRouterURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(openRouterAPIKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("HealthKitNoModify Handover Translation",
                         forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "TranslationService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                            "OpenRouter HTTP \(http.statusCode): \(raw.prefix(200))"]
            )
        }

        let decoded = try JSONDecoder().decode(
            OpenRouterTranslationResponse.self,
            from: data
        )
        guard let translated = decoded.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty else {
            throw NSError(
                domain: "TranslationService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                            "OpenRouter returned an empty translation."]
            )
        }
        return translated
    }

    // MARK: - Language detection / display

    static func detectSourceLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else {
            return "zh-TW"
        }

        switch language.rawValue {
        case "zh-Hant", "zh-Hans", "zh":
            return "zh-TW"
        case "id":
            return "id"
        case "en":
            return "en"
        default:
            return "zh-TW"
        }
    }

    static func detectSourceLanguageLabel(for text: String) -> String {
        switch detectSourceLanguage(for: text) {
        case "zh-TW":
            return "繁體中文"
        case "id":
            return "印尼文"
        case "en":
            return "英文"
        default:
            return "未知語言"
        }
    }

    /// Human-readable language name we feed to the LLM prompt.
    private static func languageDisplayName(for code: String) -> String {
        switch code {
        case "zh-TW":
            return "Traditional Chinese (繁體中文)"
        case "id":
            return "Bahasa Indonesia"
        case "en":
            return "English"
        default:
            return code
        }
    }

    // MARK: - Offline fallback

    private static func offlineTranslate(
        _ text: String,
        from sourceCode: String,
        to targetCode: String
    ) -> String {
        // If the source and target languages are the same, return the
        // original text unchanged.
        guard sourceCode != targetCode else {
            return text
        }

        let replacements = offlineDictionary(for: targetCode)
        let sortedKeys = replacements.keys.sorted { $0.count > $1.count }
        var translated = text

        for key in sortedKeys {
            if let replacement = replacements[key] {
                translated = translated.replacingOccurrences(
                    of: key,
                    with: replacement,
                    options: .caseInsensitive,
                    range: nil
                )
            }
        }

        if translated == text {
            return "[離線備援翻譯] \(text)"
        }
        return "[離線備援翻譯] \(translated)"
    }

    private static func offlineDictionary(for targetCode: String) -> [String: String] {
        switch targetCode {
        case "id":
            return [
                "餵藥": "memberi obat",
                "換藥": "mengganti perban",
                "血壓": "tekanan darah",
                "體溫": "suhu tubuh",
                "傷口": "luka",
                "發燒": "demam",
                "記錄": "mencatat",
                "交班": "serah terima tugas",
                "上午": "pagi",
                "下午": "sore",
                "晚上": "malam"
            ]
        case "en":
            return [
                "餵藥": "administer medication",
                "換藥": "change dressing",
                "血壓": "blood pressure",
                "體溫": "body temperature",
                "傷口": "wound",
                "發燒": "fever",
                "記錄": "record",
                "交班": "handover",
                "上午": "morning",
                "下午": "afternoon",
                "晚上": "evening"
            ]
        case "zh-TW":
            return [
                "medication": "藥物",
                "temperature": "體溫",
                "pressure": "血壓",
                "wound": "傷口",
                "fever": "發燒",
                "handover": "交班",
                "morning": "早上",
                "afternoon": "下午",
                "evening": "晚上",
                "today": "今天",
                "tomorrow": "明天"
            ]
        default:
            return [:]
        }
    }

    /// Normalize the display label that the picker uses into our internal
    /// language codes.
    private static func languageCode(for language: String) -> String {
        switch language {
        case "印尼文", "Indonesian", "Bahasa Indonesia", "id":
            return "id"
        case "英文", "English", "en":
            return "en"
        case "中文", "繁體中文", "Traditional Chinese", "zh-TW", "zh":
            return "zh-TW"
        default:
            return "en"
        }
    }

    enum TranslationError: LocalizedError {
        case invalidUrl
        case noData

        var errorDescription: String? {
            switch self {
            case .invalidUrl:
                return "翻譯服務設定錯誤。"
            case .noData:
                return "翻譯伺服器未回傳資料。"
            }
        }
    }
}

// MARK: - OpenRouter wire types

private struct OpenRouterTranslationRequest: Codable {
    let model: String
    let messages: [OpenRouterTranslationMessage]
    let temperature: Double
}

private struct OpenRouterTranslationMessage: Codable {
    let role: String
    let content: String
}

private struct OpenRouterTranslationResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let role: String?
        let content: String?
    }
}
