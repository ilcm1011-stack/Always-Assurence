import SwiftUI
import HealthKit

struct PatientProfileView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var manager = HealthKitManager.shared

    @State private var isEditingProfile = false
    @State private var draftPatientName = ""
    @State private var draftPatientAge = 72
    @State private var draftPatientGenderKey = "home.gender.female"
    @State private var draftPatientNotes = ""
    @ObservedObject private var scheduleManager = CareScheduleManager.shared
    @State private var isAddingCaregiver = false
    @State private var editingCaregiver: Caregiver?
    @State private var newCaregiverName = ""
    @State private var newCaregiverEmail = ""
    @State private var newCaregiverPhone = ""
    @State private var newCaregiverIcon: String = ""
    @State private var showIconPicker: Bool = false
    @State private var caregiverAvailability: [CareWindow] = []

    @State private var latestChartTemperature: Double?
    @State private var latestChartSpo2: Double?
    @State private var latestChartSystolic: Double?
    @State private var latestChartDiastolic: Double?

    private let genderOptions = ["home.gender.female", "home.gender.male", "home.gender.other"]

    /// When true (e.g. when launched from the home-screen "Caregivers"
    /// tile), the Add-Caregiver sheet opens automatically as soon as the
    /// view appears. Defaults to false so the existing entry point
    /// (direct navigation from anywhere else) still lands on the profile
    /// itself.
    private let openAddCaregiverOnAppear: Bool

    init(openAddCaregiverOnAppear: Bool = false) {
        self.openAddCaregiverOnAppear = openAddCaregiverOnAppear
    }

    var body: some View {
        AlwaysVisibleScrollView {
            VStack(spacing: 24) {
                profileCard
                careWindowCard
                caregiverSection

                if let anomaly = manager.anomalyMessage {
                    anomalyBanner(message: anomaly)
                }

                healthSummaryCard
                recordChartsSection
            }
            .padding()
        }
        .navigationTitle(settings.localized("home.patientDashboard"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Honor the deep-link from the home screen caregivers tile.
            if openAddCaregiverOnAppear && !isAddingCaregiver {
                // Reset draft fields so the sheet opens clean.
                newCaregiverName = ""
                newCaregiverEmail = ""
                newCaregiverPhone = ""
                newCaregiverIcon = ""
                caregiverAvailability = []
                // Tiny delay so the navigation push animation completes
                // before the sheet animates in (avoids a visual stutter
                // on iOS 17).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isAddingCaregiver = true
                }
            }
        }
        .sheet(isPresented: $isEditingProfile) {
            NavigationStack {
                Form {
                    Section(header: Text(settings.localized("home.profileTitle"))) {
                        TextField(settings.localized("home.patientName"), text: $draftPatientName)
                        Stepper(value: $draftPatientAge, in: 0...120) {
                            Text("\(settings.localized("home.patientAge")): \(draftPatientAge)")
                        }
                        Picker(settings.localized("home.patientGender"), selection: $draftPatientGenderKey) {
                            ForEach(genderOptions, id: \.self) { genderKey in
                                Text(settings.localized(genderKey)).tag(genderKey)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.localized("home.patientNotes"))
                                .font(settings.scaledFont(14, weight: .semibold))
                                .foregroundColor(.secondary)
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $draftPatientNotes)
                                    .font(settings.scaledFont(16))
                                    .frame(minHeight: 100)
                                    .padding(4)
                                    .background(Color(.systemBackground))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(.separator), lineWidth: 1)
                                    )
                                if draftPatientNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(settings.localized("home.patientNotesPlaceholder"))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 14)
                                }
                            }
                        }
                    }
                }
                .navigationTitle(settings.localized("home.edit"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(settings.localized("home.cancel")) {
                            isEditingProfile = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(settings.localized("home.save")) {
                            saveProfile()
                            isEditingProfile = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingCaregiver) {
            NavigationStack {
                Form {
                    Section(header: Text(settings.localized("home.addCaregiver"))) {
                        TextField(settings.localized("home.caregiverName"), text: $newCaregiverName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.emailPlaceholder"), text: $newCaregiverEmail)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.phonePlaceholder"), text: $newCaregiverPhone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        caregiverIconRow
                    }

                    Section(header: Text(settings.localized("home.caregiverAvailability"))) {
                        ForEach(caregiverAvailability.indices, id: \.self) { index in
                            let startBinding = Binding<Date>(
                                get: { Date(timeIntervalSinceReferenceDate: caregiverAvailability[index].startTime) },
                                set: { newDate in caregiverAvailability[index].startTime = newDate.timeIntervalSinceReferenceDate }
                            )
                            let endBinding = Binding<Date>(
                                get: { Date(timeIntervalSinceReferenceDate: caregiverAvailability[index].endTime) },
                                set: { newDate in caregiverAvailability[index].endTime = newDate.timeIntervalSinceReferenceDate }
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(String(format: "%@ %d", settings.localized("schedule.careWindowLabel"), index + 1))
                                        .font(settings.scaledFont(14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button(role: .destructive) {
                                        deleteCaregiverAvailabilityWindow(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                                DatePicker(
                                    settings.localized("schedule.careStartTime"),
                                    selection: startBinding,
                                    displayedComponents: .hourAndMinute
                                )
                                DatePicker(
                                    settings.localized("schedule.careEndTime"),
                                    selection: endBinding,
                                    displayedComponents: .hourAndMinute
                                )
                            }
                            .padding(.vertical, 8)
                        }

                        Button(action: addCaregiverAvailabilityWindow) {
                            Label(settings.localized("schedule.addCareWindow"), systemImage: "plus")
                        }
                    }
                }
                .navigationTitle(settings.localized("home.addCaregiver"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(settings.localized("home.cancel")) {
                            isAddingCaregiver = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(settings.localized("home.save")) {
                            addCaregiver()
                        }
                        .disabled(newCaregiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .sheet(isPresented: $showIconPicker) {
                    caregiverIconPickerSheet
                }
            }
        }
        .sheet(item: $editingCaregiver) { caregiver in
            NavigationStack {
                Form {
                    Section(header: Text(settings.localized("home.edit"))) {
                        TextField(settings.localized("home.caregiverName"), text: $newCaregiverName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.emailPlaceholder"), text: $newCaregiverEmail)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.phonePlaceholder"), text: $newCaregiverPhone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        caregiverIconRow
                    }

                    Section(header: Text(settings.localized("home.caregiverAvailability"))) {
                        ForEach(caregiverAvailability.indices, id: \.self) { index in
                            let startBinding = Binding<Date>(
                                get: { Date(timeIntervalSinceReferenceDate: caregiverAvailability[index].startTime) },
                                set: { newDate in caregiverAvailability[index].startTime = newDate.timeIntervalSinceReferenceDate }
                            )
                            let endBinding = Binding<Date>(
                                get: { Date(timeIntervalSinceReferenceDate: caregiverAvailability[index].endTime) },
                                set: { newDate in caregiverAvailability[index].endTime = newDate.timeIntervalSinceReferenceDate }
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(String(format: "%@ %d", settings.localized("schedule.careWindowLabel"), index + 1))
                                        .font(settings.scaledFont(14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button(role: .destructive) {
                                        deleteCaregiverAvailabilityWindow(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                                DatePicker(
                                    settings.localized("schedule.careStartTime"),
                                    selection: startBinding,
                                    displayedComponents: .hourAndMinute
                                )
                                DatePicker(
                                    settings.localized("schedule.careEndTime"),
                                    selection: endBinding,
                                    displayedComponents: .hourAndMinute
                                )
                            }
                            .padding(.vertical, 8)
                        }

                        Button(action: addCaregiverAvailabilityWindow) {
                            Label(settings.localized("schedule.addCareWindow"), systemImage: "plus")
                        }
                    }
                }
                .navigationTitle(settings.localized("home.edit"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(settings.localized("home.cancel")) {
                            editingCaregiver = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(settings.localized("home.save")) {
                            saveEditedCaregiver()
                        }
                        .disabled(newCaregiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear {
                    newCaregiverName = caregiver.name
                    newCaregiverEmail = caregiver.email
                    newCaregiverPhone = caregiver.phone
                    newCaregiverIcon = caregiver.icon
                    caregiverAvailability = caregiver.availability
                }
                .sheet(isPresented: $showIconPicker) {
                    caregiverIconPickerSheet
                }
            }
        }
        .onAppear {
            if !isEditingProfile {
                draftPatientName = settings.patientName
                draftPatientAge = settings.patientAge
                draftPatientGenderKey = settings.patientGenderKey
                draftPatientNotes = settings.patientNotes
            }
            manager.updateAuthorizationStatus()
            if manager.authorizationStatus == .sharingAuthorized {
                manager.refreshLatestMeasurements()
            }
            loadLatestChartMetrics()
        }
        .onChange(of: manager.authorizationStatus) { _, newStatus in
            if newStatus == .sharingAuthorized {
                manager.refreshLatestMeasurements()
            }
            loadLatestChartMetrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: HealthKitManager.didRecordMeasurementNotification)) { notification in
            // When a new measurement is recorded, upload it from the patient dashboard as well
            var measuredDate = Date()
            if let info = notification.userInfo {
                if let d = info["date"] as? Date {
                    measuredDate = d
                } else if let key = info["dateKey"] as? String {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd"
                    if let parsed = fmt.date(from: key) {
                        measuredDate = parsed
                    }
                }
            }

            // Prefer scheduleManager stored measurement if exists
            let scheduleMeasurement = CareScheduleManager.shared.measurement(for: measuredDate)
            let source = scheduleMeasurement ?? manager.measurement(for: measuredDate)

            guard let temp = source?.temp,
                  let spo2 = source?.spo2,
                  let sys = source?.sys,
                  let dia = source?.dia else {
                return
            }

            DispatchQueue.global(qos: .utility).async {
                var components = URLComponents(string: Setting.shared.appScriptUrl)
                var items: [URLQueryItem] = []
                items.append(URLQueryItem(name: "sheetId", value: Setting.shared.sheetId))
                items.append(URLQueryItem(name: "sheetName", value: "patient_dashboard"))

                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                items.append(URLQueryItem(name: "datetime", value: fmt.string(from: measuredDate)))

                items.append(URLQueryItem(name: "temperature", value: String(format: "%.1f", temp)))
                items.append(URLQueryItem(name: "spo2", value: String(format: "%.1f", spo2)))
                items.append(URLQueryItem(name: "systolic", value: String(format: "%.0f", sys)))
                items.append(URLQueryItem(name: "diastolic", value: String(format: "%.0f", dia)))
                items.append(URLQueryItem(name: "user", value: Setting.shared.username))

                items.append(URLQueryItem(name: "patientName", value: settings.patientName))
                items.append(URLQueryItem(name: "patientAge", value: String(settings.patientAge)))
                items.append(URLQueryItem(name: "patientGender", value: settings.localized(settings.patientGenderKey)))

                components?.queryItems = items
                guard let url = components?.url else { return }

                let task = URLSession.shared.dataTask(with: url) { _, _, _ in }
                task.resume()
            }
        }
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(settings.localized("home.profileTitle"))
                    .font(settings.scaledFont(22, weight: .bold))
                Spacer()
                Button(action: {
                    draftPatientName = settings.patientName
                    draftPatientAge = settings.patientAge
                    draftPatientGenderKey = settings.patientGenderKey
                    isEditingProfile = true
                }) {
                    Text(settings.localized("home.edit"))
                        .font(settings.scaledFont(14, weight: .semibold))
                }
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.localized("home.patientName"))
                        .font(settings.scaledFont(14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(settings.patientName)
                        .font(settings.scaledFont(18, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.localized("home.patientAge"))
                        .font(settings.scaledFont(14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(settings.patientAge)")
                        .font(settings.scaledFont(18, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.localized("home.patientGender"))
                        .font(settings.scaledFont(14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(settings.localized(settings.patientGenderKey))
                        .font(settings.scaledFont(18, weight: .bold))
                }
            }
            if !settings.patientNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.localized("home.patientNotes"))
                        .font(settings.scaledFont(14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(settings.patientNotes)
                        .font(settings.scaledFont(16))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    private var careWindowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(settings.localized("schedule.careHoursTitle"))
                    .font(settings.scaledFont(18, weight: .semibold))
                Spacer()
                Button(action: addCareWindow) {
                    Label(settings.localized("schedule.addCareWindow"), systemImage: "plus")
                        .font(settings.scaledFont(14, weight: .semibold))
                }
            }

            Text(settings.localized("schedule.careHoursDescription"))
                .font(settings.scaledFont(14))
                .foregroundColor(.secondary)

            ForEach(scheduleManager.dailyCareWindows.indices, id: \ .self) { index in
                let window = scheduleManager.dailyCareWindows[index]

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(String(format: "%@ %d", settings.localized("schedule.careWindowLabel"), index + 1))
                            .font(settings.scaledFont(14, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        if scheduleManager.dailyCareWindows.count > 1 {
                            Button(role: .destructive) {
                                scheduleManager.deleteCareWindow(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(settings.localized("schedule.careStartTime"))
                                .font(settings.scaledFont(14, weight: .semibold))
                                .foregroundColor(.secondary)
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { Date(timeIntervalSinceReferenceDate: window.startTime) },
                                    set: { scheduleManager.updateCareWindow(at: index, startTime: $0.timeIntervalSinceReferenceDate) }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(settings.localized("schedule.careEndTime"))
                                .font(settings.scaledFont(14, weight: .semibold))
                                .foregroundColor(.secondary)
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { Date(timeIntervalSinceReferenceDate: window.endTime) },
                                    set: { scheduleManager.updateCareWindow(at: index, endTime: $0.timeIntervalSinceReferenceDate) }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            if scheduleManager.dailyCareWindows.contains(where: { $0.endTime <= $0.startTime }) {
                Text(settings.localized("schedule.careHoursInvalid"))
                    .font(settings.scaledFont(13))
                    .foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    private func addCareWindow() {
        scheduleManager.addCareWindow()
    }

    private var caregiverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.localized("home.primaryCaregivers"))
                    .font(settings.scaledFont(18, weight: .semibold))
                Spacer()
                Button(action: {
                    newCaregiverName = ""
                    newCaregiverEmail = ""
                    newCaregiverPhone = ""
                    newCaregiverIcon = ""
                    caregiverAvailability = []
                    isAddingCaregiver = true
                }) {
                    Text(settings.localized("home.addCaregiver"))
                        .font(settings.scaledFont(14, weight: .semibold))
                }
            }

            if scheduleManager.caregivers.isEmpty {
                Text(settings.localized("home.noCaregivers"))
                    .foregroundColor(.secondary)
            } else {
                ForEach(scheduleManager.caregivers) { caregiver in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                if !caregiver.icon.isEmpty {
                                    Text(caregiver.icon)
                                        .font(settings.scaledFont(22))
                                }
                                Text(caregiver.name)
                                    .font(settings.scaledFont(16, weight: .semibold))
                            }
                            if !caregiver.email.isEmpty {
                                Text("Email：\(caregiver.email)")
                                    .font(settings.scaledFont(13))
                                    .foregroundColor(.secondary)
                            }
                            if !caregiver.phone.isEmpty {
                                Text("電話：\(caregiver.phone)")
                                    .font(settings.scaledFont(13))
                                    .foregroundColor(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            Spacer()
                            Button(settings.localized("home.edit")) {
                                editingCaregiver = caregiver
                                newCaregiverName = caregiver.name
                                newCaregiverEmail = caregiver.email
                                newCaregiverPhone = caregiver.phone
                                newCaregiverIcon = caregiver.icon
                            }
                            .font(settings.scaledFont(14, weight: .semibold))
                            Button(settings.localized("schedule.delete")) {
                                deleteCaregiver(caregiver)
                            }
                            .foregroundColor(.red)
                            .font(settings.scaledFont(14, weight: .semibold))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .cornerRadius(14)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    private func addCaregiver() {
        let newCaregiver = Caregiver(name: newCaregiverName.trimmingCharacters(in: .whitespacesAndNewlines),
                                     email: newCaregiverEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                                     phone: newCaregiverPhone.trimmingCharacters(in: .whitespacesAndNewlines),
                                     icon: newCaregiverIcon,
                                     availability: caregiverAvailability)
        scheduleManager.addCaregiver(newCaregiver)
        isAddingCaregiver = false
        caregiverAvailability = []
        newCaregiverIcon = ""
    }

    private func addCaregiverAvailabilityWindow() {
        let nextStart = caregiverAvailability.last?.endTime ?? (8 * 3600)
        let nextEnd = min(nextStart + 2 * 3600, 24 * 3600)
        caregiverAvailability.append(CareWindow(startTime: nextStart, endTime: nextEnd))
    }

    private func deleteCaregiverAvailabilityWindow(at index: Int) {
        guard caregiverAvailability.indices.contains(index) else { return }
        caregiverAvailability.remove(at: index)
    }

    private func deleteCaregiver(_ caregiver: Caregiver) {
        scheduleManager.deleteCaregiver(caregiver)
    }

    private func saveEditedCaregiver() {
        guard var caregiver = editingCaregiver else { return }
        caregiver.name = newCaregiverName.trimmingCharacters(in: .whitespacesAndNewlines)
        caregiver.email = newCaregiverEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        caregiver.phone = newCaregiverPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        caregiver.icon = newCaregiverIcon
        caregiver.availability = caregiverAvailability
        scheduleManager.updateCaregiver(caregiver)
        editingCaregiver = nil
        caregiverAvailability = []
        newCaregiverIcon = ""
    }

    private func anomalyBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.localized("home.alerts"))
                .font(settings.scaledFont(16, weight: .semibold))
            Text(message)
                .font(settings.scaledFont(14))
                .foregroundColor(.red)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemRed).opacity(0.12))
        .cornerRadius(18)
    }

    private var healthSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(settings.localized("home.latestRecords"))
                    .font(settings.scaledFont(18, weight: .semibold))
                Spacer()
                if manager.anomalyMessage == nil {
                    Text(settings.localized("home.noAlerts"))
                        .font(settings.scaledFont(14))
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                healthMetricTile(title: settings.localized("health.metric.oxygen"), value: formatted(displayedOxygenSaturation, unit: "%"), warning: displayedOxygenSaturation.map { $0 < 93 } ?? false)
                healthMetricTile(title: settings.localized("health.metric.temperature"), value: formatted(displayedTemperature, unit: "°C"), warning: displayedTemperature.map { $0 > 38.5 } ?? false)
            }
            HStack(spacing: 12) {
                healthMetricTile(title: settings.localized("health.metric.systolic"), value: formatted(displayedSystolicPressure, unit: "mmHg"), warning: displayedSystolicPressure.map { $0 >= 140 } ?? false)
                healthMetricTile(title: settings.localized("health.metric.diastolic"), value: formatted(displayedDiastolicPressure, unit: "mmHg"), warning: displayedDiastolicPressure.map { $0 >= 90 } ?? false)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    private var recordChartsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.localized("home.viewTrendCharts"))
                    .font(settings.scaledFont(18, weight: .semibold))
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    chartCard(title: settings.localized("home.thermometer"), systemImage: "thermometer", destination: ThermometerDataChartView())
                    chartCard(title: settings.localized("home.oximeter"), systemImage: "waveform.path.ecg", destination: OximeterDataChartView())
                    chartCard(title: settings.localized("home.bloodPressure"), systemImage: "heart.circle", destination: BloodPressureDataChartView())
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func chartCard<Destination: View>(title: String, systemImage: String, destination: Destination) -> some View {
        NavigationLink(destination: destination.environmentObject(settings)) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(settings.scaledFont(16, weight: .semibold))
                    .foregroundColor(.primary)
                Text(settings.localized("home.viewCharts"))
                    .font(settings.scaledFont(14))
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 180, height: 120)
            .background(Color(.systemBackground))
            .cornerRadius(18)
            .shadow(color: Color(.black).opacity(0.06), radius: 8, x: 0, y: 4)
        }
    }

    private func healthMetricTile(title: String, value: String, warning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(settings.scaledFont(14, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(settings.scaledFont(20, weight: .bold))
                .foregroundColor(warning ? .red : .primary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(warning ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value = value else {
            return "--"
        }
        return String(format: "%.1f%@", value, unit)
    }

    private var displayedOxygenSaturation: Double? {
        latestChartSpo2 ?? manager.oxygenSaturation
    }

    private var displayedTemperature: Double? {
        latestChartTemperature ?? manager.temperature
    }

    private var displayedSystolicPressure: Double? {
        latestChartSystolic ?? manager.systolicPressure
    }

    private var displayedDiastolicPressure: Double? {
        latestChartDiastolic ?? manager.diastolicPressure
    }

    private func loadLatestChartMetrics() {
        fetchLatestThermometerValue()
        fetchLatestOximeterValue()
        fetchLatestBloodPressureValue()
    }

    private func fetchLatestThermometerValue() {
        let sheetName = "thermometer"
        guard var components = URLComponents(string: Setting.shared.appScriptUrl) else { return }
        components.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: sheetName),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]
        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil else { return }
            do {
                guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArray = jsonObject["data"] as? [[String: Any]] else {
                    return
                }

                let rawFormatter = DateFormatter()
                rawFormatter.locale = Locale(identifier: "en_US_POSIX")
                rawFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

                var latestDate: Date?
                var latestValue: Double?
                for row in dataArray {
                    guard let timeString = row["datetime"] as? String,
                          let date = rawFormatter.date(from: timeString),
                          let temperature = self.parseNumericValue(from: row, for: "temperature") else {
                        continue
                    }
                    if latestDate == nil || date > latestDate! {
                        latestDate = date
                        latestValue = temperature
                    }
                }

                DispatchQueue.main.async {
                    self.latestChartTemperature = latestValue
                }
            } catch {
                print("Failed to parse thermometer chart data: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func fetchLatestOximeterValue() {
        let sheetName = "oximeter"
        guard var components = URLComponents(string: Setting.shared.appScriptUrl) else { return }
        components.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: sheetName),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]
        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil else { return }
            do {
                guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArray = jsonObject["data"] as? [[String: Any]] else {
                    return
                }

                let rawFormatter = DateFormatter()
                rawFormatter.locale = Locale(identifier: "en_US_POSIX")
                rawFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

                var latestDate: Date?
                var latestValue: Double?
                for row in dataArray {
                    guard let timeString = row["datetime"] as? String,
                          let date = rawFormatter.date(from: timeString),
                          let spo2 = self.parseNumericValue(from: row, for: "spo2") else {
                        continue
                    }
                    if latestDate == nil || date > latestDate! {
                        latestDate = date
                        latestValue = spo2
                    }
                }

                DispatchQueue.main.async {
                    self.latestChartSpo2 = latestValue
                }
            } catch {
                print("Failed to parse oximeter chart data: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func fetchLatestBloodPressureValue() {
        let sheetName = "blood_pressure_meter"
        guard var components = URLComponents(string: Setting.shared.appScriptUrl) else { return }
        components.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: sheetName),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]
        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil else { return }
            do {
                guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArray = jsonObject["data"] as? [[String: Any]] else {
                    return
                }

                let rawFormatter = DateFormatter()
                rawFormatter.locale = Locale(identifier: "en_US_POSIX")
                rawFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

                var latestDate: Date?
                var latestSys: Double?
                var latestDia: Double?
                for row in dataArray {
                    guard let timeString = row["datetime"] as? String,
                          let date = rawFormatter.date(from: timeString),
                          let systolic = self.parseNumericValue(from: row, for: "systolic"),
                          let diastolic = self.parseNumericValue(from: row, for: "diastolic") else {
                        continue
                    }
                    if latestDate == nil || date > latestDate! {
                        latestDate = date
                        latestSys = systolic
                        latestDia = diastolic
                    }
                }

                DispatchQueue.main.async {
                    self.latestChartSystolic = latestSys
                    self.latestChartDiastolic = latestDia
                }
            } catch {
                print("Failed to parse blood pressure chart data: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func parseNumericValue(from item: [String: Any], for key: String) -> Double? {
        if let doubleValue = item[key] as? Double {
            return doubleValue
        }
        if let intValue = item[key] as? Int {
            return Double(intValue)
        }
        if let stringValue = item[key] as? String {
            return Double(stringValue)
        }
        return nil
    }

    /// Inline row that lives in both the Add and Edit caregiver Forms.
    /// Tapping opens a dedicated full-screen sheet for picking the emoji,
    /// keeping the picker grid outside of any `List`/`Form` so tap targets
    /// stay reliable on iPhone & iPad.
    private var caregiverIconRow: some View {
        Button(action: { showIconPicker = true }) {
            HStack {
                Text(settings.localized("schedule.caregiverIconLabel"))
                    .font(settings.scaledFont(15, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if newCaregiverIcon.isEmpty {
                    Text(settings.localized("schedule.caregiverIconNone"))
                        .font(settings.scaledFont(13))
                        .foregroundColor(.secondary)
                } else {
                    Text(newCaregiverIcon)
                        .font(.system(size: 28))
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(BorderlessButtonStyle())
    }

    private var caregiverIconPickerSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(settings.localized("schedule.caregiverIconLabel"))
                        .font(settings.scaledFont(18, weight: .semibold))

                    Button(action: {
                        newCaregiverIcon = ""
                        showIconPicker = false
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.red)
                                .font(.title2)
                            Text(settings.localized("schedule.caregiverIconClear"))
                                .font(settings.scaledFont(15, weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            if newCaregiverIcon.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.tertiarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                              spacing: 12) {
                        ForEach(CaregiverIconPalette.options, id: \.self) { emoji in
                            Button(action: {
                                newCaregiverIcon = emoji
                                showIconPicker = false
                            }) {
                                Text(emoji)
                                    .font(.system(size: 36))
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(newCaregiverIcon == emoji
                                                  ? Color(.systemBlue).opacity(0.22)
                                                  : Color(.tertiarySystemBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(newCaregiverIcon == emoji ? Color(.systemBlue) : Color(.separator),
                                                    lineWidth: newCaregiverIcon == emoji ? 2.5 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(settings.localized("schedule.caregiverIconLabel"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.localized("schedule.close")) {
                        showIconPicker = false
                    }
                }
            }
        }
    }

    private func saveProfile() {
        settings.patientName = draftPatientName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.patientAge = draftPatientAge
        settings.patientGenderKey = draftPatientGenderKey
        settings.patientNotes = draftPatientNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    NavigationView {
        PatientProfileView()
            .environmentObject(AppSettings.shared)
    }
}
