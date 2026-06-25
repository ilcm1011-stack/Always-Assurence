import Foundation
import NaturalLanguage

struct TranslationRequest: Codable {
    let sourceText: String
    let sourceLanguage: String
    let targetLanguage: String
}

final class TranslationService {
    static func translate(_ text: String, to language: String, completion: @escaping (Result<String, Error>) -> Void) {
        let sourceLanguageCode = detectSourceLanguage(for: text)

        let complete: (Result<String, Error>) -> Void = { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }

        guard let url = URL(string: Setting.shared.translationApiUrl) else {
            DispatchQueue.global(qos: .userInitiated).async {
                complete(.success(offlineTranslate(text, to: language)))
            }
            return
        }

        let requestBody = TranslationRequest(
            sourceText: text,
            sourceLanguage: sourceLanguageCode,
            targetLanguage: languageCode(for: language)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            complete(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                complete(.success(offlineTranslate(text, to: language)))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                complete(.success(offlineTranslate(text, to: language)))
                return
            }

            guard let data = data,
                  let translated = decodeTranslatedText(from: data) else {
                complete(.success(offlineTranslate(text, to: language)))
                return
            }

            complete(.success(translated))
        }.resume()
    }

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

    private static func offlineTranslate(_ text: String, to language: String) -> String {
        let targetCode = languageCode(for: language)
        let sourceCode = detectSourceLanguage(for: text)

        // If the source and target languages are the same, return the original text.
        guard sourceCode != targetCode else {
            return text
        }

        let replacements = offlineDictionary(for: targetCode)
        let sortedKeys = replacements.keys.sorted { $0.count > $1.count }
        var translated = text

        for key in sortedKeys {
            if let replacement = replacements[key] {
                translated = translated.replacingOccurrences(of: key, with: replacement, options: .caseInsensitive, range: nil)
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

    private static func languageCode(for language: String) -> String {
        switch language {
        case "印尼文":
            return "id"
        case "英文":
            return "en"
        case "中文":
            return "zh-TW"
        default:
            return "en"
        }
    }

    private static func decodeTranslatedText(from data: Data) -> String? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translatedText = jsonObject["translatedText"] as? String else {
            return nil
        }
        return translatedText
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
