//
//  AppointmentScannerView.swift
//
//  Appointment slip scanner.
//
//  This version replaces Vision OCR + Apple Intelligence with direct
//  image-to-OpenRouter vision analysis.
//
//  The LLM analyzes the whole appointment slip photo and returns JSON for:
//  - clinicName
//  - caseType
//  - department
//  - address
//  - appointment date
//  - registration time
//
//  Output behavior follows the original AppointmentScanner:
//  - Task row format: Type, Department, Address
//  - Registration time is center point
//  - Start time = 1 hour before registration time
//  - End time = 1 hour after registration time
//  - Remarks/note format: dd/MM/yyyy hh:mm am/pm
//

import SwiftUI
import UIKit
import PhotosUI
import Foundation
import Combine

// MARK: - AppointmentScannerView

struct AppointmentScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @ObservedObject private var scheduleManager = CareScheduleManager.shared

    /// Camera should not auto-start when opening this view.
    /// Keep this property only for compatibility with existing callers.
    var initialCameraScan: Bool = false

    @State private var showCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var isProcessing = false
    @State private var processingMessage = ""

    /// Currently-running analysis Task — kept so the user's "Abort"
    /// button can cancel it mid-flight.
    @State private var analysisTask: Task<Void, Never>?

    /// Seconds the user has been waiting for the AI to respond. Driven
    /// by `processingTimer` and displayed underneath the spinner so the
    /// wait doesn't feel silent.
    @State private var processingElapsed: Int = 0

    /// 1 Hz publisher used to bump `processingElapsed` while the
    /// overlay is visible.
    private let processingTimer = Timer.publish(
        every: 1, on: .main, in: .common
    ).autoconnect()

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    @State private var showReviewSheet = false

    // Review form fields
    @State private var formStart = Date()
    @State private var formEnd = Date().addingTimeInterval(2 * 60 * 60)
    @State private var formTaskSummary = ""
    @State private var formNotes = ""
    @State private var formFrequency: AppointmentRecurrenceFrequency = .none

    @State private var selectedCaregiverId: UUID?
    @State private var formAssigneeName = ""
    @State private var formAssigneeEmail = ""
    @State private var formAssigneePhone = ""

    @State private var lastOCRText = ""

    // For testing only.
    // Do NOT hardcode API keys in production apps.
    // Prefer calling your own backend instead.
    private let openRouterAPIKey = "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"

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 24) {
                    header

                    VStack(spacing: 16) {
                        Button {
                            showCamera = true
                        } label: {
                            Label(localizedOrDefault("health.takePhoto", "Take photo"), systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label(localizedOrDefault("health.choosePhoto", "Choose from library"), systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top)

                if isProcessing {
                    processingOverlay
                }
            }
            .navigationTitle(localizedOrDefault("health.scanAppointment", "Scan appointment document"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localizedOrDefault("schedule.close", "Close")) {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker { image in
                    startAnalysisTask(for: image)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showReviewSheet) {
                reviewSheet
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button(localizedOrDefault("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }

                Task {
                    await loadPhotoPickerItem(item)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(.blue)

            Text(localizedOrDefault("health.scanAppointment", "Scan appointment document"))
                .font(.title2.bold())

            Text(scannerDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var scannerDescription: String {
        switch settings.language {
        case .chinese:
            return "請選擇拍照或從相簿選取整張覆診紙，系統會自動識別類型、科別、地址及登記時間。"
        case .english:
            return "Choose camera or photo library. The app will detect the type, department, address, and registration time."
        case .indonesian:
            return "Pilih kamera atau galeri foto. Aplikasi akan mendeteksi jenis, departemen, alamat, dan waktu pendaftaran."
        }
    }

    private var localizedTaskTitle: String {
        switch settings.language {
        case .chinese:
            return "任務"
        case .english:
            return "Task"
        case .indonesian:
            return "Tugas"
        }
    }

    private var localizedTaskPlaceholder: String {
        switch settings.language {
        case .chinese:
            return "類型、科別、地址"
        case .english:
            return "Type, Department, Address"
        case .indonesian:
            return "Jenis, Departemen, Alamat"
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.25)

                Text(processingMessage.isEmpty ? localizedProcessingText("processing") : processingMessage)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                // Live status line: elapsed seconds + a hint about how
                // long the AI normally takes. Helps users know we
                // haven't frozen and gives them context for the wait.
                VStack(spacing: 4) {
                    Text(elapsedStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(stageHintLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Abort: cancels the running analysis Task so the user
                // isn't stuck waiting on a slow / stalled AI call.
                Button(role: .destructive) {
                    abortAnalysis()
                } label: {
                    Label(localizedAbortLabel,
                          systemImage: "xmark.circle.fill")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 6)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding()
            .onReceive(processingTimer) { _ in
                guard isProcessing else { return }
                processingElapsed += 1
            }
        }
    }

    /// "Elapsed: 12s" / "已等候 12 秒" / "Sudah 12 detik".
    private var elapsedStatusLine: String {
        switch settings.language {
        case .chinese:
            return "已等候 \(processingElapsed) 秒"
        case .english:
            return "Elapsed: \(processingElapsed)s"
        case .indonesian:
            return "Sudah \(processingElapsed) detik"
        }
    }

    /// Gentle hint about how long the AI call typically takes so users
    /// don't think the app is frozen at the 30-second mark.
    private var stageHintLine: String {
        switch settings.language {
        case .chinese:
            return "AI 通常需要 15–60 秒，請耐心等候。"
        case .english:
            return "The AI usually responds in 15–60 seconds."
        case .indonesian:
            return "AI biasanya merespons dalam 15–60 detik."
        }
    }

    private var localizedAbortLabel: String {
        switch settings.language {
        case .chinese:
            return "取消分析"
        case .english:
            return "Abort"
        case .indonesian:
            return "Batalkan"
        }
    }

    /// Human-readable label for each pipeline stage reported by
    /// `OpenRouterAppointmentVisionService`. This is the actual "status"
    /// (what we're doing right now), not a wall-clock timer.
    private func stageLabel(for stage: OpenRouterAppointmentVisionService.Stage) -> String {
        switch (stage, settings.language) {
        case (.preparingImage, .chinese):
            return "狀態：正在準備圖片…"
        case (.preparingImage, .english):
            return "Status: Preparing image…"
        case (.preparingImage, .indonesian):
            return "Status: Menyiapkan gambar…"

        case (.encodingRequest, .chinese):
            return "狀態：正在編碼上傳資料…"
        case (.encodingRequest, .english):
            return "Status: Encoding request…"
        case (.encodingRequest, .indonesian):
            return "Status: Mengkodekan permintaan…"

        case (.uploadingToAI, .chinese):
            return "狀態：正在上傳圖片到 AI…"
        case (.uploadingToAI, .english):
            return "Status: Uploading image to AI…"
        case (.uploadingToAI, .indonesian):
            return "Status: Mengunggah gambar ke AI…"

        case (.waitingForAIResult, .chinese):
            return "狀態：正在等待 AI 模型回覆…"
        case (.waitingForAIResult, .english):
            return "Status: Waiting for AI model response…"
        case (.waitingForAIResult, .indonesian):
            return "Status: Menunggu respons model AI…"

        case (.parsingResult, .chinese):
            return "狀態：正在解析 AI 回覆…"
        case (.parsingResult, .english):
            return "Status: Parsing AI response…"
        case (.parsingResult, .indonesian):
            return "Status: Mengurai respons AI…"
        }
    }

    private var reviewSheet: some View {
        NavigationStack {
            Form {
                Section(localizedTaskTitle) {
                    TextField(
                        localizedTaskPlaceholder,
                        text: $formTaskSummary
                    ) {
                        Text(localizedTaskTitle)
                    }
                }

                Section(localizedOrDefault("appointment.review.detailsSection", "Time & frequency")) {
                    DatePicker(
                        localizedOrDefault("schedule.startTime", "Start time"),
                        selection: $formStart,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    DatePicker(
                        localizedOrDefault("schedule.endTime", "End time"),
                        selection: $formEnd,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Picker(localizedOrDefault("schedule.recurrenceLabel", "Recurrence"), selection: $formFrequency) {
                        ForEach(AppointmentRecurrenceFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.title(settings: settings)).tag(frequency)
                        }
                    }
                }

                Section(localizedOrDefault("appointment.review.contactSection", "Assignee & contact")) {
                    Picker(localizedOrDefault("schedule.selectCaregiver", "Select caregiver"), selection: $selectedCaregiverId) {
                        Text(localizedOrDefault("schedule.assignee.notAssigned", "Not assigned"))
                            .tag(UUID?.none)

                        ForEach(scheduleManager.caregivers) { caregiver in
                            Text(caregiver.icon.isEmpty ? caregiver.name : "\(caregiver.icon)  \(caregiver.name)")
                                .tag(Optional(caregiver.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedCaregiverId) { _, _ in
                        applySelectedCaregiver()
                    }

                    TextField(localizedOrDefault("schedule.assigneePlaceholder", "Assignee"), text: $formAssigneeName)

                    TextField(localizedOrDefault("schedule.emailPlaceholder", "Email"), text: $formAssigneeEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)

                    TextField(localizedOrDefault("schedule.phonePlaceholder", "Phone"), text: $formAssigneePhone)
                        .keyboardType(.phonePad)
                }

                Section(localizedOrDefault("appointment.review.remarksSection", remarksSectionTitle)) {
                    TextEditor(text: $formNotes)
                        .frame(minHeight: 80)
                }

                if !lastOCRText.isEmpty {
                    Section(localizedOrDefault("appointment.review.ocrResult", ocrResultTitle)) {
                        Text(lastOCRText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(localizedOrDefault("appointment.review.title", "Confirm appointment details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(localizedOrDefault("schedule.cancel", "Cancel")) {
                        showReviewSheet = false
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(localizedOrDefault("schedule.save", "Save")) {
                        saveReviewedAppointment()
                    }
                    .bold()
                    .disabled(formEnd <= formStart || formTaskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var remarksSectionTitle: String {
        switch settings.language {
        case .chinese:
            return "備註"
        case .english:
            return "Remarks"
        case .indonesian:
            return "Catatan"
        }
    }

    private var ocrResultTitle: String {
        switch settings.language {
        case .chinese:
            return "AI 分析結果"
        case .english:
            return "AI Analysis Result"
        case .indonesian:
            return "Hasil Analisis AI"
        }
    }

    private func localizedOrDefault(_ key: String, _ fallback: String) -> String {
        let value = settings.localized(key)
        return value == key ? fallback : value
    }

    private func localizedProcessingText(_ key: String) -> String {
        switch key {
        case "loading":
            switch settings.language {
            case .chinese:
                return "正在載入圖片…"
            case .english:
                return "Loading image…"
            case .indonesian:
                return "Memuat gambar…"
            }

        case "ai":
            switch settings.language {
            case .chinese:
                return "正在分析覆診紙圖片…"
            case .english:
                return "Analyzing appointment slip image…"
            case .indonesian:
                return "Menganalisis gambar dokumen janji temu…"
            }

        default:
            switch settings.language {
            case .chinese:
                return "處理中…"
            case .english:
                return "Processing…"
            case .indonesian:
                return "Memproses…"
            }
        }
    }
}

// MARK: - Main Image Analysis Flow

extension AppointmentScannerView {
    @MainActor
    private func loadPhotoPickerItem(_ item: PhotosPickerItem) async {
        do {
            beginProcessing(message: localizedProcessingText("loading"))

            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw AppointmentScannerError.imageEncodingFailed
            }

            endProcessing()
            startAnalysisTask(for: image)

        } catch {
            endProcessing()
            presentError(error)
        }
    }

    /// Kick off the AI analysis in a tracked Task so the Abort button
    /// (and `abortAnalysis()`) can cancel it cleanly.
    @MainActor
    private func startAnalysisTask(for image: UIImage) {
        analysisTask?.cancel()
        analysisTask = Task { @MainActor in
            await analyzeAppointmentSlip(image)
            analysisTask = nil
        }
    }

    @MainActor
    private func analyzeAppointmentSlip(_ image: UIImage) async {
        // Start the overlay with the first stage label; the progress
        // callback will keep `processingMessage` in sync with the real
        // pipeline stage as the request advances.
        beginProcessing(message: stageLabel(for: .preparingImage))

        do {
            let result = try await OpenRouterAppointmentVisionService.analyzeAppointmentImage(
                image: image,
                apiKey: openRouterAPIKey,
                progress: { stage in
                    // Already hopped to the main actor by the closure
                    // annotation, so it's safe to mutate @State here.
                    self.processingMessage = self.stageLabel(for: stage)
                }
            )

            // If the user tapped Abort while we were waiting, drop the
            // result silently instead of pushing the review sheet.
            if Task.isCancelled {
                endProcessing()
                return
            }

            lastOCRText = result.evidence
            applyExtractionResult(result)

            endProcessing()

        } catch is CancellationError {
            // User aborted — nothing to show, no error to surface.
            endProcessing()
        } catch {
            // URLSession reports cancellations as NSURLErrorCancelled;
            // treat them the same as an explicit user abort.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                endProcessing()
                return
            }
            endProcessing()
            presentError(error)
        }
    }

    // MARK: - Processing-state helpers

    /// Show the overlay, reset the elapsed counter, and (optionally)
    /// pre-set the status line that appears above the spinner.
    @MainActor
    private func beginProcessing(message: String) {
        processingMessage = message
        processingElapsed = 0
        isProcessing = true
    }

    @MainActor
    private func endProcessing() {
        isProcessing = false
        processingElapsed = 0
    }

    /// Triggered by the Abort button on the processing overlay. Cancels
    /// the running Task; the analyze function then drops the half-baked
    /// result on the floor.
    @MainActor
    private func abortAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        endProcessing()
    }
}

// MARK: - Applying Result

extension AppointmentScannerView {
    private static let remarksAppointmentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM/yyyy hh:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    @MainActor
    private func applyExtractionResult(_ result: AppointmentExtractionResult) {
        let appointmentDate = result.appointmentDate

        // Registration time is the center point.
        // Start = 1 hour before registration time.
        // End = 1 hour after registration time.
        formStart = Calendar.current.date(byAdding: .hour, value: -1, to: appointmentDate) ?? appointmentDate
        formEnd = Calendar.current.date(byAdding: .hour, value: 1, to: appointmentDate) ?? appointmentDate

        // When the AI flags this slip as a doctor consultation, override
        // the standard "新症 / 覆診 / unknown" label with the explicit
        // "覆診(醫生)" / "Follow-up (Doctor)" form so the care team can
        // tell at a glance that it's a doctor visit.
        let type: String = result.isDoctorAppointment
            ? localizedDoctorFollowUpLabel()
            : localizedCaseType(result.caseType)

        // Department from the AI is the specialist name (Family Medicine,
        // Cardiology, Urology, …). It appears as the second item in the
        // task summary verbatim — no "Department:" prefix.
        let department = localizedDepartment(result.department)
            ?? localizedOrDefault("appointment.department.unknown", "Department")

        let address = result.address?.nilIfBlank
            ?? result.clinicName?.nilIfBlank
            ?? localizedOrDefault("appointment.address.notFound", "Address not found")

        formTaskSummary = [
            type,
            department,
            address
        ].joined(separator: ", ")

        // Remarks now leads with "登記時間:" (Registration time:) so the
        // exported note matches the wording on the printed slip.
        let registrationLabel = localizedRegistrationLabel()
        let registrationText = Self.remarksAppointmentFormatter
            .string(from: appointmentDate)
            .lowercased()
        formNotes = "\(registrationLabel)\(registrationText)"

        print("APPLY FORM START:", formStart)
        print("APPLY FORM END:", formEnd)
        print("APPLY FORM NOTES:", formNotes)
        print("EXTRACTION EVIDENCE:", result.evidence)

        showReviewSheet = true
    }

    /// Label used when the AI explicitly identifies the slip as a doctor
    /// consultation. Always renders as "覆診(醫生)" in Chinese — English
    /// and Indonesian get matching forms.
    private func localizedDoctorFollowUpLabel() -> String {
        switch settings.language {
        case .chinese:
            return "覆診(醫生)"
        case .english:
            return "Follow-up (Doctor)"
        case .indonesian:
            return "Tindak lanjut (Dokter)"
        }
    }

    /// "登記時間:" prefix used in the auto-built remarks so the note
    /// matches the wording printed on the appointment slip.
    private func localizedRegistrationLabel() -> String {
        switch settings.language {
        case .chinese:
            return "登記時間: "
        case .english:
            return "登記時間: "
        case .indonesian:
            return "登記時間: "
        }
    }

    private func localizedCaseType(_ caseType: AppointmentCaseType) -> String {
        switch caseType {
        case .followUp:
            switch settings.language {
            case .chinese:
                return "覆診"
            case .english:
                return "Follow-up case"
            case .indonesian:
                return "Kasus tindak lanjut"
            }

        case .newCase:
            switch settings.language {
            case .chinese:
                return "新症"
            case .english:
                return "New case"
            case .indonesian:
                return "Kasus baru"
            }

        case .unknown:
            switch settings.language {
            case .chinese:
                return "覆診"
            case .english:
                return "Follow-up case"
            case .indonesian:
                return "Kasus tindak lanjut"
            }
        }
    }

    private func localizedDepartment(_ department: String?) -> String? {
        let original = department?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = original.lowercased()

        guard !normalized.isEmpty else {
            return nil
        }

        if normalized.contains("urology") ||
            normalized.contains("泌尿") ||
            normalized.contains("urologi") {
            switch settings.language {
            case .chinese:
                return "泌尿科"
            case .english:
                return "Urology"
            case .indonesian:
                return "Urologi"
            }
        }

        if normalized.contains("family medicine") ||
            normalized.contains("family medicine clinic") ||
            normalized.contains("家庭醫學") ||
            normalized.contains("家庭医学") ||
            normalized.contains("家庭醫學診所") ||
            normalized.contains("kedokteran keluarga") {
            switch settings.language {
            case .chinese:
                return "家庭醫學"
            case .english:
                return "Family Medicine"
            case .indonesian:
                return "Kedokteran Keluarga"
            }
        }

        if normalized.contains("doctor consultation") ||
            normalized.contains("醫生診症") ||
            normalized.contains("医生诊症") {
            switch settings.language {
            case .chinese:
                return "醫生診症"
            case .english:
                return "Doctor Consultation"
            case .indonesian:
                return "Konsultasi Dokter"
            }
        }

        if normalized.contains("cardiology") ||
            normalized.contains("心臟") ||
            normalized.contains("心脏") ||
            normalized.contains("kardiologi") {
            switch settings.language {
            case .chinese:
                return "心臟科"
            case .english:
                return "Cardiology"
            case .indonesian:
                return "Kardiologi"
            }
        }

        if normalized.contains("oncology") ||
            normalized.contains("腫瘤") ||
            normalized.contains("肿瘤") ||
            normalized.contains("onkologi") {
            switch settings.language {
            case .chinese:
                return "腫瘤科"
            case .english:
                return "Oncology"
            case .indonesian:
                return "Onkologi"
            }
        }

        if normalized.contains("orthopaedic") ||
            normalized.contains("orthopedic") ||
            normalized.contains("骨科") {
            switch settings.language {
            case .chinese:
                return "骨科"
            case .english:
                return "Orthopaedics"
            case .indonesian:
                return "Ortopedi"
            }
        }

        if normalized.contains("medicine") ||
            normalized.contains("內科") ||
            normalized.contains("内科") {
            switch settings.language {
            case .chinese:
                return "內科"
            case .english:
                return "Medicine"
            case .indonesian:
                return "Penyakit Dalam"
            }
        }

        return original.nilIfBlank
    }

    private func applySelectedCaregiver() {
        guard let selectedCaregiverId,
              let caregiver = scheduleManager.caregivers.first(where: { $0.id == selectedCaregiverId }) else {
            formAssigneeName = ""
            formAssigneeEmail = ""
            formAssigneePhone = ""
            return
        }

        formAssigneeName = caregiver.name
        formAssigneeEmail = caregiver.email
        formAssigneePhone = caregiver.phone
    }
}

// MARK: - Save

extension AppointmentScannerView {
    private func saveReviewedAppointment() {
        let isUnassigned = selectedCaregiverId == nil && formAssigneeName.nilIfBlank == nil

        let resolvedAssignee = formAssigneeName.nilIfBlank
            ?? localizedOrDefault("schedule.unspecifiedAssignee", "Unspecified")

        let resolvedStatus: ShiftStatus = isUnassigned ? .unassigned : .assigned

        let baseShift = Shift(
            assignee: resolvedAssignee,
            start: formStart,
            end: formEnd,
            taskSummary: formTaskSummary.nilIfBlank ?? localizedOrDefault("appointment.review.suggestedTaskSummary", "Appointment"),
            status: resolvedStatus,
            note: formNotes,
            contactEmail: isUnassigned ? "" : formAssigneeEmail,
            contactPhone: isUnassigned ? "" : formAssigneePhone,
            signedIn: false
        )

        let shifts = expandRecurrence(of: baseShift, frequency: formFrequency)

        for shift in shifts {
            scheduleManager.addShift(shift)
        }

        showReviewSheet = false
        dismiss()
    }

    private func expandRecurrence(of baseShift: Shift, frequency: AppointmentRecurrenceFrequency) -> [Shift] {
        guard frequency != .none else {
            return [baseShift]
        }

        let calendar = Calendar.current
        let duration = baseShift.end.timeIntervalSince(baseShift.start)

        let count: Int
        let component: Calendar.Component

        switch frequency {
        case .none:
            return [baseShift]

        case .daily:
            count = 30
            component = .day

        case .monthly:
            count = 11
            component = .month

        case .yearly:
            count = 2
            component = .year
        }

        var result: [Shift] = [baseShift]

        for offset in 1...count {
            guard let newStart = calendar.date(byAdding: component, value: offset, to: baseShift.start) else {
                continue
            }

            let newEnd = newStart.addingTimeInterval(duration)

            let repeatedShift = Shift(
                assignee: baseShift.assignee,
                start: newStart,
                end: newEnd,
                taskSummary: baseShift.taskSummary,
                status: baseShift.status,
                note: baseShift.note,
                contactEmail: baseShift.contactEmail,
                contactPhone: baseShift.contactPhone,
                signedIn: false
            )

            result.append(repeatedShift)
        }

        return result
    }
}

// MARK: - Camera Picker

struct CameraImagePicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()

        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.modalPresentationStyle = .fullScreen
        } else {
            picker.sourceType = .photoLibrary
        }

        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker

        init(parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }

            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - OpenRouter Appointment Vision Service

struct OpenRouterAppointmentVisionService {

    /// Discrete pipeline stages reported to the view so the overlay can
    /// show a meaningful status line (e.g. "Waiting for AI response")
    /// instead of just a spinner.
    enum Stage {
        case preparingImage      // resize + JPEG encode
        case encodingRequest     // base64 + JSON body
        case uploadingToAI       // POST sent, awaiting first byte
        case waitingForAIResult  // request open, waiting for the model
        case parsingResult       // got bytes, decoding JSON
    }

    static func analyzeAppointmentImage(
        image: UIImage,
        apiKey: String,
        progress: @MainActor @escaping (Stage) -> Void = { _ in }
    ) async throws -> AppointmentExtractionResult {
        await progress(.preparingImage)
        let resizedImage = image.resizedForOpenRouter(maxDimension: 1400)

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.78) else {
            throw AppointmentScannerError.imageEncodingFailed
        }

        await progress(.encodingRequest)
        let base64Image = jpegData.base64EncodedString()
        let imageDataURL = "data:image/jpeg;base64,\(base64Image)"

        let requestBody = OpenRouterAppointmentVisionRequest(
            model: "nvidia/nemotron-nano-12b-v2-vl:free",
            messages: [
                OpenRouterAppointmentVisionMessage(
                    role: "user",
                    content: [
                        .text(appointmentImagePrompt),
                        .imageURL(imageDataURL)
                    ]
                )
            ],
            temperature: 0.0
        )

        let jsonData = try JSONEncoder().encode(requestBody)

        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.httpBody = jsonData

        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Appointment Scanner iOS", forHTTPHeaderField: "X-Title")

        // We can't observe the upload vs. waiting transition with
        // URLSession.data(for:) directly, so we report both stages in
        // quick succession around the call — the model "waiting" stage
        // dominates by far, so the user sees that label for almost the
        // entire wait.
        await progress(.uploadingToAI)
        await progress(.waitingForAIResult)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown OpenRouter error"

            throw NSError(
                domain: "OpenRouterError",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: errorText
                ]
            )
        }

        await progress(.parsingResult)
        let decoded = try JSONDecoder().decode(OpenRouterAppointmentVisionResponse.self, from: data)

        guard let content = decoded.choices.first?.message.content?.nilIfBlank else {
            throw AppointmentScannerError.noAppointmentDateFound("No response from OpenRouter model.")
        }

        let extraction = try parseModelJSON(content)

        guard extraction.isAppointmentDateTime else {
            throw AppointmentScannerError.noAppointmentDateFound(extraction.evidence)
        }

        guard let year = extraction.year,
              let month = extraction.month,
              let day = extraction.day,
              let hour24 = extraction.hour24,
              let minute = extraction.minute else {
            throw AppointmentScannerError.noAppointmentDateFound(
                "The model did not return complete date/time fields. Evidence: \(extraction.evidence)"
            )
        }

        let appointmentDate = try AppointmentScannerView.makeDate(
            year: year,
            month: month,
            day: day,
            hour: hour24,
            minute: minute,
            evidence: extraction.evidence
        )

        return AppointmentExtractionResult(
            clinicName: extraction.clinicName?.nilIfBlank,
            caseType: extraction.caseType.appCaseType,
            department: extraction.department?.nilIfBlank,
            address: extraction.address?.nilIfBlank,
            appointmentDate: appointmentDate,
            evidence: """
            AI vision model analyzed the appointment slip image.

            Raw model content:
            \(content)

            Evidence:
            \(extraction.evidence)
            """,
            confidence: max(0, min(1, extraction.confidence)),
            // Default to true when missing — most appointment slips are
            // doctor visits, matching prompt rule 10a.
            isDoctorAppointment: extraction.isDoctorAppointment ?? true
        )
    }

    private static var appointmentImagePrompt: String {
        """
        You are analyzing a photo of a medical appointment slip.

        Your task is to extract only the information needed to add a new care shift in the app.

        Return ONLY valid JSON.
        Do not return markdown.
        Do not wrap the JSON in ```json.
        Do not add explanations outside JSON.

        Required JSON schema:

        {
          "clinicName": string or null,
          "department": string or null,
          "caseType": "followUp" or "newCase" or "unknown",
          "address": string or null,

          "isDoctorAppointment": true or false,

          "year": number or null,
          "month": number or null,
          "day": number or null,

          "hour24": number or null,
          "minute": number or null,

          "registrationHourOriginal": string or null,
          "registrationMinuteOriginal": string or null,
          "registrationMeridiemOriginal": string or null,

          "isAppointmentDateTime": true or false,
          "evidence": string,
          "confidence": number
        }

        Critical rules:

        1. Extract the patient's actual appointment date and registration time.

        2. For Hong Kong Hospital Authority appointment slips, the appointment date may appear as:
           - 2026年10月8日
           - 2026 年 10 月 8 日
           - 08/10/2026
           - A vertical field layout:
             日期
             [Date]
             2026
             [Year]
             年
             10
             [Month]
             月
             8
             [Day]
             日

           This means:
           year = 2026
           month = 10
           day = 8

        3. DD/MM/YYYY means day/month/year.
           Example:
           08/10/2026 means 8 October 2026, not August 10.

        4. The registration time must come from appointment/registration fields, such as:
           - Registration
           - [Registration]
           - 登記時間
           - Hour
           - [Hour]
           - 時
           - Minute
           - [Minute]
           - 分

        5. If the slip has this kind of block:
           [Registration] (PM)
           7
           [Hour]
           15
           [Minute]

           then the registration time is 7:15 PM.
           Return:
           hour24 = 19
           minute = 15
           registrationHourOriginal = "7"
           registrationMinuteOriginal = "15"
           registrationMeridiemOriginal = "PM"

        6. If the slip has:
           下午 7時15分

           then return:
           hour24 = 19
           minute = 15

        7. Never use footer or print timestamps as appointment date/time.
           Ignore:
           - Prt at
           - Printed at
           - Booked from
           - generated
           - created
           - issued
           - updated
           - barcode
           - QR code
           - internal-use timestamps

           Examples to ignore:
           - Prt at 28/05/2026 19:40
           - Printed at 28/05/2026 19:40:13
           - Booked from QMH by CMSOP

        8. If you cannot clearly find appointment date and registration time from the slip,
           set isAppointmentDateTime = false and set missing date/time fields to null.

        9. caseType classification:
           - followUp means follow-up, follow-up case, FU, 覆診, 复诊
           - newCase means new case, new appointment, first visit, 新症, 初診, 初诊
           - unknown means not visible

        10. Department means specialty/clinic/service department, for example:
            Urology, Family Medicine, Cardiology, Oncology, Orthopaedics, Doctor Consultation.
            Always try to identify the SPECIALIST/DEPARTMENT name, even if it
            appears only as a clinic name or a doctor's title (e.g. "Dr Wong,
            Cardiology" → department = "Cardiology"). Return it cleanly,
            without extra punctuation.

        10a. isDoctorAppointment means: is this slip clearly a consultation
             with a medical doctor (general practitioner OR specialist)?
             Return true when the slip mentions any of:
             - 醫生, 醫生診症, 醫生覆診, 醫師, Doctor, Dr., Dr, Physician,
               Consultant, GP, Specialist
             - A clearly clinical specialty (Cardiology, Urology, Oncology,
               Family Medicine, Orthopaedics, Paediatrics, Psychiatry, etc.)
               that implies a doctor visit.
             Return false when the slip is clearly NOT a doctor visit,
             for example a nurse-only dressing change, blood-draw station,
             physiotherapy session, X-ray/imaging only, or pharmacy refill.
             If you genuinely cannot tell, default to true (because most
             appointment slips are doctor visits).

        11. Address means the actual place/address/location printed on the slip.
            It may include:
            - floor
            - room
            - block
            - clinic name
            - hospital name
            - street
            - building
            - clinic location

            Do not invent the address.
            If no address/place is visible, return null.

        12. The app will create the task row as:
            Type, Department, Address

            So return department and address cleanly and concisely.

        13. confidence must be between 0.0 and 1.0.

        14. evidence should briefly explain which visible labels/fields were used,
            and mention if print/footer timestamps were ignored.
        """
    }

    private static func parseModelJSON(_ content: String) throws -> OpenRouterAppointmentExtraction {
        let cleaned = cleanJSONText(content)

        guard let data = cleaned.data(using: .utf8) else {
            throw AppointmentScannerError.noAppointmentDateFound("Could not encode model JSON.")
        }

        do {
            return try JSONDecoder().decode(OpenRouterAppointmentExtraction.self, from: data)
        } catch {
            throw AppointmentScannerError.noAppointmentDateFound(
                """
                Could not parse model JSON.

                Raw response:
                \(content)

                Cleaned response:
                \(cleaned)

                Error:
                \(error.localizedDescription)
                """
            )
        }
    }

    private static func cleanJSONText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst("```json".count))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst("```".count))
        }

        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast("```".count))
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            cleaned = String(cleaned[firstBrace...lastBrace])
        }

        return cleaned
    }
}

// MARK: - OpenRouter Request Models

struct OpenRouterAppointmentVisionRequest: Codable {
    let model: String
    let messages: [OpenRouterAppointmentVisionMessage]
    let temperature: Double?
}

struct OpenRouterAppointmentVisionMessage: Codable {
    let role: String
    let content: [OpenRouterAppointmentContentPart]
}

enum OpenRouterAppointmentContentPart: Codable {
    case text(String)
    case imageURL(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }

    enum ImageUrlKeys: String, CodingKey {
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)

        case .imageURL(let dataURL):
            try container.encode("image_url", forKey: .type)

            var imageContainer = container.nestedContainer(
                keyedBy: ImageUrlKeys.self,
                forKey: .imageUrl
            )

            try imageContainer.encode(dataURL, forKey: .url)
        }
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "OpenRouterAppointmentContentPart is only used for encoding."
            )
        )
    }
}

// MARK: - OpenRouter Response Models

struct OpenRouterAppointmentVisionResponse: Codable {
    let choices: [OpenRouterAppointmentVisionChoice]
}

struct OpenRouterAppointmentVisionChoice: Codable {
    let message: OpenRouterAppointmentAssistantMessage
}

struct OpenRouterAppointmentAssistantMessage: Codable {
    let role: String?
    let content: String?
}

// MARK: - OpenRouter Structured Extraction Model

struct OpenRouterAppointmentExtraction: Codable {
    var clinicName: String?
    var department: String?
    var caseType: OpenRouterAppointmentCaseType
    var address: String?

    /// True if the model believes this slip is a consultation with a doctor
    /// (GP or specialist). Optional so older / partial JSON still decodes;
    /// defaults to `true` further down because most appointment slips are
    /// doctor visits.
    var isDoctorAppointment: Bool?

    var year: Int?
    var month: Int?
    var day: Int?

    var hour24: Int?
    var minute: Int?

    var registrationHourOriginal: String?
    var registrationMinuteOriginal: String?
    var registrationMeridiemOriginal: String?

    var isAppointmentDateTime: Bool
    var evidence: String
    var confidence: Double
}

enum OpenRouterAppointmentCaseType: String, Codable {
    case followUp
    case newCase
    case unknown

    var appCaseType: AppointmentCaseType {
        switch self {
        case .followUp:
            return .followUp
        case .newCase:
            return .newCase
        case .unknown:
            return .unknown
        }
    }
}

// MARK: - Supporting Types

struct AppointmentExtractionResult {
    var clinicName: String?
    var caseType: AppointmentCaseType
    var department: String?
    var address: String?
    var appointmentDate: Date
    var evidence: String
    var confidence: Double
    /// Whether the AI identified this slip as a doctor consultation
    /// (drives the "覆診(醫生)" / "Follow-up (Doctor)" type label).
    var isDoctorAppointment: Bool = true
}

enum AppointmentCaseType: String {
    case followUp
    case newCase
    case unknown
}

enum AppointmentRecurrenceFrequency: CaseIterable {
    case none
    case daily
    case monthly
    case yearly

    func title(settings: AppSettings) -> String {
        switch self {
        case .none:
            let value = settings.localized("schedule.recurrence.none")
            return value == "schedule.recurrence.none"
                ? fallback(settings: settings, zh: "不重複（單次排班）", en: "No repeat (single shift)", id: "Tidak diulang (shift tunggal)")
                : value

        case .daily:
            let value = settings.localized("schedule.recurrence.daily")
            return value == "schedule.recurrence.daily"
                ? fallback(settings: settings, zh: "每天", en: "Daily", id: "Setiap hari")
                : value

        case .monthly:
            let value = settings.localized("schedule.recurrence.monthly")
            return value == "schedule.recurrence.monthly"
                ? fallback(settings: settings, zh: "每月的今天", en: "Monthly on this day", id: "Bulanan pada tanggal ini")
                : value

        case .yearly:
            let value = settings.localized("schedule.recurrence.yearly")
            return value == "schedule.recurrence.yearly"
                ? fallback(settings: settings, zh: "每年每月的今天", en: "Yearly on this date", id: "Tahunan pada tanggal ini")
                : value
        }
    }

    private func fallback(settings: AppSettings, zh: String, en: String, id: String) -> String {
        switch settings.language {
        case .chinese:
            return zh
        case .english:
            return en
        case .indonesian:
            return id
        }
    }
}

enum AppointmentScannerError: LocalizedError {
    case imageEncodingFailed
    case openRouterAPIKeyMissing
    case noAppointmentDateFound(String)
    case invalidDateComponents(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Could not prepare the image for analysis."

        case .openRouterAPIKeyMissing:
            return "OpenRouter API key is missing."

        case .noAppointmentDateFound(let evidence):
            return "Could not confidently find the appointment date/time. \(evidence)"

        case .invalidDateComponents(let evidence):
            return "The appointment date/time looked invalid. \(evidence)"
        }
    }
}

// MARK: - Utility Functions

extension AppointmentScannerView {
    @MainActor
    private func presentError(_ error: Error) {
        alertTitle = localizedOrDefault("health.ocrFailed", "OCR failed")

        if let scannerError = error as? AppointmentScannerError {
            alertMessage = localizedErrorMessage(scannerError)
        } else if let localized = error as? LocalizedError,
                  let message = localized.errorDescription {
            alertMessage = message
        } else {
            alertMessage = error.localizedDescription
        }

        showAlert = true
    }

    private func localizedErrorMessage(_ error: AppointmentScannerError) -> String {
        switch error {
        case .imageEncodingFailed:
            switch settings.language {
            case .chinese:
                return "無法準備圖片進行分析。"
            case .english:
                return "Could not prepare the image for analysis."
            case .indonesian:
                return "Tidak dapat menyiapkan gambar untuk dianalisis."
            }

        case .openRouterAPIKeyMissing:
            switch settings.language {
            case .chinese:
                return "缺少 OpenRouter API key。"
            case .english:
                return "OpenRouter API key is missing."
            case .indonesian:
                return "Kunci API OpenRouter tidak ada."
            }

        case .noAppointmentDateFound(let evidence):
            switch settings.language {
            case .chinese:
                return "未能確認就診日期或登記時間。\(evidence)"
            case .english:
                return "Could not confidently find the appointment date/time. \(evidence)"
            case .indonesian:
                return "Tidak dapat menemukan tanggal/waktu janji temu dengan yakin. \(evidence)"
            }

        case .invalidDateComponents(let evidence):
            switch settings.language {
            case .chinese:
                return "識別到的就診日期或時間無效。\(evidence)"
            case .english:
                return "The appointment date/time looked invalid. \(evidence)"
            case .indonesian:
                return "Tanggal/waktu janji temu yang terdeteksi tidak valid. \(evidence)"
            }
        }
    }

    static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        evidence: String
    ) throws -> Date {
        guard (1900...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            throw AppointmentScannerError.invalidDateComponents(evidence)
        }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let date = components.date else {
            throw AppointmentScannerError.invalidDateComponents(evidence)
        }

        let resolved = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )

        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day,
              resolved.hour == hour,
              resolved.minute == minute else {
            throw AppointmentScannerError.invalidDateComponents(evidence)
        }

        return date
    }
}

// MARK: - UIImage Utilities

extension UIImage {
    func resizedForOpenRouter(maxDimension: CGFloat) -> UIImage {
        let width = size.width
        let height = size.height

        let largestDimension = max(width, height)

        if largestDimension <= maxDimension {
            return self
        }

        let scale = maxDimension / largestDimension
        let newSize = CGSize(
            width: width * scale,
            height: height * scale
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)

        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - String Utilities

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}