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
                        let isProblematic = !isPastDate && scheduleManager.checkDateHasIssue(date)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        Button(action: {
                            guard !isPastDate else { return }
                            selectedDate = date
                            onDateSelected()

                            let calendar = Calendar.current
                            if let newStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date) {
                                startDate = newStart
                                endDate = calendar.date(byAdding: .hour, value: 6, to: newStart) ?? newStart
                            } else {
                                startDate = date
                                endDate = calendar.date(byAdding: .hour, value: 6, to: date) ?? date
                            }
                        }) {
                            Text("\(day)")
                                .font(elderBodyFont)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(isProblematic ? Color(.systemRed).opacity(0.7) : (isSelected ? Color(.systemBlue).opacity(0.2) : Color.clear))
                                .foregroundColor(!isPastDate ? (isProblematic ? .white : .primary) : .secondary)
                                .cornerRadius(8)
                        }
                        .disabled(isPastDate)
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

    private func formatMonthYear(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = Locale(identifier: "zh_TW")
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
