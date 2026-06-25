import SwiftUI
import UIKit
import HealthKit
import Vision

// MARK: - Appointment Scanner View
//
// OCR uses Apple's on-device Vision framework (the iPad's built-in AI for text
// recognition — no network calls, no third-party services).
//
// Date/time extraction uses Apple's NSDataDetector. Place + specialist-clinic
// extraction uses a lightweight multilingual keyword classifier (no LLM).
//
// After scanning, the user is shown an editable review sheet whose fields
// mirror the "Add Shift" form in the Care Schedule Board:
//   • Start / End time
//   • Frequency (none / daily / monthly / yearly)
//   • Task summary    — auto-filled with place + specialist clinic
//   • Notes           — left empty by default
//   • Assignee        — to be entered by the user
//   • Contact email   — to be entered by the user
//   • Contact phone   — to be entered by the user
//
// Tapping Save inserts the resulting shift(s) directly into
// CareScheduleManager via addShift(_:) so the appointment shows up
// immediately on the Care Schedule Board.

struct AppointmentScannerView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = HealthKitManager.shared
    @StateObject private var scheduleManager = CareScheduleManager.shared

    var initialCameraScan: Bool = false

    // Image picker state
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .camera
    @State private var hasAutomaticallyLaunchedCamera = false

    // OCR error
    @State private var showOCRFailureAlert = false
    @State private var ocrFailureMessage = ""

    // Review sheet
    @State private var showReviewSheet = false
    @State private var rawScannedText: String = ""
    @State private var detectedDate: Bool = false

    // Editable shift fields (pre-filled after OCR; user adjusts before save)
    @State private var formStart: Date = Date()
    @State private var formEnd: Date = Date().addingTimeInterval(2 * 3600)
    @State private var formTaskSummary: String = ""
    @State private var formNote: String = ""
    @State private var formAssignee: String = ""
    @State private var formContactEmail: String = ""
    @State private var formContactPhone: String = ""
    @State private var formFrequency: RecurrenceOption = .none

    // Quick-fill from saved caregivers (optional — text fields stay editable)
    @State private var formSelectedCaregiverId: UUID? = nil

    // Completion alert
    @State private var showAppointmentConfirmationAlert = false
    @State private var appointmentConfirmationMessage = ""

    // Mirrors the private enum in ScheduleBoardView so the scanner can offer
    // the same frequency choices.
    private enum RecurrenceOption: String, CaseIterable, Identifiable {
        case none
        case daily
        case monthly
        case yearly

        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .none:    return "schedule.recurrence.none"
            case .daily:   return "schedule.recurrence.daily"
            case .monthly: return "schedule.recurrence.monthly"
            case .yearly:  return "schedule.recurrence.yearly"
            }
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(settings.localized("health.scanAppointment"))
                        .font(settings.scaledFont(24, weight: .bold))
                        .padding(.top, 24)

                    Text(settings.localized("health.selectImageSource"))
                        .font(settings.scaledFont(16))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: startCameraScan) {
                        Label(settings.localized("health.takePhoto"), systemImage: "camera")
                            .font(settings.scaledFont(18, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color(.systemBlue))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)

                    Button(action: {
                        imagePickerSourceType = .photoLibrary
                        showImagePicker = true
                    }) {
                        Label(settings.localized("health.choosePhoto"), systemImage: "photo.on.rectangle")
                            .font(settings.scaledFont(18, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color(.systemGray))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
            }
            .navigationTitle(settings.localized("health.scanAppointment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.localized("home.cancel")) { dismiss() }
                }
            }
            .onAppear {
                if initialCameraScan && !hasAutomaticallyLaunchedCamera {
                    hasAutomaticallyLaunchedCamera = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        startCameraScan()
                    }
                }
            }
            .fullScreenCover(isPresented: $showImagePicker) {
                CameraImagePicker(sourceType: imagePickerSourceType, onPhotoLibrarySelected: {
                    imagePickerSourceType = .photoLibrary
                    showImagePicker = true
                }) { image in
                    recognizeText(in: image)
                }
            }
            .sheet(isPresented: $showReviewSheet) {
                reviewSheet
            }
            .alert(settings.localized("health.ocrFailed"), isPresented: $showOCRFailureAlert) {
                Button(settings.localized("home.ok"), role: .cancel) {}
            } message: {
                Text(ocrFailureMessage)
            }
            .alert(settings.localized("health.appointmentCreated"), isPresented: $showAppointmentConfirmationAlert) {
                Button(settings.localized("common.ok"), role: .cancel) {
                    dismiss()
                }
            } message: {
                Text(appointmentConfirmationMessage)
            }
        }
    }

    // MARK: Editable Review Sheet — fields mirror the Care Schedule Board's
    // Add Shift form so users get the same experience.

    private var reviewSheet: some View {
        NavigationView {
            Form {
                Section {
                    Text(settings.localized("appointment.review.subtitle"))
                        .font(settings.scaledFont(14))
                        .foregroundColor(.secondary)
                    if !detectedDate {
                        Label(settings.localized("appointment.review.noDateDetected"),
                              systemImage: "exclamationmark.triangle")
                            .font(settings.scaledFont(14, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                }

                // 1. Start/End time + Frequency
                Section(header: Text(settings.localized("appointment.review.detailsSection"))) {
                    DatePicker(settings.localized("schedule.startTime"),
                               selection: $formStart,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker(settings.localized("schedule.endTime"),
                               selection: $formEnd,
                               displayedComponents: [.date, .hourAndMinute])
                    Picker(settings.localized("schedule.recurrenceLabel"),
                           selection: $formFrequency) {
                        ForEach(RecurrenceOption.allCases) { option in
                            Text(settings.localized(option.titleKey)).tag(option)
                        }
                    }
                }

                // 2. Task summary + Notes
                Section(header: Text(settings.localized("appointment.review.summarySection"))) {
                    TextField(settings.localized("appointment.review.taskSummaryPlaceholder"),
                              text: $formTaskSummary, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(2...4)
                    TextField(settings.localized("appointment.review.notePlaceholder"),
                              text: $formNote, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(2...5)
                }

                // 3. Assignee + contact
                // If saved caregivers exist, a dropdown lets the user pick
                // one to auto-fill all three fields. The text fields remain
                // editable for manual entry or to override the auto-filled
                // values. "Custom caregiver" means fully manual entry.
                Section(header: Text(settings.localized("appointment.review.contactSection"))) {
                    if !scheduleManager.caregivers.isEmpty {
                        Picker(settings.localized("schedule.selectCaregiver"),
                               selection: $formSelectedCaregiverId) {
                            Text(settings.localized("schedule.customCaregiver"))
                                .tag(UUID?.none)
                            ForEach(scheduleManager.caregivers) { caregiver in
                                Text(caregiver.name).tag(Optional(caregiver.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: formSelectedCaregiverId) { _, _ in
                            applyCaregiverQuickFill()
                        }
                    }

                    TextField(settings.localized("schedule.assigneePlaceholder"),
                              text: $formAssignee)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    TextField(settings.localized("schedule.emailPlaceholder"),
                              text: $formContactEmail)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    TextField(settings.localized("schedule.phonePlaceholder"),
                              text: $formContactPhone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                if !rawScannedText.isEmpty {
                    Section(header: Text(settings.localized("appointment.review.scannedText"))) {
                        Text(rawScannedText)
                            .font(settings.scaledFont(13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(settings.localized("appointment.review.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.localized("home.cancel")) {
                        showReviewSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.localized("schedule.save")) {
                        confirmAppointmentShift()
                    }
                    .disabled(!isReviewFormValid)
                }
            }
        }
    }

    private var isReviewFormValid: Bool {
        let assignee = formAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary  = formTaskSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !assignee.isEmpty && !summary.isEmpty && formEnd >= formStart
    }

    /// When the user picks a saved caregiver from the dropdown, auto-fill
    /// the three contact text fields (name / email / phone). Picking
    /// "Custom caregiver" clears the fields so the user can type freely.
    private func applyCaregiverQuickFill() {
        guard let id = formSelectedCaregiverId,
              let caregiver = scheduleManager.caregivers.first(where: { $0.id == id }) else {
            // "Custom caregiver" selected — clear for manual entry.
            formAssignee = ""
            formContactEmail = ""
            formContactPhone = ""
            return
        }
        formAssignee = caregiver.name
        formContactEmail = caregiver.email
        formContactPhone = caregiver.phone
    }

    /// Builds the shift(s) (with frequency-based recurrence) and pushes them
    /// into CareScheduleManager so they appear on the Care Schedule Board.
    private func confirmAppointmentShift() {
        let assignee = formAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary  = formTaskSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseShift = Shift(
            assignee: assignee,
            start: formStart,
            end: formEnd,
            taskSummary: summary,
            status: .assigned,
            note: formNote,
            contactEmail: formContactEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            contactPhone: formContactPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let shiftsToAdd = expandRecurrence(of: baseShift, frequency: formFrequency)

        // Snapshot the shift count BEFORE adding so we can tell whether
        // CareScheduleManager actually accepted the new shift (it can refuse
        // if the assignee is currently banned for the week).
        let countBefore = scheduleManager.shifts.count
        shiftsToAdd.forEach { scheduleManager.addShift($0) }
        let added = scheduleManager.shifts.count - countBefore

        if added == 0 {
            // Likely blocked. Surface the manager's own message so the user
            // understands why nothing was added.
            ocrFailureMessage = scheduleManager.assignmentBlockedMessage
                ?? settings.localized("health.appointmentNotAdded")
            showOCRFailureAlert = true
            return
        }

        // Tell the user the exact date their shift landed on so they can
        // navigate to it on the schedule board's calendar. (Previously a
        // generic "added" message left them looking at today's date and
        // wondering where the shift went.)
        let dateString = humanDate(formStart)
        if added > 1 {
            let template = settings.localized("health.appointmentAddedRecurring")
            appointmentConfirmationMessage = String(format: template, added, dateString)
        } else {
            let template = settings.localized("health.appointmentAdded")
            appointmentConfirmationMessage = String(format: template, dateString)
        }
        showReviewSheet = false
        showAppointmentConfirmationAlert = true
    }

    private func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Mirrors ScheduleBoardView.createRecurringShifts so the scanner offers
    /// identical frequency behaviour to "Add Shift" on the schedule board.
    private func expandRecurrence(of base: Shift, frequency: RecurrenceOption) -> [Shift] {
        guard frequency != .none else { return [base] }

        let calendar = Calendar.current
        let duration = base.end.timeIntervalSince(base.start)
        let occurrences: [Date]
        switch frequency {
        case .daily:
            occurrences = (1...30).compactMap { calendar.date(byAdding: .day, value: $0, to: base.start) }
        case .monthly:
            occurrences = (1...11).compactMap { calendar.date(byAdding: .month, value: $0, to: base.start) }
        case .yearly:
            occurrences = (1...2).compactMap { calendar.date(byAdding: .year, value: $0, to: base.start) }
        case .none:
            occurrences = []
        }

        var shifts: [Shift] = [base]
        for start in occurrences {
            var copy = base
            copy.id = UUID()
            copy.start = start
            copy.end = start.addingTimeInterval(duration)
            shifts.append(copy)
        }
        return shifts
    }

    // MARK: Camera

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

    private func showOCRError(message: String) {
        ocrFailureMessage = message
        showOCRFailureAlert = true
    }

    // MARK: OCR (Apple Vision — on-device)

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
                    .joined(separator: "\n") ?? ""
                self.handleRecognizedText(recognizedText)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US", "id-ID"]

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
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            showOCRError(message: settings.localized("health.ocrNoText"))
            return
        }

        rawScannedText = cleaned

        // Reset user-entered fields (per spec these come from the user).
        formSelectedCaregiverId = nil  // Reset dropdown to "Custom caregiver"
        formAssignee = ""
        formContactEmail = ""
        formContactPhone = ""
        formNote = ""                 // Notes left empty per spec.
        formFrequency = .none

        // Date/time → start/end pickers.
        if let detected = firstDate(in: cleaned) {
            formStart = detected
            formEnd = Calendar.current.date(byAdding: .hour, value: 2, to: detected) ?? detected
            detectedDate = true
        } else {
            let now = Date()
            formStart = now
            formEnd = now.addingTimeInterval(2 * 3600)
            detectedDate = false
        }

        // Task summary = "Place — Specialist clinic" (per spec).
        formTaskSummary = buildTaskSummary(from: cleaned)

        showReviewSheet = true
    }

    // MARK: Extraction helpers (Apple NSDataDetector + lightweight heuristics)

    /// Uses Apple's built-in NSDataDetector — recognises dates in many formats
    /// across Chinese / English / Indonesian without manual regex tuning.
    private func firstDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        // Prefer the first match that has BOTH a date AND a time component.
        for match in matches {
            if let date = match.date {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                if (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 {
                    return date
                }
            }
        }
        return matches.first?.date
    }

    /// Returns "Place — Specialist clinic" if both are detected, otherwise
    /// whichever single piece was found, or a localized fallback.
    private func buildTaskSummary(from text: String) -> String {
        let facility   = extractFacilityLine(from: text)
        let department = extractDepartmentLine(from: text, excluding: facility)

        switch (facility, department) {
        case let (place?, dept?):
            return "\(place) — \(dept)"
        case let (place?, nil):
            return place
        case let (nil, dept?):
            return dept
        case (nil, nil):
            return settings.localized("appointment.review.suggestedTaskSummary")
        }
    }

    /// Multilingual keyword set for "place" / hospital / clinic.
    private static let facilityKeywords: [String] = [
        // zh-Hant / zh-Hans
        "醫院", "医院", "醫學中心", "医学中心", "醫療中心", "医疗中心",
        "健康中心", "保健中心", "服務中心", "评估中心", "評估中心",
        "診所", "诊所", "衛生所", "卫生所", "門診部", "门诊部",
        // English
        "hospital", "clinic", "medical center", "medical centre",
        "health center", "health centre", "polyclinic", "healthcare",
        // Indonesian
        "rumah sakit", "klinik", "puskesmas", "poliklinik", "klinik kesehatan"
    ]

    /// Multilingual keyword set for medical specialty / department / clinic-of.
    private static let departmentKeywords: [String] = [
        // zh — common specialties
        "科別", "科别", "門診", "门诊", "科:", "科：",
        "內科", "内科", "外科", "心臟內科", "心脏内科", "心臟科", "心脏科",
        "神經內科", "神经内科", "神經科", "神经科", "骨科", "復健科", "复健科",
        "牙科", "眼科", "耳鼻喉科", "皮膚科", "皮肤科",
        "婦產科", "妇产科", "兒科", "儿科", "家醫科", "家医科",
        "風濕免疫科", "风湿免疫科", "新陳代謝科", "新陈代谢科",
        "腎臟科", "肾脏科", "泌尿科", "精神科", "急診", "急诊", "腫瘤科", "肿瘤科",
        // English
        "department of", "dept.", "department", "clinic of", "specialty",
        "cardiology", "neurology", "orthopedics", "orthopaedics",
        "dermatology", "ophthalmology", "otolaryngology", "ent",
        "pediatrics", "paediatrics", "geriatrics", "oncology",
        "urology", "gynecology", "gynaecology", "obstetrics",
        "psychiatry", "rheumatology", "endocrinology", "nephrology",
        // Indonesian
        "poli", "spesialis", "dokter spesialis", "departemen",
        "poli jantung", "poli anak", "poli kulit", "poli mata", "poli umum"
    ]

    private func extractFacilityLine(from text: String) -> String? {
        let lines = text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines {
            let lower = line.lowercased()
            if Self.facilityKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                return line
            }
        }
        return nil
    }

    private func extractDepartmentLine(from text: String, excluding facility: String?) -> String? {
        let lines = text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines {
            if let facility = facility, line == facility { continue }
            let lower = line.lowercased()
            if Self.departmentKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                // Avoid lines that are clearly the facility too.
                if !Self.facilityKeywords.contains(where: { lower.contains($0.lowercased()) }) {
                    return line
                }
            }
        }
        return nil
    }
}

// MARK: - Camera / Image Picker wrapper

struct CameraImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var onPhotoLibrarySelected: (() -> Void)? = nil
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        if sourceType == .camera {
            picker.showsCameraControls = true
            context.coordinator.picker = picker
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, onPhotoLibrarySelected: onPhotoLibrarySelected)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        weak var picker: UIImagePickerController?
        let onImagePicked: (UIImage) -> Void
        let onPhotoLibrarySelected: (() -> Void)?

        init(onImagePicked: @escaping (UIImage) -> Void, onPhotoLibrarySelected: (() -> Void)?) {
            self.onImagePicked = onImagePicked
            self.onPhotoLibrarySelected = onPhotoLibrarySelected
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

        @objc func openPhotoLibrary() {
            picker?.dismiss(animated: true) {
                self.onPhotoLibrarySelected?()
            }
        }
    }
}
