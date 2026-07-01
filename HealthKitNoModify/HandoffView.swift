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
    @ObservedObject private var scheduleManager = CareScheduleManager.shared

    @State private var notes: [HandoffNote] = []
    @State private var originalText: String = ""
    @State private var translatedText: String = ""

    /// User-selected source language. Auto-detect was removed by request —
    /// the user now always explicitly picks the source language. Default is
    /// English so a Western caregiver can immediately type a note and see
    /// the Chinese translation appear in the preview.
    @State private var originalLanguage: String = "英文"
    @State private var targetLanguage: String = "中文"

    /// Last detected source language label — still computed by the speech
    /// recognizer path so we can display it as a hint, but no longer used
    /// to drive translation routing now that the picker is explicit.
    @State private var detectedSourceLanguage = ""

    /// Recipient caregiver for this translated note (optional). Nil means
    /// the note isn't assigned to any caregiver yet.
    @State private var assignedCaregiverId: UUID? = nil

    @State private var isRecording = false
    @State private var isTranslating = false
    @State private var translationError: String?
    @StateObject private var recognizer = SpeechRecognizer()

    /// Debounce token: every keystroke writes the current time into
    /// `typingToken`; the dispatched translation only fires if `typingToken`
    /// hasn't moved in `typingDebounceSeconds`. Keeps live translation
    /// responsive without firing one API call per character.
    @State private var typingToken: UUID = UUID()
    private let typingDebounceSeconds: Double = 0.45

    /// Cache the last-translated input so we don't re-translate the same
    /// text twice (saves a round trip every time SwiftUI re-runs `onChange`).
    @State private var lastTranslatedInput: String = ""

    private let languages = ["印尼文", "英文", "中文"]
    // Auto-detect removed — the user explicitly selects the source language.
    private let originalLanguages = ["英文", "中文", "印尼文"]

    private var assignedCaregiver: Caregiver? {
        guard let id = assignedCaregiverId else { return nil }
        return scheduleManager.caregivers.first { $0.id == id }
    }

    var body: some View {
        AlwaysVisibleScrollView {
            VStack(spacing: 20) {
                // Shaded top spacer — pushes the whole translation UI lower
                // on the page so the navigation bar / safe area visually
                // separates from the content. Acts as a soft "header band".
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        LinearGradient(
                            colors: [Color.black.opacity(0.06), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.horizontal, -16)
                    .padding(.top, -16)

                header
                languageSelector
                caregiverAssignment
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
                scheduleDebouncedTranslate()
            }
        }
        // Live translate-as-you-type: every keystroke schedules a debounced
        // translation. The actual API call only fires once typing pauses,
        // so the preview updates "instantly" without a request per letter.
        .onChange(of: originalText) { _, _ in
            scheduleDebouncedTranslate()
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

    /// Two stacked language pickers — the user picks BOTH the original
    /// language and the target language so the translator never has to
    /// guess. Auto-detect was removed by request; defaults are English →
    /// Chinese.
    private var languageSelector: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.localized("handoff.originalLanguage"))
                    .font(settings.scaledFont(15, weight: .semibold))
                Picker(settings.localized("handoff.originalLanguage"),
                       selection: $originalLanguage) {
                    ForEach(originalLanguages, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: originalLanguage) { _, _ in
                    translateCurrentText()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(settings.localized("handoff.targetLanguage"))
                    .font(settings.scaledFont(15, weight: .semibold))
                Picker(settings.localized("handoff.targetLanguage"),
                       selection: $targetLanguage) {
                    ForEach(languages, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: targetLanguage) { _, _ in
                    translateCurrentText()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    /// Recipient picker — the user can tag this translated note for a
    /// specific caregiver (so the handover log shows who it was for).
    /// Adding caregivers themselves still happens on the Care Schedule
    /// Board; this picker just reads from the same shared list.
    private var caregiverAssignment: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.localized("handoff.assignToCaregiver"))
                .font(settings.scaledFont(15, weight: .semibold))

            Picker(settings.localized("handoff.assignToCaregiver"),
                   selection: $assignedCaregiverId) {
                Text(settings.localized("handoff.noCaregiver"))
                    .tag(UUID?.none)
                ForEach(scheduleManager.caregivers) { caregiver in
                    Text(caregiver.icon.isEmpty
                         ? caregiver.name
                         : "\(caregiver.icon)  \(caregiver.name)")
                        .tag(Optional(caregiver.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Email & phone of the selected caregiver are intentionally
            // not shown here — the picker label alone is enough.
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
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
                Text(settings.localized("handoff.createTranslatedNote"))
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
        // Auto-detect was removed — always pass the explicitly picked
        // source language to the translation service.
        let sourceForRequest: String? = originalLanguage

        // If the live-preview translation already produced a result for
        // this exact input, reuse it instead of paying for another API
        // round trip when the user taps "Create translated note".
        if !translatedText.isEmpty && lastTranslatedInput == text {
            self.isTranslating = false
            self.persistTranslatedNote(originalText: text,
                                       translated: translatedText)
            return
        }

        TranslationService.translate(text,
                                     from: sourceForRequest,
                                     to: targetLanguage) { result in
            DispatchQueue.main.async {
                self.isTranslating = false
                switch result {
                case .success(let translated):
                    self.translatedText = translated
                    self.lastTranslatedInput = text
                    self.persistTranslatedNote(originalText: text,
                                               translated: translated)
                case .failure(let error):
                    self.translationError = error.localizedDescription
                }
            }
        }
    }

    /// Save the new note to the on-screen log, tagged with the selected
    /// recipient caregiver (or "Unassigned" when no caregiver was picked).
    /// The sender now reflects the actually-assigned caregiver name
    /// instead of the previous generic "家庭照顧者" placeholder.
    private func persistTranslatedNote(originalText: String, translated: String) {
        let recipientLabel: String
        let senderLabel: String
        if let caregiver = assignedCaregiver {
            recipientLabel = "\(caregiver.name) (\(targetLanguage))"
            senderLabel = caregiver.name
        } else {
            recipientLabel = targetLanguage
            senderLabel = settings.localized("handoff.noCaregiver")
        }
        let note = HandoffNote(sender: senderLabel,
                               recipient: recipientLabel,
                               timestamp: Date(),
                               originalText: originalText,
                               translatedText: translated,
                               isConfirmed: false)
        notes.insert(note, at: 0)
        self.originalText = ""
        translatedText = ""
        lastTranslatedInput = ""
        saveNotes()
    }

    /// Schedule a translation to run once the user stops typing for
    /// `typingDebounceSeconds`. This is what makes live translation feel
    /// "instant" without firing a network call on every keystroke.
    private func scheduleDebouncedTranslate() {
        let token = UUID()
        typingToken = token
        let content = originalText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clear the preview the moment the input is emptied so stale text
        // doesn't linger after the user deletes everything.
        if content.isEmpty {
            translatedText = ""
            lastTranslatedInput = ""
            translationError = nil
            return
        }

        // Skip the API call entirely if this exact input was just
        // translated — common case when SwiftUI re-runs the onChange.
        if content == lastTranslatedInput { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + typingDebounceSeconds) {
            // Cancel ourselves if a newer keystroke superseded this one.
            guard self.typingToken == token else { return }
            let latest = self.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard latest == content, !latest.isEmpty else { return }
            self.translateCurrentText()
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
        guard !content.isEmpty else {
            translatedText = ""
            lastTranslatedInput = ""
            return
        }
        detectedSourceLanguage = TranslationService.detectSourceLanguageLabel(for: content)
        isTranslating = true
        translationError = nil
        // Auto-detect was removed — always pass the explicitly picked
        // source language to the translation service.
        let sourceForRequest: String? = originalLanguage
        TranslationService.translate(content,
                                     from: sourceForRequest,
                                     to: targetLanguage) { result in
            DispatchQueue.main.async {
                self.isTranslating = false
                switch result {
                case .success(let translated):
                    self.translatedText = translated
                    self.lastTranslatedInput = content
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
