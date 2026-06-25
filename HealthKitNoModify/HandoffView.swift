import SwiftUI
import Combine
import Speech
import AVFoundation

struct HandoffNote: Identifiable, Codable {
    var id = UUID()
    let sender: String
    let recipient: String
    let timestamp: Date
    let originalText: String
    let translatedText: String
    var isConfirmed: Bool

    static let storageKey = "HandoffNotes"
}

struct HandoffView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var notes: [HandoffNote] = []
    @State private var originalText: String = ""
    @State private var translatedText: String = ""
    @State private var targetLanguage = "印尼文"
    @State private var detectedSourceLanguage = "自動偵測"
    @State private var isRecording = false
    @State private var isTranslating = false
    @State private var translationError: String?
    @StateObject private var recognizer = SpeechRecognizer()

    private let languages = ["印尼文", "英文", "中文"]

    var body: some View {
        AlwaysVisibleScrollView {
            VStack(spacing: 20) {
                header
                languageSelector
                messageInput
                actionButtons
                translationPreview
                noteList
            }
            .padding()
        }
        .navigationTitle(settings.localized("home.handoff"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadNotes)
        .onChange(of: recognizer.transcript) { _, newValue in
            if !newValue.isEmpty {
                originalText = newValue
                detectedSourceLanguage = TranslationService.detectSourceLanguageLabel(for: newValue)
                translateCurrentText()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.localized("handoff.title"))
                .font(settings.scaledFont(22, weight: .bold))
            Text(settings.localized("handoff.subtitle"))
                .foregroundColor(.secondary)
                .font(settings.scaledFont(16))
                .lineSpacing(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languageSelector: some View {
        HStack(spacing: 16) {
            Text(settings.localized("handoff.targetLanguage"))
                .font(settings.scaledFont(16, weight: .semibold))
            Spacer()
            Picker(settings.localized("handoff.targetLanguage"), selection: $targetLanguage) {
                ForEach(languages, id: \.self) { language in
                    Text(language)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var messageInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localized("handoff.contentLabel"))
                .font(settings.scaledFont(16, weight: .semibold))
            TextEditor(text: $originalText)
                .font(settings.scaledFont(14))
                .frame(height: 160)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: createTranslationNote) {
                Text(settings.localized("handoff.createNote"))
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding()
                    .background(isTranslating ? Color(.systemGray) : Color(.systemBlue))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(isTranslating || originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                    Text(isRecording ? settings.localized("handoff.stopRecording") : settings.localized("handoff.startRecording"))
                }
                .font(settings.scaledFont(16))
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding()
                .background(isRecording ? Color(.systemRed) : Color(.systemGreen))
                .foregroundColor(.white)
                .cornerRadius(14)
            }
        }
    }

    private var translationPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.localized("handoff.preview"))
                .font(settings.scaledFont(16, weight: .semibold))
            Text("\(settings.localized("handoff.sourceLanguage"))\(detectedSourceLanguage)")
                .font(settings.scaledFont(14))
                .foregroundColor(.secondary)

            Group {
                if isTranslating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(settings.localized("handoff.translating"))
                    }
                } else if let error = translationError {
                    Text(error)
                        .foregroundColor(.red)
                } else if translatedText.isEmpty {
                    Text(settings.localized("handoff.noTranslation"))
                        .font(settings.scaledFont(14))
                        .lineSpacing(6)
                        .foregroundColor(.secondary)
                } else {
                    Text(translatedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.localized("handoff.log"))
                .font(settings.scaledFont(16, weight: .semibold))
            if notes.isEmpty {
                Text(settings.localized("handoff.noNotes"))
                    .foregroundColor(.secondary)
            } else {
                ForEach(notes) { note in
                    noteCard(note)
                }
            }
        }
    }

    private func noteCard(_ note: HandoffNote) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(note.sender)
                        .font(settings.scaledFont(16, weight: .semibold))
                    Text(note.timestamp, style: .date) + Text(" ") + Text(note.timestamp, style: .time)
                        .font(settings.scaledFont(12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Label(note.isConfirmed ? settings.localized("handoff.confirmed") : settings.localized("handoff.pending"), systemImage: note.isConfirmed ? "checkmark.seal.fill" : "hourglass")
                    .font(settings.scaledFont(12))
                    .padding(6)
                    .background(note.isConfirmed ? Color(.systemGreen).opacity(0.16) : Color(.systemOrange).opacity(0.16))
                    .cornerRadius(10)
            }
            Text("\(settings.localized("handoff.original"))\n\(note.originalText)")
                .font(settings.scaledFont(14))
                .lineSpacing(6)
            Text("\(settings.localized("handoff.translated"))\n\(note.translatedText)")
                .font(settings.scaledFont(14))
                .lineSpacing(6)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button(action: { confirmNote(note) }) {
                    Text(note.isConfirmed ? settings.localized("handoff.reported") : settings.localized("handoff.markReported"))
                        .font(settings.scaledFont(12))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(note.isConfirmed ? Color(.systemGray4) : Color(.systemTeal).opacity(0.16))
                        .foregroundColor(note.isConfirmed ? .secondary : .blue)
                        .cornerRadius(12)
                }

                Button(action: { deleteNote(note) }) {
                    Text(settings.localized("handoff.deleteNote"))
                        .font(settings.scaledFont(12))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemRed).opacity(0.16))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 4)
    }

    private func createTranslationNote() {
        let content = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        translateAndCreateNote(text: content)
    }

    private func translateAndCreateNote(text: String) {
        detectedSourceLanguage = TranslationService.detectSourceLanguageLabel(for: text)
        isTranslating = true
        translationError = nil
        TranslationService.translate(text, to: targetLanguage) { result in
            DispatchQueue.main.async {
                self.isTranslating = false
                switch result {
                case .success(let translated):
                    self.translatedText = translated
                    let note = HandoffNote(sender: "家庭照顧者",
                                           recipient: self.targetLanguage,
                                           timestamp: Date(),
                                           originalText: text,
                                           translatedText: translated,
                                           isConfirmed: false)
                    self.notes.insert(note, at: 0)
                    self.originalText = ""
                    self.saveNotes()
                case .failure(let error):
                    self.translationError = error.localizedDescription
                }
            }
        }
    }

    private func confirmNote(_ note: HandoffNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].isConfirmed = true
        saveNotes()
    }

    private func deleteNote(_ note: HandoffNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes.remove(at: index)
        saveNotes()
    }

    private func toggleRecording() {
        if isRecording {
            recognizer.stopRecording()
            isRecording = false
            translateCurrentText()
        } else {
            recognizer.requestAuthorization { authorized in
                if authorized {
                    recognizer.startRecording(locale: Locale(identifier: "id-ID"))
                    isRecording = true
                }
            }
        }
    }

    private func translateCurrentText() {
        let content = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        detectedSourceLanguage = TranslationService.detectSourceLanguageLabel(for: content)
        isTranslating = true
        translationError = nil
        TranslationService.translate(content, to: targetLanguage) { result in
            DispatchQueue.main.async {
                self.isTranslating = false
                switch result {
                case .success(let translated):
                    self.translatedText = translated
                case .failure(let error):
                    self.translationError = error.localizedDescription
                }
            }
        }
    }

    private func loadNotes() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = UserDefaults.standard.data(forKey: HandoffNote.storageKey) else {
                DispatchQueue.main.async { self.notes = [] }
                return
            }
            if let decoded = try? JSONDecoder().decode([HandoffNote].self, from: data) {
                DispatchQueue.main.async { self.notes = decoded }
            } else {
                DispatchQueue.main.async { self.notes = [] }
            }
        }
    }

    private func saveNotes() {
        let notesToSave = notes
        DispatchQueue.global(qos: .background).async {
            if let data = try? JSONEncoder().encode(notesToSave) {
                UserDefaults.standard.set(data, forKey: HandoffNote.storageKey)
            }
        }
    }
}

struct HandoffView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            HandoffView()
                .environmentObject(AppSettings.shared)
        }
    }
}

final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func startRecording(locale: Locale) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            return
        }
        recognitionRequest.shouldReportPartialResults = true

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DispatchQueue.main.async {
                self.transcript = ""
            }
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            DispatchQueue.main.async {
                self.transcript = ""
            }
            return
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                DispatchQueue.main.async {
                    self.transcript = result.bestTranscription.formattedString
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                self.stopRecording()
            }
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}
