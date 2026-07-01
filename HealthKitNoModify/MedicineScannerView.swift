//
//  MedicineScannerView.swift
//
//  Medicine label scanner.
//
//  This version uses direct image-to-OpenRouter vision analysis instead of
//  Vision OCR + Apple Foundation Models.
//
//  Updated fix:
//  - OpenRouter responses are parsed with JSONSerialization instead of a strict
//    Codable response model, preventing:
//      "The data couldn’t be read because it isn’t in the correct format."
//  - Raw OpenRouter responses are included in scanner errors to make debugging easier.
//

import SwiftUI
import UIKit
import PhotosUI
import Foundation
import Combine

// MARK: - Extracted struct passed from AI layer into the View

struct ExtractedMedicineInfo {
    var drugName: String
    var medicationDays: Int
    var frequencyDays: Int
    var timesPerDay: Int
    var firstDoseHour: Int
    var firstDoseMinute: Int

    /// One of: "1", "1/2", or "1/4".
    var tabletPortion: String

    /// Optional extra fields from OpenRouter vision.
    var dosage: String? = nil
    var totalTablets: Double? = nil
    var evidence: String = ""
    var confidence: Double = 0
}

/// Valid tablet-portion picker values.
enum MedicineTabletPortion: String, CaseIterable, Identifiable {
    case full = "1"
    case half = "1/2"
    case quarter = "1/4"

    var id: String { rawValue }

    var numericValue: Double {
        switch self {
        case .full:
            return 1.0
        case .half:
            return 0.5
        case .quarter:
            return 0.25
        }
    }

    func displayLabel(tabletWord: String) -> String {
        "\(rawValue) \(tabletWord)"
    }

    /// Lenient parse — accepts variants like "0.5", "½", "¼", "half",
    /// "quarter", "1.0", numerics, mixed Chinese/English.
    static func parse(_ raw: String) -> MedicineTabletPortion {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if s.contains("1/4") ||
            s.contains("¼") ||
            s.contains("quarter") ||
            s.contains("0.25") ||
            s.contains("四分一") ||
            s.contains("四分之一") {
            return .quarter
        }

        if s.contains("1/2") ||
            s.contains("½") ||
            s.contains("half") ||
            s.contains("0.5") ||
            s.contains("半") {
            return .half
        }

        return .full
    }
}

// MARK: - MedicineScannerView

struct MedicineScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @ObservedObject private var scheduleManager = CareScheduleManager.shared

    @State private var showCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var isProcessing = false
    @State private var processingMessage = ""

    /// Currently-running analysis Task — kept so the user's Abort button
    /// can cancel it mid-flight.
    @State private var analysisTask: Task<Void, Never>?

    /// Seconds the user has been waiting for the AI to respond.
    @State private var processingElapsed: Int = 0

    /// 1 Hz publisher used to bump `processingElapsed` while overlay is visible.
    private let processingTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    @State private var showReviewSheet = false

    // Review form fields - bound to editable controls.
    @State private var formDrugName = ""
    @State private var formTotalTabletsText = ""
    @State private var formMedicationDays = 7
    @State private var formFrequencyDays = 1
    @State private var formTimesPerDay = 1
    @State private var formFirstDoseTime: Date = MedicineScannerView.defaultFirstDoseTime()
    @State private var formTabletPortion: MedicineTabletPortion = .full

    @State private var formCaregiverId: UUID?
    @State private var formAssigneeName = ""
    @State private var formAssigneeEmail = ""
    @State private var formAssigneePhone = ""

    /// Shows the raw AI result / evidence so the user can verify what
    /// the AI was working from.
    @State private var lastOCRText = ""

    // For testing only.
    // Do NOT hardcode API keys in production apps.
    // Prefer calling your own backend instead.
    //
    // Paste your OpenRouter API key here for local testing.
    private let openRouterAPIKey = "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"

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 24) {
                    header

                    VStack(spacing: 16) {
                        Button {
                            showCamera = true
                        } label: {
                            Label(
                                localizedOrDefault("health.takePhoto", "Take photo"),
                                systemImage: "camera.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label(
                                localizedOrDefault("health.choosePhoto", "Choose from library"),
                                systemImage: "photo.on.rectangle"
                            )
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
            .navigationTitle(localizedOrDefault("health.scanMedicine", "Scan medicine"))
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

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "pills.fill")
                .font(.system(size: 52))
                .foregroundStyle(.pink)

            Text(localizedOrDefault("health.scanMedicine", "Scan medicine"))
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
            return "請選擇拍照或從相簿選取整張藥物標籤，系統會自動識別藥名、劑量、藥物數量、服用次數及每次份量。"
        case .english:
            return "Choose camera or photo library. The app will detect the drug name, dosage, quantity, frequency, and portion per dose."
        case .indonesian:
            return "Pilih kamera atau galeri foto. Aplikasi akan mendeteksi nama obat, dosis, jumlah, frekuensi, dan porsi setiap dosis."
        }
    }

    // MARK: Processing overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.25)

                Text(processingMessage.isEmpty ? medicineProcessingText("processing") : processingMessage)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                VStack(spacing: 4) {
                    Text(elapsedStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(stageHintLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(role: .destructive) {
                    abortAnalysis()
                } label: {
                    Label(localizedAbortLabel, systemImage: "xmark.circle.fill")
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

    // MARK: Review sheet

    private var reviewSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        localizedOrDefault("medicine.review.drugNamePlaceholder", "Drug name"),
                        text: $formDrugName
                    )
                } header: {
                    Text(localizedOrDefault("medicine.review.drugNameLabel", "Drug name"))
                }

                Section {
                    TextField(
                        localizedOrDefault("medicine.review.totalTabletsLabel", "Total tablets / capsules on label"),
                        text: $formTotalTabletsText
                    )
                    .keyboardType(.decimalPad)
                    .onChange(of: formTotalTabletsText) { _, _ in
                        recalculateMedicationDaysFromQuantity()
                    }

                    Stepper(value: $formMedicationDays, in: 1...365) {
                        HStack {
                            Text(localizedOrDefault("medicine.review.medicationDaysLabel", "Medicine can last days"))
                            Spacer()
                            Text("\(formMedicationDays)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: $formFrequencyDays, in: 1...30) {
                        HStack {
                            Text(localizedOrDefault("medicine.review.frequencyDaysLabel", "Every N days"))
                            Spacer()
                            Text("\(formFrequencyDays)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: formFrequencyDays) { _, _ in
                        recalculateMedicationDaysFromQuantity()
                    }

                    Stepper(value: $formTimesPerDay, in: 1...12) {
                        HStack {
                            Text(localizedOrDefault("medicine.review.timesPerDayLabel", "Times per day"))
                            Spacer()
                            Text("\(formTimesPerDay)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: formTimesPerDay) { _, _ in
                        recalculateMedicationDaysFromQuantity()
                    }

                    DatePicker(
                        localizedOrDefault("medicine.review.firstDoseTimeLabel", "First dose time"),
                        selection: $formFirstDoseTime,
                        displayedComponents: [.hourAndMinute]
                    )

                    Picker(
                        localizedOrDefault("medicine.review.tabletPortionLabel", "Per dose"),
                        selection: $formTabletPortion
                    ) {
                        ForEach(MedicineTabletPortion.allCases) { portion in
                            Text(
                                portion.displayLabel(
                                    tabletWord: localizedOrDefault("medicine.review.tabletWord", "tablet")
                                )
                            )
                            .tag(portion)
                        }
                    }
                    .onChange(of: formTabletPortion) { _, _ in
                        recalculateMedicationDaysFromQuantity()
                    }

                    Text(medicineLastsCalculationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker(
                        localizedOrDefault("health.selectCaregiver", "Select caregiver"),
                        selection: $formCaregiverId
                    ) {
                        Text("—").tag(UUID?.none)

                        ForEach(scheduleManager.caregivers) { caregiver in
                            Text(caregiver.name).tag(Optional(caregiver.id))
                        }
                    }
                    .onChange(of: formCaregiverId) { _, _ in
                        applySelectedCaregiver()
                    }
                } header: {
                    Text(localizedOrDefault("health.selectCaregiver", "Select caregiver"))
                }

                Section {
                    let preview = previewSchedule()
                    let summary = String(
                        format: localizedOrDefault(
                            "medicine.review.previewSummary",
                            "%d reminders. First: %@"
                        ),
                        preview.count,
                        preview.first.map { formatDate($0) } ?? "—"
                    )

                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(Array(preview.prefix(6).enumerated()), id: \.offset) { _, date in
                        Text(formatDate(date))
                            .font(.footnote)
                    }

                    if preview.count > 6 {
                        Text("… +\(preview.count - 6)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(localizedOrDefault("medicine.review.previewSection", "Preview"))
                }

                if !lastOCRText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        ScrollView {
                            Text(lastOCRText)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    } header: {
                        Text(localizedOrDefault("medicine.review.ocrSection", "AI Analysis Result"))
                    }
                }
            }
            .navigationTitle(localizedOrDefault("medicine.review.title", "Confirm medicine details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedOrDefault("medicine.review.cancel", "Cancel")) {
                        showReviewSheet = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(localizedOrDefault("medicine.review.saveToCalendar", "Save to calendar")) {
                        saveReviewedMedicine()
                    }
                    .disabled(formDrugName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Quantity calculation display

    private var parsedTotalTablets: Double? {
        let raw = formTotalTabletsText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")

        return Double(raw)
    }

    private var medicineLastsCalculationText: String {
        guard let total = parsedTotalTablets, total > 0 else {
            switch settings.language {
            case .chinese:
                return "未能讀取藥物總數，請手動確認可服用日數。"
            case .english:
                return "Total tablet count not found. Please confirm how many days it can last."
            case .indonesian:
                return "Jumlah tablet tidak ditemukan. Harap konfirmasi berapa hari obat dapat digunakan."
            }
        }

        let tabletsPerDosingDay = Double(max(1, formTimesPerDay)) * formTabletPortion.numericValue

        guard tabletsPerDosingDay > 0 else {
            return ""
        }

        let dosingDays = Int(floor(total / tabletsPerDosingDay))
        let calendarDays = max(1, dosingDays * max(1, formFrequencyDays))

        switch settings.language {
        case .chinese:
            return "計算：\(formatNumber(total)) 粒 ÷ 每個服藥日 \(formatNumber(tabletsPerDosingDay)) 粒，約可服用 \(calendarDays) 日。"
        case .english:
            return "Calculation: \(formatNumber(total)) tablets ÷ \(formatNumber(tabletsPerDosingDay)) tablets per dosing day = about \(calendarDays) calendar days."
        case .indonesian:
            return "Perhitungan: \(formatNumber(total)) tablet ÷ \(formatNumber(tabletsPerDosingDay)) tablet per hari dosis = sekitar \(calendarDays) hari kalender."
        }
    }

    private func recalculateMedicationDaysFromQuantity() {
        guard let total = parsedTotalTablets, total > 0 else {
            return
        }

        let tabletsPerDosingDay = Double(max(1, formTimesPerDay)) * formTabletPortion.numericValue

        guard tabletsPerDosingDay > 0 else {
            return
        }

        let dosingDays = Int(floor(total / tabletsPerDosingDay))
        let calendarDays = dosingDays * max(1, formFrequencyDays)

        formMedicationDays = max(1, min(365, calendarDays))
    }

    // MARK: Photo picker handler

    @MainActor
    private func loadPhotoPickerItem(_ item: PhotosPickerItem) async {
        do {
            beginProcessing(message: medicineProcessingText("loading"))

            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw MedicineScannerError.imageEncodingFailed
            }

            endProcessing()
            startAnalysisTask(for: image)

        } catch {
            endProcessing()
            presentMedicineError(error)
        }

        selectedPhotoItem = nil
    }

    // MARK: OpenRouter image analysis flow

    @MainActor
    private func startAnalysisTask(for image: UIImage) {
        analysisTask?.cancel()

        analysisTask = Task { @MainActor in
            await analyzeMedicineLabel(image)
            analysisTask = nil
        }
    }

    @MainActor
    private func analyzeMedicineLabel(_ image: UIImage) async {
        beginProcessing(message: medicineStageLabel(for: .preparingImage))

        do {
            let result = try await OpenRouterMedicineVisionService.analyzeMedicineImage(
                image: image,
                apiKey: openRouterAPIKey,
                progress: { stage in
                    self.processingMessage = self.medicineStageLabel(for: stage)
                }
            )

            if Task.isCancelled {
                endProcessing()
                return
            }

            lastOCRText = result.evidence
            populateForm(from: result)

            endProcessing()
            showReviewSheet = true

        } catch is CancellationError {
            endProcessing()

        } catch {
            let nsError = error as NSError

            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                endProcessing()
                return
            }

            endProcessing()
            presentMedicineError(error)
        }
    }

    // MARK: Processing-state helpers

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

    @MainActor
    private func abortAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        endProcessing()
    }

    // MARK: Medicine-only status / localized text

    private func medicineProcessingText(_ key: String) -> String {
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

        default:
            switch settings.language {
            case .chinese:
                return "正在分析藥物標籤…"
            case .english:
                return "Analyzing medicine label…"
            case .indonesian:
                return "Menganalisis label obat…"
            }
        }
    }

    private func medicineStageLabel(for stage: OpenRouterMedicineVisionService.Stage) -> String {
        switch (stage, settings.language) {
        case (.preparingImage, .chinese):
            return "狀態：正在準備藥物標籤圖片…"
        case (.preparingImage, .english):
            return "Status: Preparing medicine label image…"
        case (.preparingImage, .indonesian):
            return "Status: Menyiapkan gambar label obat…"

        case (.encodingRequest, .chinese):
            return "狀態：正在編碼圖片資料…"
        case (.encodingRequest, .english):
            return "Status: Encoding image request…"
        case (.encodingRequest, .indonesian):
            return "Status: Mengkodekan permintaan gambar…"

        case (.uploadingToAI, .chinese):
            return "狀態：正在上傳藥物標籤到 AI…"
        case (.uploadingToAI, .english):
            return "Status: Uploading medicine label to AI…"
        case (.uploadingToAI, .indonesian):
            return "Status: Mengunggah label obat ke AI…"

        case (.waitingForAIResult, .chinese):
            return "狀態：正在等待 AI 識別藥物資料…"
        case (.waitingForAIResult, .english):
            return "Status: Waiting for AI to read medicine details…"
        case (.waitingForAIResult, .indonesian):
            return "Status: Menunggu AI membaca detail obat…"

        case (.parsingResult, .chinese):
            return "狀態：正在解析藥物資料…"
        case (.parsingResult, .english):
            return "Status: Parsing medicine result…"
        case (.parsingResult, .indonesian):
            return "Status: Mengurai hasil obat…"
        }
    }

    // MARK: Populate review form

    private func populateForm(from info: ExtractedMedicineInfo) {
        formDrugName = info.drugName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let total = info.totalTablets, total > 0 {
            formTotalTabletsText = formatNumber(total)
        } else {
            formTotalTabletsText = ""
        }

        formFrequencyDays = max(1, min(30, info.frequencyDays))
        formTimesPerDay = max(1, min(12, info.timesPerDay))
        formFirstDoseTime = todayAt(
            hour: info.firstDoseHour,
            minute: info.firstDoseMinute
        )
        formTabletPortion = MedicineTabletPortion.parse(info.tabletPortion)

        if let total = info.totalTablets, total > 0 {
            let tabletsPerDosingDay = Double(formTimesPerDay) * formTabletPortion.numericValue
            if tabletsPerDosingDay > 0 {
                let dosingDays = Int(floor(total / tabletsPerDosingDay))
                let calendarDays = dosingDays * formFrequencyDays
                formMedicationDays = max(1, min(365, calendarDays))
            } else {
                formMedicationDays = max(1, min(365, info.medicationDays))
            }
        } else {
            formMedicationDays = max(1, min(365, info.medicationDays))
        }
    }

    // MARK: Schedule expansion - one Shift per dose

    /// Compute the full list of dose times for the current form values.
    /// First dose anchors to today at the chosen hour:minute. Each dosing day
    /// spreads `timesPerDay` doses across 12 hours starting at the first-dose time.
    /// Dosing days repeat every `frequencyDays` days until `medicationDays`
    /// total calendar course days have elapsed.
    private func previewSchedule() -> [Date] {
        let calendar = Calendar.current
        let firstDose = formFirstDoseTime

        // Per-day dose offsets in seconds, evenly spread over 12 hours.
        let perDay = max(1, formTimesPerDay)
        let spreadHours: Double = 12

        let offsets: [TimeInterval]
        if perDay == 1 {
            offsets = [0]
        } else {
            let step = (spreadHours * 3600) / Double(perDay - 1)
            offsets = (0..<perDay).map { Double($0) * step }
        }

        // Build dosing-day start dates.
        let totalDays = max(1, formMedicationDays)
        let interval = max(1, formFrequencyDays)

        var dosingDays: [Date] = []
        var elapsed = 0
        var dayIndex = 0

        while elapsed < totalDays {
            if let d = calendar.date(
                byAdding: .day,
                value: dayIndex * interval,
                to: firstDose
            ) {
                dosingDays.append(d)
            }

            elapsed += interval
            dayIndex += 1
        }

        return dosingDays.flatMap { base in
            offsets.map { base.addingTimeInterval($0) }
        }
    }

    // MARK: Caregiver selection

    private func applySelectedCaregiver() {
        guard let formCaregiverId,
              let caregiver = scheduleManager.caregivers
                .first(where: { $0.id == formCaregiverId }) else {
            formAssigneeName = ""
            formAssigneeEmail = ""
            formAssigneePhone = ""
            return
        }

        formAssigneeName = caregiver.name
        formAssigneeEmail = caregiver.email
        formAssigneePhone = caregiver.phone
    }

    // MARK: Save - one Shift per dose

    private func saveReviewedMedicine() {
        let trimmedName = formDrugName.trimmingCharacters(in: .whitespacesAndNewlines)

        let taskSummary = trimmedName.isEmpty
            ? localizedOrDefault("medicine.review.suggestedTaskSummary", "Take medicine")
            : "\(localizedOrDefault("medicine.review.suggestedTaskSummary", "Take medicine")) — \(trimmedName)"

        let perDoseText = String(
            format: localizedOrDefault("medicine.review.perDoseTemplate", "%@ per dose"),
            formTabletPortion.displayLabel(
                tabletWord: localizedOrDefault("medicine.review.tabletWord", "tablet")
            )
        )

        let quantityText: String
        if let total = parsedTotalTablets, total > 0 {
            quantityText = " — Total: \(formatNumber(total))"
        } else {
            quantityText = ""
        }

        let calendarNote = trimmedName.isEmpty
            ? "\(perDoseText)\(quantityText)"
            : "\(trimmedName) — \(perDoseText)\(quantityText)"

        let isUnassigned = formCaregiverId == nil &&
            formAssigneeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let resolvedAssignee: String
        if isUnassigned {
            resolvedAssignee = localizedOrDefault("schedule.unspecifiedAssignee", "Unspecified")
        } else if !formAssigneeName.isEmpty {
            resolvedAssignee = formAssigneeName
        } else {
            resolvedAssignee = localizedOrDefault("schedule.unspecifiedAssignee", "Unspecified")
        }

        let resolvedStatus: ShiftStatus = isUnassigned ? .unassigned : .assigned

        // Each dose becomes a 15-minute Shift.
        for doseTime in previewSchedule() {
            let end = doseTime.addingTimeInterval(15 * 60)

            let shift = Shift(
                assignee: resolvedAssignee,
                start: doseTime,
                end: end,
                taskSummary: taskSummary,
                status: resolvedStatus,
                note: calendarNote,
                contactEmail: isUnassigned ? "" : formAssigneeEmail,
                contactPhone: isUnassigned ? "" : formAssigneePhone,
                signedIn: false
            )

            scheduleManager.addShift(shift)
        }

        showReviewSheet = false
        dismiss()
    }

    // MARK: Error handling

    @MainActor
    private func presentMedicineError(_ error: Error) {
        alertTitle = localizedOrDefault("health.ocrFailed", "Analysis failed")

        if let scannerError = error as? MedicineScannerError {
            alertMessage = localizedErrorMessage(scannerError)
        } else if let localized = error as? LocalizedError,
                  let message = localized.errorDescription {
            alertMessage = message
        } else {
            alertMessage = error.localizedDescription
        }

        showAlert = true
    }

    private func localizedErrorMessage(_ error: MedicineScannerError) -> String {
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

        case .noMedicineFound(let evidence):
            switch settings.language {
            case .chinese:
                return "未能確認藥物標籤內容。\(evidence)"
            case .english:
                return "Could not confidently read the medicine label. \(evidence)"
            case .indonesian:
                return "Tidak dapat membaca label obat dengan yakin. \(evidence)"
            }
        }
    }

    // MARK: Misc helpers

    private func localizedOrDefault(_ key: String, _ fallback: String) -> String {
        let value = settings.localized(key)
        return value == key ? fallback : value
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func todayAt(hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = max(0, min(23, hour))
        comps.minute = max(0, min(59, minute))
        return cal.date(from: comps) ?? Date()
    }

    private static func defaultFirstDoseTime() -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 9
        comps.minute = 0
        return cal.date(from: comps) ?? Date()
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.2f", value)
    }
}

// MARK: - OpenRouter Medicine Vision Service

struct OpenRouterMedicineVisionService {

    /// Discrete pipeline stages reported to the view so the overlay can
    /// show a meaningful status line.
    enum Stage {
        case preparingImage
        case encodingRequest
        case uploadingToAI
        case waitingForAIResult
        case parsingResult
    }

    static func analyzeMedicineImage(
        image: UIImage,
        apiKey: String,
        progress: @MainActor @escaping (Stage) -> Void = { _ in }
    ) async throws -> ExtractedMedicineInfo {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey != "YOUR_OPENROUTER_API_KEY_HERE" else {
            throw MedicineScannerError.openRouterAPIKeyMissing
        }

        await progress(.preparingImage)

        let resizedImage = image.resizedForOpenRouter(maxDimension: 1400)

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.78) else {
            throw MedicineScannerError.imageEncodingFailed
        }

        await progress(.encodingRequest)

        let base64Image = jpegData.base64EncodedString()
        let imageDataURL = "data:image/jpeg;base64,\(base64Image)"

        let requestBody = OpenRouterMedicineVisionRequest(
            model: "nvidia/nemotron-nano-12b-v2-vl:free",
            messages: [
                OpenRouterMedicineVisionMessage(
                    role: "user",
                    content: [
                        .text(medicineImagePrompt),
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
        request.setValue("Medicine Scanner iOS", forHTTPHeaderField: "X-Title")

        await progress(.uploadingToAI)
        await progress(.waitingForAIResult)

        let (data, response) = try await URLSession.shared.data(for: request)

        let rawResponse = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            throw NSError(
                domain: "OpenRouterMedicineError",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: """
                    OpenRouter HTTP \(httpResponse.statusCode)

                    Raw response:
                    \(rawResponse)
                    """
                ]
            )
        }

        await progress(.parsingResult)

        let content = try extractAssistantContentFromOpenRouterResponse(data)

        guard let content = content.nilIfBlank else {
            throw MedicineScannerError.noMedicineFound(
                """
                No readable response from OpenRouter medicine model.

                Raw OpenRouter response:
                \(rawResponse)
                """
            )
        }

        let extraction = try parseModelJSON(content)

        guard extraction.isMedicineLabel else {
            throw MedicineScannerError.noMedicineFound(
                "The image was not identified as a medicine label. Evidence: \(extraction.evidence)"
            )
        }

        let rawDrugName = extraction.drugName?.nilIfBlank ?? ""

        guard !rawDrugName.isEmpty else {
            throw MedicineScannerError.noMedicineFound(
                "The medicine name was not found. Evidence: \(extraction.evidence)"
            )
        }

        let portion = MedicineTabletPortion.parse(extraction.tabletPortion ?? "1")

        let frequencyDays = max(1, min(30, extraction.frequencyDays ?? 1))
        let timesPerDay = max(1, min(12, extraction.timesPerDay ?? 1))

        let fallbackDays = max(1, min(365, extraction.medicationDays ?? 7))

        let calculatedDays: Int
        if let totalTablets = extraction.totalTablets,
           totalTablets > 0 {
            let tabletsPerDosingDay = Double(timesPerDay) * portion.numericValue

            if tabletsPerDosingDay > 0 {
                let dosingDays = Int(floor(totalTablets / tabletsPerDosingDay))
                calculatedDays = max(1, min(365, dosingDays * frequencyDays))
            } else {
                calculatedDays = fallbackDays
            }
        } else {
            calculatedDays = fallbackDays
        }

        let firstDoseHour = extraction.firstDoseHour ?? 9
        let firstDoseMinute = extraction.firstDoseMinute ?? 0

        let finalDrugName: String
        if let dosage = extraction.dosage?.nilIfBlank,
           !rawDrugName.localizedCaseInsensitiveContains(dosage) {
            finalDrugName = "\(rawDrugName) \(dosage)"
        } else {
            finalDrugName = rawDrugName
        }

        return ExtractedMedicineInfo(
            drugName: finalDrugName,
            medicationDays: calculatedDays,
            frequencyDays: frequencyDays,
            timesPerDay: timesPerDay,
            firstDoseHour: (0...23).contains(firstDoseHour) ? firstDoseHour : 9,
            firstDoseMinute: (0...59).contains(firstDoseMinute) ? firstDoseMinute : 0,
            tabletPortion: portion.rawValue,
            dosage: extraction.dosage?.nilIfBlank,
            totalTablets: extraction.totalTablets,
            evidence: """
            AI vision model analyzed the medicine label image.

            Raw model content:
            \(content)

            Evidence:
            \(extraction.evidence)

            Parsed fields:
            drugName = \(finalDrugName)
            dosage = \(extraction.dosage?.nilIfBlank ?? "nil")
            totalTablets = \(extraction.totalTablets.map { "\($0)" } ?? "nil")
            totalTabletsOriginal = \(extraction.totalTabletsOriginal?.nilIfBlank ?? "nil")
            directionsOriginal = \(extraction.directionsOriginal?.nilIfBlank ?? "nil")
            frequencyDays = \(frequencyDays)
            timesPerDay = \(timesPerDay)
            tabletPortion = \(portion.rawValue)
            medicationDays = \(calculatedDays)
            confidence = \(max(0, min(1, extraction.confidence)))

            Full OpenRouter response:
            \(rawResponse)
            """,
            confidence: max(0, min(1, extraction.confidence))
        )
    }

    // MARK: Robust OpenRouter response parsing

    private static func extractAssistantContentFromOpenRouterResponse(_ data: Data) throws -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"

        do {
            let any = try JSONSerialization.jsonObject(with: data, options: [])

            guard let root = any as? [String: Any] else {
                throw MedicineScannerError.noMedicineFound(
                    """
                    OpenRouter response root was not a JSON object.

                    Raw response:
                    \(raw)
                    """
                )
            }

            if let error = root["error"] {
                throw MedicineScannerError.noMedicineFound(
                    """
                    OpenRouter returned an error:

                    \(error)

                    Raw response:
                    \(raw)
                    """
                )
            }

            guard let choices = root["choices"] as? [[String: Any]],
                  let firstChoice = choices.first else {
                throw MedicineScannerError.noMedicineFound(
                    """
                    OpenRouter response did not contain choices[0].

                    Raw response:
                    \(raw)
                    """
                )
            }

            guard let message = firstChoice["message"] as? [String: Any] else {
                throw MedicineScannerError.noMedicineFound(
                    """
                    OpenRouter response did not contain choices[0].message.

                    Raw response:
                    \(raw)
                    """
                )
            }

            let contentValue = message["content"]

            if let stringContent = contentValue as? String {
                return stringContent
            }

            if let arrayContent = contentValue as? [[String: Any]] {
                let parts = arrayContent.compactMap { part -> String? in
                    if let text = part["text"] as? String {
                        return text
                    }

                    if let type = part["type"] as? String,
                       type == "text",
                       let text = part["content"] as? String {
                        return text
                    }

                    return nil
                }

                let joined = parts.joined(separator: "\n")

                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return joined
                }
            }

            if let objectContent = contentValue as? [String: Any] {
                if let text = objectContent["text"] as? String {
                    return text
                }

                if let content = objectContent["content"] as? String {
                    return content
                }
            }

            throw MedicineScannerError.noMedicineFound(
                """
                OpenRouter message.content was not a readable string.

                Raw response:
                \(raw)
                """
            )

        } catch let scannerError as MedicineScannerError {
            throw scannerError
        } catch {
            throw MedicineScannerError.noMedicineFound(
                """
                Could not parse OpenRouter response JSON.

                Error:
                \(error.localizedDescription)

                Raw response:
                \(raw)
                """
            )
        }
    }

    // MARK: Prompt

    private static var medicineImagePrompt: String {
        """
        You are analyzing a photo of a MEDICINE LABEL or PHARMACY DISPENSING BAG.

        This is NOT an appointment slip.
        Do NOT look for doctor appointment information.
        Do NOT look for clinic appointment dates.
        Do NOT look for registration time.
        Do NOT classify doctor appointment type.

        Your task is ONLY to extract medicine reminder fields.

        Return ONLY valid JSON.
        Do not return markdown.
        Do not wrap the JSON in ```json.
        Do not add explanations outside JSON.

        Required JSON schema:

        {
          "isMedicineLabel": true or false,

          "drugName": string or null,
          "dosage": string or null,

          "totalTablets": number or null,
          "totalTabletsOriginal": string or null,

          "medicationDays": number or null,

          "frequencyDays": number or null,
          "timesPerDay": number or null,

          "firstDoseHour": number or null,
          "firstDoseMinute": number or null,

          "tabletPortion": "1" or "1/2" or "1/4",

          "directionsOriginal": string or null,
          "evidence": string,
          "confidence": number
        }

        Field meanings:

        1. isMedicineLabel:
           true if this image is a medicine label, drug label, pharmacy
           dispensing bag, or prescription medicine instruction label.
           false only if it is clearly not medicine-related.

        2. drugName:
           Full drug / medicine name AS PRINTED on the label.
           Include salt form, formulation, and strength if shown.
           The active drug name may span multiple consecutive lines.
           Join the lines.

           Examples:
           AMLODIPINE
           (BESYLATE) TABLET 5MG

           drugName = "Amlodipine (Besylate) Tablet 5mg"
           dosage = "5mg"

           AMOXICILLIN
           CAPSULE 250MG

           drugName = "Amoxicillin Capsule 250mg"
           dosage = "250mg"

           PARACETAMOL TAB 500MG

           drugName = "Paracetamol Tab 500mg"
           dosage = "500mg"

           Skip patient name, pharmacy name, dates, footer text, phone numbers,
           barcode numbers, and short stock codes.

        3. dosage:
           Drug strength only, such as:
           "5mg", "250mg", "500mg", "10mg/ml", "5ml".

           Correct common OCR errors:
           "SMG" or "5MQ" means "5mg".
           "lMG" or "IMG" means "1mg".
           "OMG" means "0mg".

        4. totalTablets:
           Extract the total dispensed quantity.

           IMPORTANT:
           Many Hong Kong medicine labels show the quantity at the TOP RIGHT,
           for example:
           "28 TAB"
           "14 TAB"
           "7 TAB"
           "30 TABLET"
           "10 CAP"
           "20 CAPSULE"

           If you see "xx TAB" at the top right, return xx as totalTablets.

           Also accept:
           "Qty: 28"
           "Quantity 28"
           "數量 28"
           "共 28 粒"
           "28 粒"
           "28 片"

           Do NOT confuse dosage strength with total quantity:
           "5MG" is dosage, not quantity.
           "500MG" is dosage, not quantity.

        5. medicationDays:
           Total course length in days if explicitly printed.
           Examples:
           "Take for 7 days" -> 7
           "服食7日" -> 7
           "療程7天" -> 7
           "服用5日" -> 5
           "For 14 days" -> 14
           "Selama 10 hari" -> 10

           If there is no explicit course length, return null.
           The app will calculate it from totalTablets.
           If both totalTablets and explicit course length are missing,
           the app will default to 7.

        6. frequencyDays:
           Interval in days between dosing days.
           every day / daily / 每日 / 每天 = 1
           every other day / alternate days / 隔日 = 2
           Default to 1 if unspecified.

        7. timesPerDay:
           Number of times to take medicine per dosing day.

           once daily / once a day / OD / QD / 每日1次 = 1
           twice daily / BID / BD / 每日2次 / 一日2回 = 2
           three times daily / TID / 每日3次 / 一日3回 = 3
           four times daily / QID / 每日4次 = 4

           Indonesian:
           "sehari 1 kali" = 1
           "sehari 2 kali" = 2
           "2 kali sehari" = 2
           "3 kali sehari" = 3

           Default to 1 if unspecified.

        8. firstDoseHour and firstDoseMinute:
           If an exact first dose time is visible, return it in 24-hour clock.

           If only meal/time-of-day wording is shown:
           morning / before breakfast / with breakfast / 早上 / 早餐 = 9:00
           lunch / noon / 午餐 = 13:00
           evening / dinner / 晚餐 = 18:00
           bedtime / before bed / 睡前 = 22:00

           If no time is printed:
           firstDoseHour = 9
           firstDoseMinute = 0

        9. tabletPortion:
           Return EXACTLY one of:
           "1", "1/2", "1/4"

           "Take 1 tablet", "每次1粒", "每次一粒", "每次1片" = "1"

           "half tablet", "1/2 tablet", "½ tablet", "0.5 tablet",
           "每次半粒", "半粒", "半片" = "1/2"

           "quarter tablet", "1/4 tablet", "¼ tablet", "0.25 tablet",
           "每次1/4粒", "四分一粒", "四分之一片" = "1/4"

           CRITICAL:
           If the Chinese character "半" appears near "粒", "片", "顆", or "錠",
           tabletPortion MUST be "1/2", never "1".

           Default to "1" only if no portion is visible.

        10. The app will calculate how many days the medicine can last:
            totalTablets / (timesPerDay * tabletPortion)

            Example:
            totalTablets = 14
            timesPerDay = 2
            tabletPortion = "1/2"
            tablets used per dosing day = 1
            medicine can last 14 dosing days.

        11. evidence:
            Briefly state the visible medicine label fields used:
            medicine name, dosage, quantity, directions, per-dose amount.

        12. confidence:
            Number between 0.0 and 1.0.
        """
    }

    // MARK: Model JSON parsing

    private static func parseModelJSON(_ content: String) throws -> OpenRouterMedicineExtraction {
        let cleaned = cleanJSONText(content)

        guard let data = cleaned.data(using: .utf8) else {
            throw MedicineScannerError.noMedicineFound("Could not encode model JSON.")
        }

        do {
            return try JSONDecoder().decode(OpenRouterMedicineExtraction.self, from: data)
        } catch {
            throw MedicineScannerError.noMedicineFound(
                """
                Could not parse model JSON.

                Raw model response:
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

// MARK: - OpenRouter Medicine Request Models

struct OpenRouterMedicineVisionRequest: Codable {
    let model: String
    let messages: [OpenRouterMedicineVisionMessage]
    let temperature: Double?
}

struct OpenRouterMedicineVisionMessage: Codable {
    let role: String
    let content: [OpenRouterMedicineContentPart]
}

enum OpenRouterMedicineContentPart: Codable {
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
                debugDescription: "OpenRouterMedicineContentPart is only used for encoding."
            )
        )
    }
}

// MARK: - OpenRouter Medicine Structured Extraction Model

struct OpenRouterMedicineExtraction: Codable {
    var isMedicineLabel: Bool

    var drugName: String?
    var dosage: String?

    var totalTablets: Double?
    var totalTabletsOriginal: String?

    var medicationDays: Int?

    var frequencyDays: Int?
    var timesPerDay: Int?

    var firstDoseHour: Int?
    var firstDoseMinute: Int?

    var tabletPortion: String?

    var directionsOriginal: String?
    var evidence: String
    var confidence: Double
}

// MARK: - Medicine Scanner Error

enum MedicineScannerError: LocalizedError {
    case imageEncodingFailed
    case openRouterAPIKeyMissing
    case noMedicineFound(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Could not prepare the image for analysis."

        case .openRouterAPIKeyMissing:
            return "OpenRouter API key is missing."

        case .noMedicineFound(let evidence):
            return "Could not confidently read the medicine label. \(evidence)"
        }
    }
}