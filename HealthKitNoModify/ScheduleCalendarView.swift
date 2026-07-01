import SwiftUI

/// Monthly calendar + per-day measurement/shift summary.
///
/// Extracted from `ScheduleBoardView` so the main view file stays manageable.
/// Takes bindings to the dates owned by the parent and a callback the parent
/// uses to refresh measurements when the user picks a new date.
struct ScheduleCalendarView: View {
    typealias DailyMeasurementTuple = (temp: Double?, spo2: Double?, sys: Double?, dia: Double?)

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var scheduleManager = CareScheduleManager.shared

    @Binding var selectedDate: Date
    @Binding var startDate: Date
    @Binding var endDate: Date
    let measurementsByDate: [String: DailyMeasurementTuple]
    let onDateSelected: () -> Void

    // Elder-friendly fonts (matched to ScheduleBoardView's own elder fonts)
    private var elderTitleFont: Font { settings.scaledFont(22, weight: .bold) }
    private var elderBodyFont: Font { settings.scaledFont(18) }
    private var elderCaptionFont: Font { settings.scaledFont(16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.localized("schedule.calendar"))
                .font(settings.scaledFont(16, weight: .semibold))

            VStack(spacing: 12) {
                HStack {
                    Button(action: {
                        selectedDate = Calendar.current.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate
                    }) {
                        Image(systemName: "chevron.left")
                            .frame(width: 32, height: 32)
                    }

                    Spacer()

                    Text(formatMonthYear(selectedDate))
                        .font(settings.scaledFont(16, weight: .semibold))

                    Spacer()

                    Button(action: {
                        selectedDate = Calendar.current.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate
                    }) {
                        Image(systemName: "chevron.right")
                            .frame(width: 32, height: 32)
                    }
                }

                // Prominent "selected date" banner so the user always sees
                // which day the lists below are tied to.
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundColor(.accentColor)
                    Text(settings.localized("schedule.selectedDateLabel"))
                        .font(elderCaptionFont)
                        .foregroundColor(.secondary)
                    Text(formatLongDate(selectedDate))
                        .font(settings.scaledFont(17, weight: .semibold))
                        .foregroundColor(.primary)
                    if Calendar.current.isDate(selectedDate, inSameDayAs: Date()) {
                        Text(settings.localized("schedule.todayBadge"))
                            .font(settings.scaledFont(12, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.18))
                            .foregroundColor(.accentColor)
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemBackground))
                )

                // Weekly overbooked reminders (top-right)
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        let overbooked = scheduleManager.getWeeklyOverbookedAssignees(for: selectedDate)
                        if !Calendar.current.isDate(selectedDate, inSameDayAs: Date()),
                           selectedDate < Calendar.current.startOfDay(for: Date()) {
                            EmptyView()
                        } else {
                            ForEach(Array(overbooked.keys).sorted(), id: \.self) { name in
                                if let count = overbooked[name] {
                                    Text(String(format: settings.localized("schedule.overbookedWarning"), name, count))
                                        .font(settings.scaledFont(11))
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Color(.systemOrange))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                }

                let days = [
                    settings.localized("schedule.weekday.sun"),
                    settings.localized("schedule.weekday.mon"),
                    settings.localized("schedule.weekday.tue"),
                    settings.localized("schedule.weekday.wed"),
                    settings.localized("schedule.weekday.thu"),
                    settings.localized("schedule.weekday.fri"),
                    settings.localized("schedule.weekday.sat")
                ]
                HStack {
                    ForEach(days, id: \.self) { day in
                        Text(day)
                            .font(elderCaptionFont)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.secondary)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                    let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: selectedDate)) ?? selectedDate
                    let range = Calendar.current.range(of: .day, in: .month, for: selectedDate)!
                    let numDays = range.count
                    let firstWeekday = Calendar.current.component(.weekday, from: startOfMonth) - 1

                    ForEach(0..<firstWeekday, id: \.self) { _ in
                        Text("")
                            .frame(height: 40)
                    }

                    ForEach(1...numDays, id: \.self) { day in
                        let date = Calendar.current.date(byAdding: .day, value: day - 1, to: startOfMonth) ?? startOfMonth
                        let today = Calendar.current.startOfDay(for: Date())
                        let isPastDate = date < today
                        let isToday = Calendar.current.isDate(date, inSameDayAs: Date())
                        // Past days never raise the red "problematic" flag —
                        // they're history, not actionable.
                        let isProblematic = !isPastDate && scheduleManager.checkDateHasIssue(date)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        // Tick mark when every shift on that day is completed —
                        // gives the user a positive "done" signal for past
                        // (and current) days where care actually wrapped up.
                        let isAllDone = scheduleManager.allShiftsCompleted(on: date)
                        Button(action: {
                            // Past dates are now selectable so the user can
                            // review history; only future-creation behaviour
                            // (setting `startDate` / `endDate` to that day at
                            // 8am) is skipped for past picks.
                            selectedDate = date
                            onDateSelected()

                            if !isPastDate {
                                let calendar = Calendar.current
                                if let newStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date) {
                                    startDate = newStart
                                    endDate = calendar.date(byAdding: .hour, value: 6, to: newStart) ?? newStart
                                } else {
                                    startDate = date
                                    endDate = calendar.date(byAdding: .hour, value: 6, to: date) ?? date
                                }
                            }
                        }) {
                            ZStack(alignment: .topTrailing) {
                                Text("\(day)")
                                    .font(elderBodyFont)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(
                                        Group {
                                            if isProblematic {
                                                Color(.systemRed).opacity(0.7)
                                            } else if isSelected {
                                                Color(.systemBlue).opacity(0.25)
                                            } else if isToday {
                                                Color(.systemBlue).opacity(0.08)
                                            } else {
                                                Color.clear
                                            }
                                        }
                                    )
                                    .foregroundColor(
                                        isProblematic ? .white :
                                        (isPastDate ? .secondary : .primary)
                                    )
                                    .cornerRadius(8)
                                    .overlay(
                                        // Strong ring on the selected cell so
                                        // the current pick is obvious even at
                                        // a glance.
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isSelected ? Color(.systemBlue) : Color.clear,
                                                    lineWidth: 2.5)
                                    )

                                if isAllDone {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.green)
                                        .background(
                                            Circle()
                                                .fill(Color(.systemBackground))
                                                .frame(width: 14, height: 14)
                                        )
                                        .padding(2)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(settings.localized("schedule.todayMeasurements"))
                        .font(elderTitleFont)

                    let key = isoDate(selectedDate)
                    let m = measurementsByDate[key]

                    if let temp = m?.temp {
                        Text("\(settings.localized("schedule.temperature"))\(String(format: "%.1f", temp)) °C")
                            .font(elderBodyFont)
                    } else {
                        Text(settings.localized("schedule.noData"))
                            .font(elderBodyFont)
                            .foregroundColor(.secondary)
                    }
                    if let spo2 = m?.spo2 {
                        Text("\(settings.localized("schedule.spo2"))\(String(format: "%.0f", (spo2 * 100))) %")
                            .font(elderBodyFont)
                    } else {
                        Text(settings.localized("schedule.noData"))
                            .font(elderBodyFont)
                            .foregroundColor(.secondary)
                    }
                    if let sys = m?.sys, let dia = m?.dia {
                        Text("\(settings.localized("schedule.bloodPressureMeasurement"))\(Int(sys))/\(Int(dia)) mmHg")
                            .font(elderBodyFont)
                    } else {
                        Text(settings.localized("schedule.noData"))
                            .font(elderBodyFont)
                            .foregroundColor(.secondary)
                    }
                }
                .font(settings.scaledFont(12))
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.localized("schedule.todayShifts"))
                        .font(settings.scaledFont(14, weight: .semibold))

                    let dayShifts = shifts(on: selectedDate)
                    let uncovered = scheduleManager.getUncoveredPeriodsForDate(selectedDate)

                    if dayShifts.isEmpty {
                        Text(settings.localized("schedule.noTasks"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(dayShifts) { shift in
                            let overlappingShifts = scheduleManager.hasOverlappingShifts(for: selectedDate)
                            let isOverlapping = overlappingShifts.contains(where: { $0.id == shift.id })

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(shift.assignee)
                                        .font(settings.scaledFont(14, weight: .semibold))
                                        .foregroundColor(isOverlapping ? .red : .primary)
                                    Text("\(formattedDate(shift.start)) - \(formattedDate(shift.end))")
                                        .font(settings.scaledFont(10))
                                        .foregroundColor(isOverlapping ? Color(.systemRed) : .secondary)
                                }
                                Spacer()
                                Text(shift.taskSummary)
                                    .font(settings.scaledFont(12))
                                    .foregroundColor(isOverlapping ? .red : .secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(8)
                            .background(Color(.systemBackground))
                            .cornerRadius(10)
                        }
                    }

                    if !uncovered.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(settings.localized("schedule.unassigned.title"))
                                .font(settings.scaledFont(12, weight: .semibold))
                                .foregroundColor(.orange)
                            Text(settings.localized("schedule.unassigned.description"))
                                .font(settings.scaledFont(10))
                                .foregroundColor(.secondary)

                            ForEach(uncovered.indices, id: \.self) { index in
                                Text(formatInterval(uncovered[index]))
                                    .font(settings.scaledFont(10))
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(10)
                        .background(Color(.systemOrange).opacity(0.12))
                        .cornerRadius(10)
                    }
                }
                .font(settings.scaledFont(12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
    }

    // MARK: - Local helpers (kept private; mirror the parent's formatters
    // so this view is fully self-contained and can be edited independently).

    /// Maps the user's chosen `AppLanguage` to a matching `Locale`, so all
    /// date strings shown by the calendar follow the in-app language
    /// instead of the device system language.
    private var currentLocale: Locale {
        switch settings.language {
        case .chinese:    return Locale(identifier: "zh_TW")
        case .english:    return Locale(identifier: "en_US")
        case .indonesian: return Locale(identifier: "id_ID")
        }
    }

    private func formatMonthYear(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = currentLocale
        return formatter.string(from: date)
    }

    /// Long-form "Mon, 23 Jun 2026" style label used in the "selected date"
    /// banner above the calendar grid. Follows the in-app language.
    private func formatLongDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.locale = currentLocale
        return formatter.string(from: date)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatInterval(_ interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: interval.start)
        let end = formatter.string(from: interval.end)
        return "\(start) - \(end)"
    }

    private func isoDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private func shifts(on date: Date) -> [Shift] {
        scheduleManager.shifts
            .filter { Calendar.current.isDate($0.start, inSameDayAs: date) }
            .sorted { $0.start < $1.start }
    }
}
