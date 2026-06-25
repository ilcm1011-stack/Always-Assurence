import SwiftUI
import iREdFramework

#if os(macOS)
import AppKit
#endif

import EventKit

#if canImport(UIKit)
import UIKit
#endif

struct ScheduleBoardView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var scheduleManager = CareScheduleManager.shared
    @StateObject private var eventKitManager = EventKitManager.shared

    @State private var assignee = ""
    @State private var selectedCaregiverId: UUID? = nil
    @State private var selectedCaregiverWindowId: UUID? = nil
    @State private var taskSummary = ""
    @State private var note = ""
    @State private var contactEmail = ""
    @State private var contactPhone = ""
    @AppStorage("autoEmailReminderEnabled") private var autoEmailReminderEnabled = false
    @State private var startDate = Date()
    @State private var endDate = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date()
    @State private var exportAlertMessage: String?
    @State private var showExportAlert = false
    @State private var showCaregiverManager = false
    @State private var caregiverEditor: Caregiver?
    @State private var caregiverName = ""
    @State private var caregiverEmailField = ""
    @State private var caregiverPhoneField = ""

    private enum RecurrenceOption: String, CaseIterable, Identifiable {
        case none
        case daily
        case monthly
        case yearly

        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .none: return "schedule.recurrence.none"
            case .daily: return "schedule.recurrence.daily"
            case .monthly: return "schedule.recurrence.monthly"
            case .yearly: return "schedule.recurrence.yearly"
            }
        }
    }

    @State private var recurrenceOption: RecurrenceOption = .none

    /// Filter for the shift list at the bottom of the board. By default the
    /// list shows only the shifts for the selected calendar day; users can
    /// expand it to a week / month / year horizon, or "All".
    private enum ShiftListFilter: String, CaseIterable, Identifiable {
        case selectedDay
        case week
        case month
        case year
        case all

        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .selectedDay: return "schedule.filter.selectedDay"
            case .week:        return "schedule.filter.week"
            case .month:       return "schedule.filter.month"
            case .year:        return "schedule.filter.year"
            case .all:         return "schedule.filter.all"
            }
        }
    }

    @State private var shiftListFilter: ShiftListFilter = .selectedDay

    @State private var editingShift: Shift?
    @State private var editSelectedCaregiverId: UUID? = nil
    @State private var editAssignee = ""
    @State private var editTaskSummary = ""
    @State private var editNote = ""
    @State private var editContactEmail = ""
    @State private var editContactPhone = ""
    @State private var editStartDate = Date()
    @State private var editEndDate = Date()
    @State private var confirmDeleteShift: Shift?

    // Calendar / Health data state
    @State private var selectedDate: Date = Date()
    @ObservedObject private var healthManager = HealthKitManager.shared
    @Environment(\.openURL) private var openURL
    @StateObject private var ble = iREdBluetooth.shared
    @State private var measurementsByDate: [String: (temp: Double?, spo2: Double?, sys: Double?, dia: Double?)] = [:]

    private var calendar = Calendar.current

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }

    @State private var showScheduleSettings = false
    @State private var showHomecareLink = false
    @State private var showGapWarningAlert = false
    @State private var showCompletionCelebration = false
    @State private var showShareSheet = false
    @State private var completionMessage = ""
    @State private var completionScale: CGFloat = 1.0

    private var completionMessages: [String] {
        settings.localized("schedule.completionMessages").components(separatedBy: "|")
    }

    private var selectedCaregiver: Caregiver? {
        guard let caregiverId = selectedCaregiverId else { return nil }
        return scheduleManager.caregivers.first { $0.id == caregiverId }
    }

    private var elderButtonFont: Font { settings.scaledFont(20, weight: .semibold) }
    private var elderTitleFont: Font { settings.scaledFont(22, weight: .bold) }
    private var elderBodyFont: Font { settings.scaledFont(18) }
    private var elderCaptionFont: Font { settings.scaledFont(16) }

    private var editSelectedCaregiver: Caregiver? {
        guard let caregiverId = editSelectedCaregiverId else { return nil }
        return scheduleManager.caregivers.first { $0.id == caregiverId }
    }

    private func applySelectedCaregiver() {
        // Reset the time-window picker so it doesn't carry over a slot
        // from a previously selected caregiver.
        selectedCaregiverWindowId = nil
        if let caregiver = selectedCaregiver {
            assignee = caregiver.name
            contactEmail = caregiver.email
            contactPhone = caregiver.phone
        } else {
            // "Not assigned" sentinel — clear any stale entries so the
            // shift is saved as truly unassigned with no contact info.
            assignee = ""
            contactEmail = ""
            contactPhone = ""
        }
    }

    private var completionCelebrationView: some View {
        VStack(spacing: 16) {
            Text("👏👏👏")
                .font(.system(size: 48))
                .scaleEffect(completionScale)
            Text(completionMessage)
                .font(elderTitleFont)
                .multilineTextAlignment(.center)
            Text(settings.localized("schedule.completionSubtitle"))
                .font(elderBodyFont)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(24)
        .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 24)
        .scaleEffect(completionScale)
    }

    private func showCompletionThankYou() {
        completionMessage = completionMessages.randomElement() ?? settings.localized("schedule.completionFallback")
        completionScale = 0.6
        showCompletionCelebration = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6, blendDuration: 0)) {
            completionScale = 1.1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.35)) {
                showCompletionCelebration = false
            }
        }
    }

    private func applySelectedCareWindow() {
        guard let caregiver = selectedCaregiver,
              let windowId = selectedCaregiverWindowId,
              let window = caregiver.availability.first(where: { $0.id == windowId }) else {
            return
        }

        let dateComponents = calendar.dateComponents([.year, .month, .day], from: startDate)
        let startComponents = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSinceReferenceDate: window.startTime))
        let endComponents = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSinceReferenceDate: window.endTime))

        if let newStart = calendar.date(from: DateComponents(
            year: dateComponents.year,
            month: dateComponents.month,
            day: dateComponents.day,
            hour: startComponents.hour,
            minute: startComponents.minute
        )) {
            startDate = newStart
        }

        if let newEnd = calendar.date(from: DateComponents(
            year: dateComponents.year,
            month: dateComponents.month,
            day: dateComponents.day,
            hour: endComponents.hour,
            minute: endComponents.minute
        )) {
            endDate = newEnd
        }
    }

    private func applyEditSelectedCaregiver() {
        if let caregiver = editSelectedCaregiver {
            editAssignee = caregiver.name
            editContactEmail = caregiver.email
            editContactPhone = caregiver.phone
        }
    }

    var body: some View {
        ZStack {
            AlwaysVisibleScrollView {
                VStack(spacing: 28) {
                header
                dailyScheduleSummary
                if let gapAlert = scheduleManager.gapAlert {
                    gapAlertCard(message: gapAlert)
                }
                if let missingSignInAlert = scheduleManager.missingSignInAlert {
                    missingSignInCard(message: missingSignInAlert)
                }

                thresholdReminderBanner
                ScheduleCalendarView(
                    selectedDate: $selectedDate,
                    startDate: $startDate,
                    endDate: $endDate,
                    measurementsByDate: measurementsByDate,
                    onDateSelected: loadMeasurementsForSelectedDate
                )
                HStack {
                    Spacer()
                    Button(action: { showScheduleSettings = true }) {
                        Label {
                            Text(settings.localized("schedule.settings"))
                                .font(elderButtonFont)
                        } icon: {
                            Image(systemName: "gearshape")
                                .font(elderButtonFont)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .frame(minWidth: 140, minHeight: 44)
                        .background(Color(.systemBlue))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(color: Color(.black).opacity(0.12), radius: 4, x: 0, y: 2)
                    }
                }

                exportButton
                shareScheduleButton
                newShiftForm
                shiftList
            }
            .padding()
        }

            if showCompletionCelebration {
                completionCelebrationView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.28))
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .onAppear {
            // When opening the schedule board, default to today and load measurements
            CareNotificationManager.shared.requestAuthorization { _ in }
            selectedDate = Date()
            loadMeasurementsForSelectedDate()
            scheduleAutoRemindersForUpcomingShifts()
            showGapWarningAlert = scheduleManager.gapAlert != nil

            // Ensure new-shift date pickers don't default to a past date
            if startDate < Date() {
                startDate = Date()
            }
            if endDate <= startDate {
                endDate = Calendar.current.date(byAdding: .hour, value: 6, to: startDate) ?? startDate
            }
        }
        .onChange(of: autoEmailReminderEnabled) { _, newValue in
            if newValue {
                // When enabling auto email reminders, schedule/send for existing shifts immediately
                scheduleAutoRemindersForUpcomingShifts()
            } else {
                // When disabling, cancel any scheduled shift reminder notifications
                CareNotificationManager.shared.cancelScheduledNotifications(matchingPrefix: "shift-reminder-")
            }
        }
        .navigationTitle(settings.localized("home.scheduleBoard"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showExportAlert) {
            Alert(title: Text(settings.localized("schedule.export")), message: Text(exportAlertMessage ?? settings.localized("schedule.exportSuccess")), dismissButton: .default(Text(settings.localized("device.understood"))))
        }
        .alert(isPresented: $showGapWarningAlert) {
            Alert(
                title: Text(settings.localized("schedule.gap.title")),
                message: Text(scheduleManager.gapAlert ?? ""),
                primaryButton: .default(Text(settings.localized("schedule.gap.action")), action: notifyBackupSupport),
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showScheduleSettings) {
            NavigationView {
                ScheduleSettingsSheet()
                    .environmentObject(settings)
            }
        }
        .sheet(item: $editingShift) { _ in
            NavigationView {
                Form {
                    Section(header: Text(settings.localized("schedule.editTask"))) {
                        if !scheduleManager.caregivers.isEmpty {
                            Picker(settings.localized("schedule.selectCaregiver"), selection: $editSelectedCaregiverId) {
                                Text(settings.localized("schedule.customCaregiver")).tag(UUID?.none)
                                ForEach(scheduleManager.caregivers) { caregiver in
                                    Text(caregiver.name).tag(Optional(caregiver.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: editSelectedCaregiverId) { _, _ in
                                applyEditSelectedCaregiver()
                            }
                        }
                        TextField(settings.localized("schedule.assigneePlaceholder"), text: $editAssignee)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        DatePicker(settings.localized("schedule.startTime"), selection: $editStartDate, displayedComponents: [.date, .hourAndMinute])
                        DatePicker(settings.localized("schedule.endTime"), selection: $editEndDate, displayedComponents: [.date, .hourAndMinute])
                        TextField(settings.localized("schedule.taskSummaryPlaceholder"), text: $editTaskSummary)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.notePlaceholder"), text: $editNote)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.emailPlaceholder"), text: $editContactEmail)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField(settings.localized("schedule.phonePlaceholder"), text: $editContactPhone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
                .navigationTitle(settings.localized("schedule.editTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(settings.localized("schedule.cancel")) {
                            editingShift = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(settings.localized("schedule.save")) {
                            saveEditedShift()
                        }
                        .disabled(editEndDate <= editStartDate)
                    }
                }
            }
        }
        .sheet(isPresented: $showCaregiverManager) {
            caregiverManagerSheet
        }
        .sheet(isPresented: $showHomecareLink) {
            if let url = Bundle.main.url(forResource: "homecare", withExtension: "html") {
                WebView(url: url)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Text(settings.localized("schedule.homecareNotFound"))
                        .font(.title3)
                    Text(settings.localized("schedule.homecareNotFoundDesc"))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    Button(settings.localized("schedule.close")) {
                        showHomecareLink = false
                    }
                    .padding()
                    .background(Color(.systemBlue))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HealthKitManager.didRecordMeasurementNotification)) { notification in
            guard let info = notification.userInfo else { return }
            var notifiedDate: Date?
            if let d = info["date"] as? Date {
                notifiedDate = d
            } else if let key = info["dateKey"] as? String {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                notifiedDate = fmt.date(from: key)
            }

            guard let date = notifiedDate else { return }

            DispatchQueue.main.async {
                let key = isoDate(date)
                let persisted = healthManager.measurement(for: date)

                var storedTemp = persisted?.temp
                var storedSpo2 = persisted?.spo2
                var storedSys = persisted?.sys
                var storedDia = persisted?.dia

                // If notified date is today, prefer live BLE readings when available
                if Calendar.current.isDateInToday(date) {
                    if let t = ble.iredDeviceData.thermometerData.data.temperature {
                        storedTemp = t
                    }
                    if let s = ble.iredDeviceData.oximeterData.data.spo2 {
                        storedSpo2 = Double(s) / 100.0
                    }
                    if let syst = ble.iredDeviceData.sphygmometerData.data.systolic {
                        storedSys = Double(syst)
                    }
                    if let dias = ble.iredDeviceData.sphygmometerData.data.diastolic {
                        storedDia = Double(dias)
                    }
                }

                measurementsByDate[key] = (temp: storedTemp, spo2: storedSpo2, sys: storedSys, dia: storedDia)
            }
        }
        .alert(item: $confirmDeleteShift) { shift in
            Alert(title: Text(settings.localized("schedule.confirmDelete")),
                  message: Text(settings.localized("schedule.confirmDeleteMessage")),
                  primaryButton: .destructive(Text(settings.localized("schedule.delete"))) {
                      scheduleManager.deleteShift(shift)
                  },
                  secondaryButton: .cancel())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text(settings.localized("schedule.title"))
                    .font(.title)
                    .fontWeight(.bold)
                Text(settings.localized("schedule.subtitle"))
                    .font(.body)
                    .lineSpacing(6)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gapAlertCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localized("schedule.gap.title"))
                .font(.title3)
            Text(message)
                .font(.body)
                .lineSpacing(6)
                .foregroundColor(.red)
            Button(action: notifyBackupSupport) {
                Text(settings.localized("schedule.gap.action"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemOrange))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
        }
        .padding()
        .background(Color(.systemRed).opacity(0.1))
        .cornerRadius(18)
    }

    private func missingSignInCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localized("schedule.signIn.title"))
                .font(.title3)
            Text(message)
                .font(.body)
                .lineSpacing(6)
                .foregroundColor(.orange)
        }
        .padding()
        .background(Color(.systemYellow).opacity(0.12))
        .cornerRadius(18)
    }

    private var exportButton: some View {
        Button(action: exportShiftsToCalendar) {
            Text(settings.localized("schedule.export"))
                .font(elderButtonFont)
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding()
                .background(Color(.systemPurple))
                .foregroundColor(.white)
                .cornerRadius(16)
        }
    }

    private var shareScheduleButton: some View {
        Button(action: {
            showShareSheet = true
        }) {
            Text(settings.localized("schedule.shareSchedule"))
                .font(elderButtonFont)
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding()
                .background(Color(.systemTeal))
                .foregroundColor(.white)
                .cornerRadius(16)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [scheduleShareText()])
        }
    }

    private var newShiftForm: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.localized("schedule.addTask"))
                    .font(.title3)

                // Assignee must come from the saved caregivers list. The
                // sentinel "Not assigned (pending)" entry creates an
                // unassigned shift so it can be filled in later.
                Picker(settings.localized("schedule.selectCaregiver"), selection: $selectedCaregiverId) {
                    Text(settings.localized("schedule.assignee.notAssigned")).tag(UUID?.none)
                    ForEach(scheduleManager.caregivers) { caregiver in
                        Text(caregiver.name).tag(Optional(caregiver.id))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCaregiverId) { _, _ in
                    applySelectedCaregiver()
                }

                // Empty-state helper: if no caregivers exist yet, explain
                // what to do and surface a button to open the manager so
                // the user isn't stuck on "Not assigned".
                if scheduleManager.caregivers.isEmpty {
                    Text(settings.localized("schedule.assignee.needCaregivers"))
                        .font(settings.scaledFont(13))
                        .foregroundColor(.secondary)
                    Button(action: { showCaregiverManager = true }) {
                        Label(settings.localized("schedule.openCaregiverManager"),
                              systemImage: "person.crop.circle.badge.plus")
                            .font(settings.scaledFont(15, weight: .semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Color(.systemIndigo).opacity(0.14))
                            .foregroundColor(Color(.systemIndigo))
                            .cornerRadius(10)
                    }
                }

                // When a real caregiver is picked, show their contact info
                // as read-only confirmation (no more free-text email/phone
                // entry — those belong to the caregiver record).
                if let caregiver = selectedCaregiver {
                    VStack(alignment: .leading, spacing: 4) {
                        if !caregiver.email.isEmpty {
                            Label("\(settings.localized("schedule.emailLabel"))\(caregiver.email)",
                                  systemImage: "envelope.fill")
                                .font(settings.scaledFont(13))
                                .foregroundColor(.secondary)
                        }
                        if !caregiver.phone.isEmpty {
                            Label("\(settings.localized("schedule.phoneLabel"))\(caregiver.phone)",
                                  systemImage: "phone.fill")
                                .font(settings.scaledFont(13))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let windows = selectedCaregiver?.availability, !windows.isEmpty {
                    Picker(settings.localized("schedule.selectCaregiverWindow"), selection: $selectedCaregiverWindowId) {
                        Text(settings.localized("schedule.customTimeWindow")).tag(UUID?.none)
                        ForEach(windows) { window in
                            Text(formatWindow(window))
                                .tag(Optional(window.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedCaregiverWindowId) { _, _ in
                        applySelectedCareWindow()
                    }
                }

                let minStart = Calendar.current.startOfDay(for: Date())
                DatePicker(settings.localized("schedule.timeLabel"), selection: $startDate, in: minStart..., displayedComponents: [.date, .hourAndMinute])
                DatePicker(settings.localized("schedule.timeLabel"), selection: $endDate, in: startDate..., displayedComponents: [.date, .hourAndMinute])

                Picker(settings.localized("schedule.recurrenceLabel"), selection: $recurrenceOption) {
                    ForEach(RecurrenceOption.allCases) { option in
                        Text(settings.localized(option.titleKey)).tag(option)
                    }
                }
                .pickerStyle(.menu)

                TextField(settings.localized("schedule.taskSummaryPlaceholder"), text: $taskSummary)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                TextField(settings.localized("schedule.notePlaceholder"), text: $note)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(18)

            Button(action: addShift) {
                Text(settings.localized("schedule.addButton"))
                    .font(elderButtonFont)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding()
                    .background(Color(.systemTeal))
                    .foregroundColor(.white)
                    .cornerRadius(16)
            }
            .disabled(isAddShiftBlocked)

            if let blockMsg = scheduleManager.assignmentBlockedMessage {
                Text(blockMsg)
                    .font(settings.scaledFont(12))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
    }

    /// Block the Add button only when a real caregiver is picked and they
    /// are over the weekly assignment cap. "Not assigned" shifts have no
    /// caregiver to cap, so the button stays enabled.
    private var isAddShiftBlocked: Bool {
        guard let caregiver = selectedCaregiver else { return false }
        return scheduleManager.isAssigneeBlocked(caregiver.name, for: startDate)
    }

    private var shiftList: some View {
        VStack(spacing: 18) {
            // Range picker — lets the user widen the bottom shift list
            // beyond the currently selected day (Today only / 1 week /
            // 1 month / 1 year / All), so newly added or recurring shifts
            // on future dates are easy to find without scrolling the
            // calendar to each date individually.
            VStack(alignment: .leading, spacing: 8) {
                Text(settings.localized("schedule.filter.title"))
                    .font(settings.scaledFont(14, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker(settings.localized("schedule.filter.title"),
                       selection: $shiftListFilter) {
                    ForEach(ShiftListFilter.allCases) { option in
                        Text(settings.localized(option.titleKey)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)

            let displayed = filteredShifts(filter: shiftListFilter)

            // Heading shows the active range so the user knows what they're
            // looking at.
            HStack {
                Text(filterSummary(for: shiftListFilter, count: displayed.count))
                    .font(settings.scaledFont(14, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if displayed.isEmpty {
                Text(settings.localized("schedule.noTasks"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(18)
            } else {
                ForEach(displayed) { shift in
                    shiftCard(for: shift)
                }
            }
        }
    }

    /// Returns shifts that fall inside the requested range, sorted by start.
    /// For `.selectedDay` the anchor is the selected calendar date so the
    /// existing day-picker workflow still works. For the wider ranges the
    /// anchor is *today* (real-world today) so the user immediately sees
    /// upcoming shifts without first hunting through the calendar.
    private func filteredShifts(filter: ShiftListFilter) -> [Shift] {
        let all = scheduleManager.shifts.sorted { $0.start < $1.start }
        let cal = Calendar.current
        switch filter {
        case .selectedDay:
            return all.filter { cal.isDate($0.start, inSameDayAs: selectedDate) }
        case .week:
            let startOfToday = cal.startOfDay(for: Date())
            guard let horizon = cal.date(byAdding: .day, value: 7, to: startOfToday) else { return all }
            return all.filter { $0.start >= startOfToday && $0.start < horizon }
        case .month:
            let startOfToday = cal.startOfDay(for: Date())
            guard let horizon = cal.date(byAdding: .day, value: 30, to: startOfToday) else { return all }
            return all.filter { $0.start >= startOfToday && $0.start < horizon }
        case .year:
            let startOfToday = cal.startOfDay(for: Date())
            guard let horizon = cal.date(byAdding: .day, value: 365, to: startOfToday) else { return all }
            return all.filter { $0.start >= startOfToday && $0.start < horizon }
        case .all:
            return all
        }
    }

    private func filterSummary(for filter: ShiftListFilter, count: Int) -> String {
        let label = settings.localized(filter.titleKey)
        let template = settings.localized("schedule.filter.countTemplate")
        return String(format: template, label, count)
    }

    private func shiftCard(for shift: Shift) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Text(shift.status.displayName)
                    .font(elderCaptionFont.weight(.bold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(shift.status.color.opacity(0.18))
                    .foregroundColor(shift.status.color)
                    .cornerRadius(12)
            }
            HStack(alignment: .top, spacing: 12) {
                Label(shift.assignee, systemImage: "person.fill")
                Spacer()
                Label(shift.taskSummary, systemImage: "list.bullet.rectangle")
            }
            .font(settings.scaledFont(20, weight: .semibold))
            Text("\(settings.localized("schedule.timeLabel"))\(formattedDate(shift.start)) ~ \(formattedDate(shift.end))")
                .font(.body)
                .foregroundColor(.secondary)
                .lineSpacing(6)
            if !shift.note.isEmpty {
                Text("\(settings.localized("schedule.noteLabel"))\(shift.note)")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineSpacing(6)
            }
            if !shift.contactEmail.isEmpty || !shift.contactPhone.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !shift.contactEmail.isEmpty {
                        Label("\(settings.localized("schedule.emailLabel"))\(shift.contactEmail)", systemImage: "envelope.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !shift.contactPhone.isEmpty {
                        Label("\(settings.localized("schedule.phoneLabel"))\(shift.contactPhone)", systemImage: "phone.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Text(shift.signedIn ? settings.localized("schedule.signedIn") : settings.localized("schedule.notSignedIn"))
                .font(.caption)
                .foregroundColor(shift.signedIn ? .green : .orange)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background((shift.signedIn ? Color(.systemGreen) : Color(.systemOrange)).opacity(0.12))
                .cornerRadius(10)

            HStack(spacing: 12) {
                Button(action: {
                    scheduleManager.updateShiftStatus(shift, to: .completed)
                    showCompletionThankYou()
                }) {
                    Text(settings.localized("schedule.complete"))
                        .font(elderBodyFont)
                        .padding(12)
                        .background(Color(.systemGreen).opacity(0.14))
                        .cornerRadius(12)
                }
                Button(action: {
                    if shift.signedIn {
                        scheduleManager.signOutShift(shift)
                    } else {
                        scheduleManager.signInShift(shift)
                    }
                }) {
                    Text(shift.signedIn ? settings.localized("schedule.cancelSignIn") : settings.localized("schedule.signIn"))
                        .font(elderBodyFont)
                        .padding(12)
                        .background(shift.signedIn ? Color(.systemGray3).opacity(0.14) : Color(.systemBlue).opacity(0.14))
                        .cornerRadius(12)
                }
                if shift.status == .unassigned {
                    Button(action: { editShift(shift) }) {
                        Text(settings.localized("schedule.selectPrimaryCaregiver"))
                            .font(elderBodyFont)
                            .padding(12)
                            .background(Color(.systemBlue).opacity(0.14))
                            .cornerRadius(12)
                    }
                } else {
                    Button(action: { scheduleManager.updateShiftStatus(shift, to: .assigned) }) {
                        Text(settings.localized("schedule.assign"))
                            .font(elderBodyFont)
                            .padding(12)
                            .background(Color(.systemBlue).opacity(0.14))
                            .cornerRadius(12)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(action: { editShift(shift) }) {
                    Text(settings.localized("schedule.editTask"))
                        .font(elderBodyFont)
                        .padding(12)
                        .background(Color(.systemIndigo).opacity(0.14))
                        .cornerRadius(12)
                }
                Button(action: { confirmDeleteShift = shift }) {
                    Text(settings.localized("schedule.delete"))
                        .font(elderBodyFont)
                        .padding(12)
                        .background(Color(.systemRed).opacity(0.14))
                        .cornerRadius(12)
                }
            }
            if !shift.contactEmail.isEmpty || !shift.contactPhone.isEmpty {
                HStack(spacing: 12) {
                    if !shift.contactEmail.isEmpty {
                        Button(action: { sendEmailReminder(for: shift) }) {
                            Text(settings.localized("schedule.sendEmail"))
                                .font(elderBodyFont)
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemBlue).opacity(0.14))
                                .cornerRadius(12)
                        }
                    }
                    if !shift.contactPhone.isEmpty {
                        Button(action: { sendSMSReminder(for: shift) }) {
                            Text(settings.localized("schedule.sendSMS"))
                                .font(elderBodyFont)
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemGreen).opacity(0.14))
                                .cornerRadius(12)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 6)
    }

    private func addShift() {
        // If the picker is on "Not assigned", create the shift with the
        // .unassigned status (and a placeholder assignee label) so the
        // schedule board / home page flag it as pending follow-up.
        let isUnassigned = selectedCaregiverId == nil
        let resolvedAssignee = isUnassigned
            ? settings.localized("schedule.unspecifiedAssignee")
            : (assignee.isEmpty ? settings.localized("schedule.unspecifiedAssignee") : assignee)
        let resolvedStatus: ShiftStatus = isUnassigned ? .unassigned : .assigned

        let baseShift = Shift(assignee: resolvedAssignee,
                              start: startDate,
                              end: endDate,
                              taskSummary: taskSummary.isEmpty ? settings.localized("schedule.emptyTaskSummary") : taskSummary,
                              status: resolvedStatus,
                              note: note,
                              contactEmail: isUnassigned ? "" : contactEmail,
                              contactPhone: isUnassigned ? "" : contactPhone)

        let shiftsToAdd = createRecurringShifts(for: baseShift, recurrence: recurrenceOption)
        shiftsToAdd.forEach { shift in
            scheduleManager.addShift(shift)
            // Only schedule reminders for shifts that actually have an
            // assignee with contact info.
            if !isUnassigned {
                scheduleAutoReminder(for: shift)
            }
        }

        taskSummary = ""
        note = ""
        recurrenceOption = .none
        // Reset the caregiver picker back to "Not assigned" so the form
        // is clean for the next entry; keep contactEmail/contactPhone in
        // sync via applySelectedCaregiver().
        selectedCaregiverId = nil
        applySelectedCaregiver()
    }

    private func createRecurringShifts(for baseShift: Shift, recurrence: RecurrenceOption) -> [Shift] {
        guard recurrence != .none else { return [baseShift] }

        let calendar = Calendar.current
        let duration = baseShift.end.timeIntervalSince(baseShift.start)
        let occurrences: [Date]

        switch recurrence {
        case .daily:
            occurrences = (1...30).compactMap { calendar.date(byAdding: .day, value: $0, to: baseShift.start) }
        case .monthly:
            occurrences = (1...11).compactMap { calendar.date(byAdding: .month, value: $0, to: baseShift.start) }
        case .yearly:
            occurrences = (1...2).compactMap { calendar.date(byAdding: .year, value: $0, to: baseShift.start) }
        case .none:
            occurrences = []
        }

        var shifts = [baseShift]
        for start in occurrences {
            let end = start.addingTimeInterval(duration)
            let repeatedShift = Shift(assignee: baseShift.assignee,
                                     start: start,
                                     end: end,
                                     taskSummary: baseShift.taskSummary,
                                     status: baseShift.status,
                                     note: baseShift.note,
                                     contactEmail: baseShift.contactEmail,
                                     contactPhone: baseShift.contactPhone)
            shifts.append(repeatedShift)
        }
        return shifts
    }

    private func editShift(_ shift: Shift) {
        editingShift = shift
        editAssignee = shift.assignee
        editTaskSummary = shift.taskSummary
        editNote = shift.note
        editContactEmail = shift.contactEmail
        editContactPhone = shift.contactPhone
        editStartDate = shift.start
        editEndDate = shift.end
        editSelectedCaregiverId = scheduleManager.caregivers.first(where: { $0.name == shift.assignee && $0.email == shift.contactEmail && $0.phone == shift.contactPhone })?.id
    }

    private func saveEditedShift() {
        guard var shift = editingShift else { return }
        shift.assignee = editAssignee.isEmpty ? settings.localized("schedule.unspecifiedAssignee") : editAssignee
        shift.start = editStartDate
        shift.end = editEndDate
        shift.taskSummary = editTaskSummary.isEmpty ? settings.localized("schedule.emptyTaskSummary") : editTaskSummary
        shift.note = editNote
        shift.contactEmail = editContactEmail
        shift.contactPhone = editContactPhone
        scheduleManager.updateShift(shift)
        scheduleAutoReminder(for: shift)
        editingShift = nil
    }

    private func resetCaregiverEditor() {
        caregiverEditor = nil
        caregiverName = ""
        caregiverEmailField = ""
        caregiverPhoneField = ""
    }

    private func openCaregiverEditor(_ caregiver: Caregiver? = nil) {
        caregiverEditor = caregiver
        if let worker = caregiver {
            caregiverName = worker.name
            caregiverEmailField = worker.email
            caregiverPhoneField = worker.phone
        } else {
            resetCaregiverEditor()
        }
    }

    private func saveCaregiverEntry() {
        let name = caregiverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let email = caregiverEmailField.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = caregiverPhoneField.trimmingCharacters(in: .whitespacesAndNewlines)

        if var edited = caregiverEditor {
            edited.name = name
            edited.email = email
            edited.phone = phone
            scheduleManager.updateCaregiver(edited)
        } else {
            let newCaregiver = Caregiver(name: name, email: email, phone: phone)
            scheduleManager.addCaregiver(newCaregiver)
        }

        resetCaregiverEditor()
    }

    private func deleteCaregiverEntry(_ caregiver: Caregiver) {
        scheduleManager.deleteCaregiver(caregiver)
        if selectedCaregiverId == caregiver.id {
            selectedCaregiverId = nil
        }
    }

    private var caregiverManagerSheet: some View {
        NavigationView {
            List {
                Section(header: Text(settings.localized("schedule.manageCaregivers"))) {
                    if scheduleManager.caregivers.isEmpty {
                        Text(settings.localized("home.noCaregivers"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(scheduleManager.caregivers) { caregiver in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(caregiver.name)
                                    .font(settings.scaledFont(16, weight: .semibold))
                                if !caregiver.email.isEmpty {
                                    Text("\(settings.localized("schedule.emailLabel"))\(caregiver.email)")
                                        .font(settings.scaledFont(13))
                                        .foregroundColor(.secondary)
                                }
                                if !caregiver.phone.isEmpty {
                                    Text("\(settings.localized("schedule.phoneLabel"))\(caregiver.phone)")
                                        .font(settings.scaledFont(13))
                                        .foregroundColor(.secondary)
                                }
                                HStack {
                                    Button(settings.localized("home.edit")) {
                                        openCaregiverEditor(caregiver)
                                    }
                                    .font(settings.scaledFont(14, weight: .semibold))
                                    Spacer()
                                    Button(settings.localized("schedule.delete")) {
                                        deleteCaregiverEntry(caregiver)
                                    }
                                    .foregroundColor(.red)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }

                Section(header: Text(caregiverEditor == nil ? settings.localized("home.addCaregiver") : settings.localized("home.edit"))) {
                    TextField(settings.localized("home.caregiverName"), text: $caregiverName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    TextField(settings.localized("schedule.emailPlaceholder"), text: $caregiverEmailField)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    TextField(settings.localized("schedule.phonePlaceholder"), text: $caregiverPhoneField)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(caregiverEditor == nil ? settings.localized("home.addCaregiver") : settings.localized("home.save")) {
                        saveCaregiverEntry()
                    }
                    .disabled(caregiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(settings.localized("schedule.manageCaregivers"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.localized("schedule.close")) {
                        showCaregiverManager = false
                        resetCaregiverEditor()
                    }
                }
            }
        }
    }

    private func exportShiftsToCalendar() {
        eventKitManager.exportShiftsToCalendar(scheduleManager.shifts) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    exportAlertMessage = settings.localized("schedule.exportSuccess")
                case .failure(let error):
                    exportAlertMessage = String(format: settings.localized("schedule.exportFailure"), error.localizedDescription)
                }
                showExportAlert = true
            }
        }
    }

    private func notifyBackupSupport() {
        // Show a sheet with the local file link so user can choose to open or copy it
        showHomecareLink = true

        CareNotificationManager.shared.sendLocalNotification(
            title: settings.localized("schedule.backupNotificationTitle"),
            body: settings.localized("schedule.backupNotificationBody")
        )
    }

    private func reminderBody(for shift: Shift) -> String {
        String(format: settings.localized("schedule.reminderMessage"),
               shift.taskSummary,
               formattedDate(shift.start), formattedDate(shift.end))
    }

    private func sendReminder(for shift: Shift) {
        let message = reminderBody(for: shift)
        let subject = settings.localized("schedule.reminderSubject")
        if !shift.contactEmail.isEmpty {
            sendReminderEmail(for: shift)
            if let url = mailtoURL(to: shift.contactEmail, subject: subject, body: message) {
                openURL(url)
            }
        } else if !shift.contactPhone.isEmpty, let url = smsURL(to: shift.contactPhone, body: message) {
            openURL(url)
        }
    }

    private func sendEmailReminder(for shift: Shift) {
        sendReminderEmail(for: shift)
        let message = reminderBody(for: shift)
        let subject = settings.localized("schedule.reminderSubject")
        if let url = mailtoURL(to: shift.contactEmail, subject: subject, body: message) {
            openURL(url)
        }
    }

    private func sendSMSReminder(for shift: Shift) {
        let message = reminderBody(for: shift)
        if !shift.contactPhone.isEmpty, let url = smsURL(to: shift.contactPhone, body: message) {
            openURL(url)
        }
    }

    private func scheduleShareText() -> String {
        let shifts = scheduleManager.shifts
        guard !shifts.isEmpty else { return settings.localized("schedule.shareEmpty") }
        let fmt = settings.localized("schedule.shareFormat")
        let lines = shifts.map { shift in
            String(format: fmt, shift.assignee, formattedDate(shift.start), formattedDate(shift.end), shift.taskSummary, shift.note, shift.contactEmail, shift.contactPhone)
        }
        return "\(settings.localized("schedule.shareTitle"))\n\n" + lines.joined(separator: "\n\n")
    }

    private func mailtoURL(to recipient: String, subject: String, body: String) -> URL? {
        let encodedRecipient = recipient.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? recipient
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(encodedRecipient)?subject=\(encodedSubject)&body=\(encodedBody)")
    }

    private func sendReminderEmail(for shift: Shift) {
        guard !shift.contactEmail.isEmpty else { return }
        let message = reminderBody(for: shift)
        let subject = settings.localized("schedule.reminderSubject")

        var components = URLComponents(string: Setting.shared.appScriptUrl)
        components?.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: "email_reminder"),
            URLQueryItem(name: "recipient", value: shift.contactEmail),
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: message),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]

        guard let url = components?.url else { return }

        URLSession.shared.dataTask(with: url) { _, _, _ in
            // fire and forget; server may handle email delivery
        }.resume()
    }

    private func scheduleAutoReminder(for shift: Shift) {
        guard autoEmailReminderEnabled,
              !shift.contactEmail.isEmpty else { return }

        let reminderDate = Calendar.current.date(byAdding: .minute, value: -15, to: shift.start) ?? shift.start
        if reminderDate <= Date() {
            sendReminderEmail(for: shift)
        } else {
            CareNotificationManager.shared.scheduleLocalNotification(
                title: settings.localized("schedule.sendReminder"),
                body: String(format: settings.localized("schedule.autoReminderBody"), shift.assignee),
                triggerDate: reminderDate,
                identifier: "shift-reminder-\(shift.id.uuidString)"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + reminderDate.timeIntervalSinceNow) {
                sendReminderEmail(for: shift)
            }
        }
    }

    private func scheduleAutoRemindersForUpcomingShifts() {
        guard autoEmailReminderEnabled else { return }
        let now = Date()
        for shift in scheduleManager.shifts where !shift.contactEmail.isEmpty {
            let reminderDate = Calendar.current.date(byAdding: .minute, value: -15, to: shift.start) ?? shift.start
            if reminderDate > now {
                scheduleAutoReminder(for: shift)
            }
        }
    }

    private func smsURL(to phone: String, body: String) -> URL? {
        let encodedPhone = phone.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? phone
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "sms:\(encodedPhone)?body=\(encodedBody)")
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatWindow(_ window: CareWindow) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: Date(timeIntervalSinceReferenceDate: window.startTime))
        let end: String
        if window.endTime >= 24 * 3600 {
            end = "24:00"
        } else {
            end = formatter.string(from: Date(timeIntervalSinceReferenceDate: window.endTime))
        }
        return "\(start) ~ \(end)"
    }

    private var dailyScheduleSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.localized("schedule.dailyScheduleTitle"))
                .font(settings.scaledFont(16, weight: .semibold))
            if !scheduleManager.dailyCareWindows.isEmpty {
                Text(String(format: settings.localized("schedule.dailyCareWindowsLabel"), scheduleManager.dailyCareWindows.map(formatWindow).joined(separator: ", ")))
                    .font(settings.scaledFont(13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    private var thresholdReminderBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(.systemBlue).opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "bell.fill")
                        .foregroundColor(Color(.systemBlue))
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.localized("schedule.thresholdReminderTitle"))
                        .font(settings.scaledFont(16, weight: .semibold))

                    Text(String(format: settings.localized("schedule.thresholdReminderText"), settings.weeklyReminderThreshold, settings.scheduleWarningThreshold, settings.weeklyBanThreshold))
                        .font(settings.scaledFont(13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .background(Color(.systemTeal).opacity(0.14))
        .cornerRadius(16)
    }


    
    private func shifts(on date: Date) -> [Shift] {
        scheduleManager.shifts
            .filter { calendar.isDate($0.start, inSameDayAs: date) }
            .sorted { $0.start < $1.start }
    }

    private func loadMeasurementsForSelectedDate() {
        let key = isoDate(selectedDate)
        // Prefer measurements stored in CareScheduleManager (schedule-level storage)
        let persisted = scheduleManager.measurement(for: selectedDate) ?? healthManager.measurement(for: selectedDate)

        var storedTemp = persisted?.temp
        var storedSpo2 = persisted?.spo2
        var storedSys = persisted?.sys
        var storedDia = persisted?.dia

        // If selected date is today, prefer recent BLE device readings when available
        let todayKey = isoDate(Date())
        if key == todayKey {
            if let t = ble.iredDeviceData.thermometerData.data.temperature {
                storedTemp = t
            }
            if let s = ble.iredDeviceData.oximeterData.data.spo2 {
                storedSpo2 = Double(s) / 100.0
            }
            if let syst = ble.iredDeviceData.sphygmometerData.data.systolic {
                storedSys = Double(syst)
            }
            if let dias = ble.iredDeviceData.sphygmometerData.data.diastolic {
                storedDia = Double(dias)
            }
        }

        measurementsByDate[key] = (temp: storedTemp, spo2: storedSpo2, sys: storedSys, dia: storedDia)

        healthManager.fetchMeasurements(for: selectedDate) { temp, spo2, sys, dia in
            DispatchQueue.main.async {
                let latestTemp = storedTemp ?? temp
                let latestSpo2 = storedSpo2 ?? spo2
                let latestSys = storedSys ?? sys
                let latestDia = storedDia ?? dia

                measurementsByDate[key] = (temp: latestTemp, spo2: latestSpo2, sys: latestSys, dia: latestDia)
            }
        }
    }

    private func isoDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

struct ScheduleBoardView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ScheduleBoardView()
                .environmentObject(AppSettings.shared)
        }
    }
}
