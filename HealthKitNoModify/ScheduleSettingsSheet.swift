import SwiftUI

/// Settings sheet for the schedule board: weekly thresholds, daily care
/// windows, and date-specific care windows.
///
/// Extracted from `ScheduleBoardView` so the main view file stays readable
/// and so tools (and humans) can edit this independently.
struct ScheduleSettingsSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var scheduleManager = CareScheduleManager.shared
    @AppStorage("weeklyReminderThreshold") private var weeklyReminderThreshold = 5
    @AppStorage("weeklyBanThreshold") private var weeklyBanThreshold = 6
    @AppStorage("scheduleWarningThreshold") private var scheduleWarningThreshold = 3
    @AppStorage("autoEmailReminderEnabled") private var autoEmailReminderEnabled = false

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }

    var body: some View {
        Form {
            Section(header: Text(settings.localized("schedule.settings"))) {
                Toggle(isOn: $autoEmailReminderEnabled) {
                    Text(settings.localized("schedule.autoEmailReminder"))
                        .font(settings.scaledFont(16, weight: .semibold))
                }
                Text(settings.localized("schedule.autoEmailReminderHelp"))
                    .font(settings.scaledFont(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                HStack {
                    Text(settings.localized("schedule.weeklyReminderThreshold"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Spacer()
                    Text(String(format: settings.localized("schedule.thresholdDaysSuffix"), weeklyReminderThreshold))
                        .foregroundColor(.secondary)
                }
                Stepper(value: $weeklyReminderThreshold, in: 1...7) { Text("") }
                    .labelsHidden()
                Text(settings.localized("schedule.weeklyThresholdHelp"))
                    .font(settings.scaledFont(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(settings.localized("schedule.scheduleWarningThreshold"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Spacer()
                    Text(String(format: settings.localized("schedule.thresholdDaysSuffix"), scheduleWarningThreshold))
                        .foregroundColor(.secondary)
                }
                Stepper(value: $scheduleWarningThreshold, in: 1...14) { Text("") }
                    .labelsHidden()
                Text(settings.localized("schedule.scheduleWarningThresholdHelp"))
                    .font(settings.scaledFont(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(settings.localized("schedule.weeklyBanThreshold"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Spacer()
                    Text(String(format: settings.localized("schedule.thresholdDaysSuffix"), weeklyBanThreshold))
                        .foregroundColor(.secondary)
                }
                Stepper(value: $weeklyBanThreshold, in: 1...7) { Text("") }
                    .labelsHidden()
            }

            Section(header: Text(settings.localized("schedule.careHoursTitle"))) {
                Text(settings.localized("schedule.careHoursDescription"))
                    .font(settings.scaledFont(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                ForEach(scheduleManager.dailyCareWindows.indices, id: \.self) { index in
                    let window = scheduleManager.dailyCareWindows[index]
                    VStack(alignment: .leading, spacing: 8) {
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
                        DatePicker(
                            settings.localized("schedule.careStartTime"),
                            selection: Binding(
                                get: { Date(timeIntervalSinceReferenceDate: window.startTime) },
                                set: { newDate in scheduleManager.updateCareWindow(at: index, startTime: newDate.timeIntervalSinceReferenceDate) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            settings.localized("schedule.careEndTime"),
                            selection: Binding(
                                get: { Date(timeIntervalSinceReferenceDate: window.endTime) },
                                set: { newDate in scheduleManager.updateCareWindow(at: index, endTime: newDate.timeIntervalSinceReferenceDate) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                    .padding(.vertical, 6)
                }

                Button(action: { scheduleManager.addCareWindow() }) {
                    Label(settings.localized("schedule.addCareWindow"), systemImage: "plus")
                }

                if scheduleManager.dailyCareWindows.contains(where: { $0.endTime <= $0.startTime }) {
                    Text(settings.localized("schedule.careHoursInvalid"))
                        .font(settings.scaledFont(12))
                        .foregroundColor(.red)
                }
            }

            Section(header: Text(settings.localized("schedule.dateSpecificCareHoursTitle"))) {
                Text(settings.localized("schedule.dateSpecificCareHoursDescription"))
                    .font(settings.scaledFont(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                ForEach(Array(scheduleManager.dateSpecificCareWindows.enumerated()), id: \.1.id) { pair in
                    let index = pair.0
                    let window = pair.1
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(dateFormatter.string(from: window.date))
                                .font(settings.scaledFont(14, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                scheduleManager.deleteDateSpecificCareWindow(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        DatePicker(
                            settings.localized("schedule.selectDate"),
                            selection: Binding(
                                get: { window.date },
                                set: { newDate in scheduleManager.updateDateSpecificCareWindow(at: index, date: newDate) }
                            ),
                            displayedComponents: .date
                        )
                        DatePicker(
                            settings.localized("schedule.careStartTime"),
                            selection: Binding(
                                get: { Date(timeIntervalSinceReferenceDate: window.startTime) },
                                set: { newDate in scheduleManager.updateDateSpecificCareWindow(at: index, startTime: newDate.timeIntervalSinceReferenceDate) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            settings.localized("schedule.careEndTime"),
                            selection: Binding(
                                get: { Date(timeIntervalSinceReferenceDate: window.endTime) },
                                set: { newDate in scheduleManager.updateDateSpecificCareWindow(at: index, endTime: newDate.timeIntervalSinceReferenceDate) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                    .padding(.vertical, 6)
                }

                Button(action: { scheduleManager.addDateSpecificCareWindow(date: Date()) }) {
                    Label(settings.localized("schedule.addDateSpecificCareWindow"), systemImage: "plus")
                }

                if scheduleManager.dateSpecificCareWindows.contains(where: { $0.endTime <= $0.startTime }) {
                    Text(settings.localized("schedule.careHoursInvalid"))
                        .font(settings.scaledFont(12))
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle(settings.localized("schedule.settings"))
        .onAppear {
            weeklyReminderThreshold = settings.weeklyReminderThreshold
            weeklyBanThreshold = settings.weeklyBanThreshold
            scheduleWarningThreshold = settings.scheduleWarningThreshold
            autoEmailReminderEnabled = settings.autoEmailReminderEnabled
        }
        .onChange(of: weeklyReminderThreshold) { _, newValue in
            settings.weeklyReminderThreshold = newValue
        }
        .onChange(of: weeklyBanThreshold) { _, newValue in
            settings.weeklyBanThreshold = newValue
        }
        .onChange(of: scheduleWarningThreshold) { _, newValue in
            settings.scheduleWarningThreshold = newValue
        }
        .onChange(of: autoEmailReminderEnabled) { _, newValue in
            settings.autoEmailReminderEnabled = newValue
        }
    }
}
