import SwiftUI
import UIKit
import HealthKit
import Vision

struct HealthKitDashboardView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var manager = HealthKitManager.shared
    @StateObject private var scheduleManager = CareScheduleManager.shared
    @State private var isUploading = false
    @State private var uploadMessage: String?
    @State private var showUploadAlert = false

    @State private var showImageSourceDialog = false
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .photoLibrary
    @State private var showOCRFailureAlert = false
    @State private var ocrFailureMessage = ""
    @State private var showCaregiverSelection = false
    @State private var selectedCaregiverSelection: CaregiverSelection = .external
    @State private var externalEmail = ""
    @State private var externalPhone = ""
    @State private var addToCalendar = true
    @State private var showAppointmentConfirmationAlert = false
    @State private var appointmentConfirmationMessage = ""
    @State private var parsedAppointment: ParsedAppointment?
    @State private var hasAutomaticallyLaunchedCamera = false

    var initialCameraScan: Bool = false

    private struct ParsedAppointment {
        let date: Date
        let doctorName: String
        let rawText: String
    }

    private enum CaregiverSelection: Hashable, Identifiable {
        case existing(UUID)
        case external

        var id: String {
            switch self {
            case .existing(let uuid): return uuid.uuidString
            case .external: return "external"
            }
        }
    }

    var body: some View {
        AlwaysVisibleScrollView {
            VStack(spacing: 28) {
                header
                statusCard
                UploadStatusView()
                    .environmentObject(settings)
                metricCards
                actionButtons
                policyCard
            }
            .padding()
        }
        .navigationTitle(settings.localized("home.healthDashboard"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            CareNotificationManager.shared.requestAuthorization { _ in }
            if manager.authorizationStatus == .sharingAuthorized {
                manager.refreshLatestMeasurements()
            }
            scheduleManager.reloadShifts()
            if initialCameraScan && !hasAutomaticallyLaunchedCamera {
                hasAutomaticallyLaunchedCamera = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    startCameraScan()
                }
            }
        }
        .onChange(of: manager.authorizationStatus) { _, newStatus in
            if newStatus == .sharingAuthorized {
                manager.refreshLatestMeasurements()
            }
        }
        .fullScreenCover(isPresented: $showImagePicker) {
            ImagePicker(sourceType: imagePickerSourceType) { image in
                recognizeText(in: image)
            }
        }
        .sheet(isPresented: $showCaregiverSelection) {
            caregiverSelectionSheet
        }
        .alert(isPresented: $showUploadAlert) {
            Alert(
                title: Text(settings.localized("health.uploadResult")),
                message: Text(uploadMessage ?? settings.localized("health.uploadUnknownError")),
                dismissButton: .default(Text(settings.localized("device.understood")))
            )
        }
        .alert(settings.localized("health.ocrFailed"), isPresented: $showOCRFailureAlert, actions: {
            Button(settings.localized("home.ok"), role: .cancel) {}
        }, message: {
            Text(ocrFailureMessage)
        })
        .alert(settings.localized("health.appointmentCreated"), isPresented: $showAppointmentConfirmationAlert) {
            Button(settings.localized("common.ok"), role: .cancel) {}
        } message: {
            Text(appointmentConfirmationMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localized("health.title"))
                .font(settings.scaledFont(22, weight: .bold))
            Text(settings.localized("health.subtitle"))
                .font(settings.scaledFont(16))
                .lineSpacing(6)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        Group {
            if manager.authorizationStatus == .sharingAuthorized {
                HStack {
                    Image(systemName: "checkmark.shield")
                    Text(settings.localized("health.authorized"))
                        .font(settings.scaledFont(14))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGreen).opacity(0.12))
                .cornerRadius(16)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(settings.localized("health.notAuthorized"))
                        .font(settings.scaledFont(18))
                    Text(settings.localized("health.authMessage"))
                        .font(settings.scaledFont(14))
                        .lineSpacing(6)
                        .foregroundColor(.secondary)
                    Button(action: requestAuthorization) {
                        Text(settings.localized("health.requestAuthorization"))
                            .font(settings.scaledFont(16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemTeal))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                }
                .padding()
                .background(Color(.systemYellow).opacity(0.12))
                .cornerRadius(16)
            }
        }
    }

    private var metricCards: some View {
        VStack(spacing: 18) {
            metricCard(title: settings.localized("health.metric.oxygen"), value: formatted(manager.oxygenSaturation, unit: "%"), warning: manager.oxygenSaturation.map { $0 < 93 } ?? false, detail: settings.localized("health.metric.oxygenWarning"))
            metricCard(title: settings.localized("health.metric.temperature"), value: formatted(manager.temperature, unit: "°C"), warning: manager.temperature.map { $0 > 38.5 } ?? false, detail: settings.localized("health.metric.temperatureWarning"))
            metricCard(title: settings.localized("health.metric.systolic"), value: formatted(manager.systolicPressure, unit: "mmHg"), warning: manager.systolicPressure.map { $0 >= 140 } ?? false, detail: settings.localized("health.metric.systolicWarning"))
            metricCard(title: settings.localized("health.metric.diastolic"), value: formatted(manager.diastolicPressure, unit: "mmHg"), warning: manager.diastolicPressure.map { $0 >= 90 } ?? false, detail: settings.localized("health.metric.diastolicWarning"))
        }
    }

    private func metricCard(title: String, value: String, warning: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(settings.scaledFont(18, weight: .semibold))
                Spacer()
                if warning {
                    Label(settings.localized("health.anomalyAlert"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(settings.scaledFont(12))
                }
            }
            Text(value)
                .font(settings.scaledFont(22, weight: .bold))
                .foregroundColor(warning ? .red : .primary)
            Text(detail)
                .font(settings.scaledFont(14))
                .lineSpacing(6)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    private var actionButtons: some View {
        VStack(spacing: 16) {
            Button(action: { manager.refreshLatestMeasurements(saveAndUpload: true) }) {
                Text(settings.localized("health.refreshData"))
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBlue))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }

            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(settings.scaledFont(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: uploadHealthSummary) {
                HStack {
                    if isUploading {
                        ProgressView()
                    }
                    Text(settings.localized("health.uploadData"))
                }
                .font(settings.scaledFont(16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGreen))
                .foregroundColor(.white)
                .cornerRadius(14)
            }

            if let anomalyMessage = manager.anomalyMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.localized("health.anomalyAlert"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Text(anomalyMessage)
                        .font(settings.scaledFont(14))
                        .foregroundColor(.red)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemRed).opacity(0.1))
                .cornerRadius(16)
            }
            scanAppointmentButton
        }
    }

    private var scanAppointmentButton: some View {
        Button(action: { showImageSourceDialog = true }) {
            Text(settings.localized("health.scanAppointment"))
                .font(settings.scaledFont(16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemPurple))
                .foregroundColor(.white)
                .cornerRadius(14)
        }
        .confirmationDialog(settings.localized("health.selectImageSource"), isPresented: $showImageSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(settings.localized("health.takePhoto")) {
                    imagePickerSourceType = .camera
                    showImagePicker = true
                }
            }
            Button(settings.localized("health.choosePhoto")) {
                imagePickerSourceType = .photoLibrary
                showImagePicker = true
            }
            Button(settings.localized("common.cancel"), role: .cancel) {}
        }
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.localized("health.policyTitle"))
                .font(.title3)
            Text(settings.localized("health.policyBody"))
                .font(.body)
                .lineSpacing(6)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value = value else {
            return "--"
        }
        return String(format: "%.1f%@", value, unit)
    }

    private func startCameraScan() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            imagePickerSourceType = .camera
            showImagePicker = true
        } else if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            imagePickerSourceType = .photoLibrary
            showImagePicker = true
        } else {
            showOCRError(message: settings.localized("health.ocrInvalidImage"))
        }
    }

    private func requestAuthorization() {
        manager.requestAuthorization { success in
            if success {
                manager.refreshLatestMeasurements()
            }
        }
    }

    private var caregiverSelectionSheet: some View {
        NavigationView {
            Form {
                Section(header: Text(settings.localized("health.selectCaregiver"))) {
                    Picker(settings.localized("health.selectCaregiver"), selection: $selectedCaregiverSelection) {
                        ForEach(scheduleManager.caregivers, id: \.id) { caregiver in
                            Text(caregiver.name).tag(CaregiverSelection.existing(caregiver.id))
                        }
                        Text(settings.localized("health.externalHelper")).tag(CaregiverSelection.external)
                    }
                    .pickerStyle(.menu)

                    if selectedCaregiverSelection == .external {
                        TextField(settings.localized("schedule.emailPlaceholder"), text: $externalEmail)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.phonePlaceholder"), text: $externalPhone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }

                Section {
                    Toggle(settings.localized("health.addToSchedule"), isOn: $addToCalendar)
                }
            }
            .navigationTitle(settings.localized("health.selectCaregiverTitle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.localized("home.cancel")) {
                        showCaregiverSelection = false
                        resetAppointmentState()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.localized("home.ok")) {
                        confirmAppointmentShift()
                    }
                    .disabled(selectedCaregiverSelection == .external && externalEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && externalPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func resetAppointmentState() {
        parsedAppointment = nil
        selectedCaregiverSelection = .external
        externalEmail = ""
        externalPhone = ""
        addToCalendar = true
    }

    private func confirmAppointmentShift() {
        guard let appointment = parsedAppointment else { return }
        let assignment: (String, String, String)
        switch selectedCaregiverSelection {
        case .existing(let id):
            if let caregiver = scheduleManager.caregivers.first(where: { $0.id == id }) {
                assignment = (caregiver.name, caregiver.email, caregiver.phone)
            } else {
                assignment = (settings.localized("health.externalHelper"), externalEmail, externalPhone)
            }
        case .external:
            guard !externalEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !externalPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ocrFailureMessage = settings.localized("health.externalContactRequired")
                showOCRFailureAlert = true
                return
            }
            assignment = (settings.localized("health.externalHelper"), externalEmail, externalPhone)
        }

        let endDate = Calendar.current.date(byAdding: .hour, value: 2, to: appointment.date) ?? appointment.date
        let newShift = Shift(assignee: assignment.0,
                             start: appointment.date,
                             end: endDate,
                             taskSummary: String(format: settings.localized("health.appointmentTaskSummary"), appointment.doctorName),
                             status: .assigned,
                             note: appointment.rawText,
                             contactEmail: assignment.1,
                             contactPhone: assignment.2)

        if addToCalendar {
            scheduleManager.addShift(newShift)
            appointmentConfirmationMessage = settings.localized("health.appointmentAdded")
        } else {
            appointmentConfirmationMessage = settings.localized("health.appointmentNotAdded")
        }

        showAppointmentConfirmationAlert = true
        showCaregiverSelection = false
        resetAppointmentState()
    }

    private func recognizeText(in image: UIImage) {
        guard let cgImage = image.cgImage else {
            showOCRError(message: settings.localized("health.ocrInvalidImage"))
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showOCRError(message: error.localizedDescription)
                    return
                }
                let recognizedText = request.results?
                    .compactMap { ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string }
                    .joined(separator: " ") ?? ""

                self.handleRecognizedText(recognizedText)
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.showOCRError(message: error.localizedDescription)
                }
            }
        }
    }

    private func handleRecognizedText(_ text: String) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty, let appointment = parseAppointmentDetails(from: cleanedText) else {
            showOCRError(message: settings.localized("health.ocrNoText"))
            return
        }
        parsedAppointment = appointment
        showCaregiverSelection = true
    }

    private func showOCRError(message: String) {
        ocrFailureMessage = message
        showOCRFailureAlert = true
    }

    private func parseAppointmentDetails(from text: String) -> ParsedAppointment? {
        guard let date = extractAppointmentDate(from: text), let doctor = extractDoctorName(from: text) else {
            return nil
        }
        return ParsedAppointment(date: date, doctorName: doctor, rawText: text)
    }

    private func extractAppointmentDate(from text: String) -> Date? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let matches = detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let date = match.date {
                    return date
                }
            }
        }

        let patterns = ["\\d{4}[./-]\\d{1,2}[./-]\\d{1,2}\\s*\\d{1,2}:\\d{2}",
                        "\\d{4}[./-]\\d{1,2}[./-]\\d{1,2}",
                        "\\d{1,2}[./-]\\d{1,2}\\s*\\d{1,2}:\\d{2}",
                        "\\d{1,2}[./-]\\d{1,2}"]
        for pattern in patterns {
            if let match = matchRegex(pattern, in: text)?.first {
                if let date = parseDateString(match) {
                    return date
                }
            }
        }
        return nil
    }

    private func extractDoctorName(from text: String) -> String? {
        let patterns = ["(?:醫生|醫師)[:：\\s]*([^,，。\n]+)",
                        "(?:Dr\\.?|Doctor)\\s*([A-Za-z\\u4e00-\\u9fff]+)"]
        for pattern in patterns {
            if let match = matchRegex(pattern, in: text)?.first {
                return match.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lines = text.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            if line.contains("醫生") || line.contains("醫師") {
                let components = line.components(separatedBy: CharacterSet(charactersIn: ":："))
                if components.count > 1 {
                    return components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func matchRegex(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func parseDateString(_ string: String) -> Date? {
        let formats = ["yyyy/MM/dd HH:mm", "yyyy-M-d HH:mm", "yyyy.MM.dd HH:mm", "yyyy年M月d日 HH:mm", "yyyy/MM/dd", "yyyy-M-d", "yyyy.MM.dd", "M/d HH:mm", "M.d HH:mm", "M/d", "M.d"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                if format.contains("yyyy") {
                    return date
                } else {
                    var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    let currentYear = Calendar.current.component(.year, from: Date())
                    components.year = currentYear
                    return Calendar.current.date(from: components)
                }
            }
        }
        return nil
    }

    private func uploadHealthSummary() {
        guard let temperature = manager.temperature,
              let spo2 = manager.oxygenSaturation,
              let systolic = manager.systolicPressure,
              let diastolic = manager.diastolicPressure else {
            uploadMessage = settings.localized("health.noValidData")
            showUploadAlert = true
            return
        }

        isUploading = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())

        var urlComponents = URLComponents(string: Setting.shared.appScriptUrl)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: "health_summary"),
            URLQueryItem(name: "datetime", value: timestamp),
            URLQueryItem(name: "temperature", value: String(format: "%.1f", temperature)),
            URLQueryItem(name: "spo2", value: String(format: "%.1f", spo2)),
            URLQueryItem(name: "systolic", value: String(format: "%.0f", systolic)),
            URLQueryItem(name: "diastolic", value: String(format: "%.0f", diastolic)),
            URLQueryItem(name: "user", value: Setting.shared.username),
            URLQueryItem(name: "patientName", value: settings.patientName),
            URLQueryItem(name: "patientAge", value: String(settings.patientAge)),
            URLQueryItem(name: "patientGender", value: settings.localized(settings.patientGenderKey))
        ]

        guard let url = urlComponents.url else {
            isUploading = false
            uploadMessage = settings.localized("health.uploadFailed")
            showUploadAlert = true
            return
        }

        URLSession.shared.dataTask(with: url) { _, response, error in
            DispatchQueue.main.async {
                isUploading = false
                if let error = error {
                    uploadMessage = String(format: settings.localized("health.uploadError"), error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        uploadMessage = settings.localized("health.uploadSuccess")
                    } else {
                        uploadMessage = String(format: settings.localized("health.uploadFailedStatus"), String(httpResponse.statusCode))
                    }
                } else {
                    uploadMessage = settings.localized("health.uploadUnknownError")
                }
                showUploadAlert = true
            }
        }.resume()
    }
}

struct HealthKitDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            HealthKitDashboardView()
                .environmentObject(AppSettings.shared)
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImagePicked: (UIImage) -> Void

        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true, completion: nil)
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true, completion: nil)
        }
    }
}
