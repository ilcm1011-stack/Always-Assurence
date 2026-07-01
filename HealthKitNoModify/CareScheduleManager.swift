import Foundation
import Combine
import SwiftUI

enum ShiftStatus: String, CaseIterable, Codable {
    // Raw values are kept in Chinese on purpose so existing persisted data
    // (UserDefaults / JSON encoded shifts) still decodes correctly. Use
    // `displayName` for anything user-facing instead of `rawValue`.
    case unassigned = "待指派"
    case assigned = "已指派"
    case completed = "已完成"

    var color: Color {
        switch self {
        case .unassigned: return .red
        case .assigned: return .blue
        case .completed: return .green
        }
    }

    /// Localized label to show in the UI. Falls back gracefully for any
    /// future case.
    var displayName: String {
        switch self {
        case .unassigned: return AppSettings.shared.localized("schedule.status.unassigned")
        case .assigned:   return AppSettings.shared.localized("schedule.status.assigned")
        case .completed:  return AppSettings.shared.localized("schedule.status.completed")
        }
    }
}

struct Shift: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var assignee: String
    var start: Date
    var end: Date
    var taskSummary: String
    var status: ShiftStatus
    var note: String
    var contactEmail: String = ""
    var contactPhone: String = ""
    var signedIn: Bool = false

    // Backwards compatibility for any previously persisted shifts that
    // included the now-removed `role` field. Decoding tolerates its
    // absence, and encoding simply omits it.
    private enum CodingKeys: String, CodingKey {
        case id, assignee, start, end, taskSummary, status, note,
             contactEmail, contactPhone, signedIn
    }
}

struct CareWindow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startTime: TimeInterval
    var endTime: TimeInterval
}

struct DateSpecificCareWindow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var startTime: TimeInterval
    var endTime: TimeInterval
}

struct Caregiver: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var email: String
    var phone: String
    /// User-pickable emoji shown next to the caregiver name in pickers and
    /// shift cards so each helper is visually distinct at a glance. Empty
    /// string means "no icon"; older persisted data without this field
    /// decodes safely thanks to `decodeIfPresent` below.
    var icon: String = ""
    var availability: [CareWindow] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, email, phone, icon, availability
    }

    init(id: UUID = UUID(),
         name: String,
         email: String,
         phone: String,
         icon: String = "",
         availability: [CareWindow] = []) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
        self.icon = icon
        self.availability = availability
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        self.phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        self.availability = try c.decodeIfPresent([CareWindow].self, forKey: .availability) ?? []
    }
}

/// Curated set of caregiver emojis used in the icon picker. Kept short so
/// the picker stays scannable, but covers the most common archetypes.
enum CaregiverIconPalette {
    static let options: [String] = [
        "👩‍⚕️", "👨‍⚕️", "🧑‍⚕️", "👵", "👴",
        "👩", "👨", "🧑", "👧", "👦",
        "🤱", "🧕", "👮", "🦸", "🐶",
        "❤️", "⭐️", "🌸", "🌟", "🩺",
    ]
}

final class CareScheduleManager: ObservableObject {
    static let shared = CareScheduleManager()

    @Published private(set) var shifts: [Shift] = []
    @Published var gapAlert: String?
    @Published var missingSignInAlert: String?
    @Published var uncoveredIntervals: [DateInterval] = []
    @Published var todayHasIssue: Bool = false
    @Published var problematicDatesNextWeek: Set<String> = []
    @Published var weeklyOverbookedAssignees: [String: Int] = [:]
    @Published var bannedAssignees: Set<String> = []
    @Published var appointmentAssignmentWarning: String? = nil
    @Published var unassignedShiftCount: Int = 0
    @Published var unassignedShiftWarning: String? = nil
    @Published var upcomingScheduleWarning: String? = nil
    @Published var upcomingUnscheduledDates: [Date] = []
    @Published var assignmentBlockedMessage: String?
    @Published var dailyMeasurements: [String: DailyMeasurement] = [:]
    @Published var caregivers: [Caregiver] = []
    @Published var dailyCareWindows: [CareWindow] = [CareWindow(startTime: 0, endTime: 24 * 3600)]
    @Published var dateSpecificCareWindows: [DateSpecificCareWindow] = []

    private var settingsCancellables = Set<AnyCancellable>()

    private let dailyMeasurementsStorageKey = "careDailyMeasurements"
    private let caregiversStorageKey = "careScheduleCaregivers"
    private let careWindowsStorageKey = "dailyCareWindows"
    private let dateSpecificCareWindowsStorageKey = "dateSpecificCareWindows"
    private let shiftsStorageKey = "careScheduleShifts"

    private init() {
        loadPersistedShifts()
        loadPersistedDailyMeasurements()
        loadPersistedCaregivers()
        loadPersistedCareWindows()
        loadPersistedDateSpecificCareWindows()
        subscribeToSettingsChanges()
        subscribeToCareWindowChanges()
        subscribeToDateSpecificCareWindowChanges()
        evaluateSchedule()
    }

    private func subscribeToSettingsChanges() {
        AppSettings.shared.$weeklyReminderThreshold
            .sink { [weak self] _ in
                self?.evaluateSchedule()
            }
            .store(in: &settingsCancellables)

        AppSettings.shared.$weeklyBanThreshold
            .sink { [weak self] _ in
                self?.evaluateSchedule()
            }
            .store(in: &settingsCancellables)

        AppSettings.shared.$scheduleWarningThreshold
            .sink { [weak self] _ in
                self?.evaluateSchedule()
            }
            .store(in: &settingsCancellables)

        // Re-evaluate when the user changes the interface language so that
        // gapAlert / missingSignInAlert / upcomingScheduleWarning / etc.
        // are recomputed in the new language.
        //
        // NOTE: @Published fires its publisher in `willSet`, BEFORE the
        // property is actually updated. If we call `evaluateSchedule()`
        // synchronously here, `AppSettings.shared.language` still holds the
        // OLD value, so `localized(_:)` returns the previous language's
        // text — causing the home-page warnings to lag by one language
        // change. Defer to the next runloop tick so the property has been
        // updated by the time we recompute the alerts.
        AppSettings.shared.$language
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.evaluateSchedule()
                }
            }
            .store(in: &settingsCancellables)
    }

    private func subscribeToCareWindowChanges() {
        $dailyCareWindows
            .sink { [weak self] _ in
                self?.savePersistedCareWindows()
                self?.evaluateSchedule()
            }
            .store(in: &settingsCancellables)
    }

    private func subscribeToDateSpecificCareWindowChanges() {
        $dateSpecificCareWindows
            .sink { [weak self] _ in
                self?.savePersistedDateSpecificCareWindows()
                self?.evaluateSchedule()
            }
            .store(in: &settingsCancellables)
    }

    private func loadPersistedShifts() {
        guard let data = UserDefaults.standard.data(forKey: shiftsStorageKey) else {
            shifts = initialShifts()
            return
        }
        if let decoded = try? JSONDecoder().decode([Shift].self, from: data) {
            shifts = decoded
        } else {
            shifts = initialShifts()
        }
    }

    private func savePersistedShifts() {
        if let data = try? JSONEncoder().encode(shifts) {
            UserDefaults.standard.set(data, forKey: shiftsStorageKey)
        }
    }

    func reloadShifts() {
        loadPersistedShifts()
        evaluateSchedule()
    }

    private func loadPersistedCareWindows() {
        guard let data = UserDefaults.standard.data(forKey: careWindowsStorageKey) else {
            return
        }
        if let decoded = try? JSONDecoder().decode([CareWindow].self, from: data), !decoded.isEmpty {
            dailyCareWindows = decoded
        }
    }

    private func savePersistedCareWindows() {
        if let data = try? JSONEncoder().encode(dailyCareWindows) {
            UserDefaults.standard.set(data, forKey: careWindowsStorageKey)
        }
    }

    private func loadPersistedDateSpecificCareWindows() {
        guard let data = UserDefaults.standard.data(forKey: dateSpecificCareWindowsStorageKey) else {
            dateSpecificCareWindows = []
            return
        }
        if let decoded = try? JSONDecoder().decode([DateSpecificCareWindow].self, from: data) {
            dateSpecificCareWindows = decoded
        }
    }

    private func savePersistedDateSpecificCareWindows() {
        if let data = try? JSONEncoder().encode(dateSpecificCareWindows) {
            UserDefaults.standard.set(data, forKey: dateSpecificCareWindowsStorageKey)
        }
    }

    struct DailyMeasurement: Codable {
        let temperature: Double?
        let oxygenSaturation: Double?
        let systolicPressure: Double?
        let diastolicPressure: Double?
        let recordedAt: Date
    }

    func setDailyMeasurement(for date: Date,
                             temperature: Double? = nil,
                             oxygenSaturation: Double? = nil,
                             systolicPressure: Double? = nil,
                             diastolicPressure: Double? = nil) {
        let key = isoDate(date)
        let existing = dailyMeasurements[key]
        let measurement = DailyMeasurement(
            temperature: temperature ?? existing?.temperature,
            oxygenSaturation: oxygenSaturation ?? existing?.oxygenSaturation,
            systolicPressure: systolicPressure ?? existing?.systolicPressure,
            diastolicPressure: diastolicPressure ?? existing?.diastolicPressure,
            recordedAt: Date()
        )
        dailyMeasurements[key] = measurement
        savePersistedDailyMeasurements()
    }

    func measurement(for date: Date) -> (temp: Double?, spo2: Double?, sys: Double?, dia: Double?)? {
        guard let m = dailyMeasurements[isoDate(date)] else { return nil }
        return (m.temperature, m.oxygenSaturation, m.systolicPressure, m.diastolicPressure)
    }

    private func loadPersistedDailyMeasurements() {
        guard let data = UserDefaults.standard.data(forKey: dailyMeasurementsStorageKey) else {
            dailyMeasurements = [:]
            return
        }
        if let decoded = try? JSONDecoder().decode([String: DailyMeasurement].self, from: data) {
            dailyMeasurements = decoded
        }
    }

    private func savePersistedDailyMeasurements() {
        if let data = try? JSONEncoder().encode(dailyMeasurements) {
            UserDefaults.standard.set(data, forKey: dailyMeasurementsStorageKey)
        }
    }

    private func loadPersistedCaregivers() {
        guard let data = UserDefaults.standard.data(forKey: caregiversStorageKey) else {
            // First launch — seed the caregiver list with sample data so the
            // demo has someone to assign shifts to right away.
            caregivers = initialCaregivers()
            savePersistedCaregivers()
            return
        }
        if let decoded = try? JSONDecoder().decode([Caregiver].self, from: data) {
            caregivers = decoded
        }
    }

    /// Sample caregivers used the first time the app launches so the demo
    /// has realistic contact data prepopulated. Kept in sync with the
    /// sample shifts in `initialShifts()`.
    private func initialCaregivers() -> [Caregiver] {
        [
            Caregiver(name: "印尼看護",
                      email: "secdcs01@ctshkpcc.edu.hk",
                      phone: "+852 98765430",
                      icon: "🧕"),
            Caregiver(name: "大兒子",
                      email: "secdcs02@ctshkpcc.edu.hk",
                      phone: "+852 98765431",
                      icon: "👨"),
        ]
    }

    private func savePersistedCaregivers() {
        if let data = try? JSONEncoder().encode(caregivers) {
            UserDefaults.standard.set(data, forKey: caregiversStorageKey)
        }
    }

    func addCaregiver(_ caregiver: Caregiver) {
        caregivers.append(caregiver)
        savePersistedCaregivers()
    }

    func updateCaregiver(_ caregiver: Caregiver) {
        if let index = caregivers.firstIndex(where: { $0.id == caregiver.id }) {
            caregivers[index] = caregiver
            savePersistedCaregivers()
        }
    }

    func deleteCaregiver(_ caregiver: Caregiver) {
        caregivers.removeAll { $0.id == caregiver.id }
        savePersistedCaregivers()
    }

    func addCareWindow(startTime: TimeInterval? = nil, endTime: TimeInterval? = nil) {
        let nextStart = startTime ?? (dailyCareWindows.last?.endTime ?? 20 * 3600)
        let newStart = min(nextStart, 22 * 3600)
        let newEnd = endTime ?? min(newStart + 2 * 3600, 23 * 3600)
        dailyCareWindows.append(CareWindow(startTime: newStart, endTime: newEnd))
        savePersistedCareWindows()
        evaluateSchedule()
    }

    func updateCareWindow(at index: Int, startTime: TimeInterval? = nil, endTime: TimeInterval? = nil) {
        guard dailyCareWindows.indices.contains(index) else { return }
        var window = dailyCareWindows[index]
        if let startTime = startTime {
            window.startTime = startTime
        }
        if let endTime = endTime {
            window.endTime = endTime
        }
        dailyCareWindows[index] = window
        savePersistedCareWindows()
        evaluateSchedule()
    }

    func deleteCareWindow(at index: Int) {
        guard dailyCareWindows.indices.contains(index), dailyCareWindows.count > 1 else { return }
        dailyCareWindows.remove(at: index)
        savePersistedCareWindows()
        evaluateSchedule()
    }

    func addDateSpecificCareWindow(date: Date, startTime: TimeInterval? = nil, endTime: TimeInterval? = nil) {
        let newStart = startTime ?? (8 * 3600)
        let newEnd = endTime ?? (20 * 3600)
        dateSpecificCareWindows.append(DateSpecificCareWindow(date: date, startTime: newStart, endTime: newEnd))
        savePersistedDateSpecificCareWindows()
        evaluateSchedule()
    }

    func updateDateSpecificCareWindow(at index: Int, date: Date? = nil, startTime: TimeInterval? = nil, endTime: TimeInterval? = nil) {
        guard dateSpecificCareWindows.indices.contains(index) else { return }
        var window = dateSpecificCareWindows[index]
        if let date = date {
            window.date = date
        }
        if let startTime = startTime {
            window.startTime = startTime
        }
        if let endTime = endTime {
            window.endTime = endTime
        }
        dateSpecificCareWindows[index] = window
        savePersistedDateSpecificCareWindows()
        evaluateSchedule()
    }

    func deleteDateSpecificCareWindow(at index: Int) {
        guard dateSpecificCareWindows.indices.contains(index) else { return }
        dateSpecificCareWindows.remove(at: index)
        savePersistedDateSpecificCareWindows()
        evaluateSchedule()
    }

    func addShift(_ shift: Shift) {
        // prevent adding if assignee is blocked for the week of the shift
        if isAssigneeBlocked(shift.assignee, for: shift.start) {
            let template = AppSettings.shared.localized("schedule.assignmentBlockedMessage")
            assignmentBlockedMessage = String(format: template, shift.assignee, AppSettings.shared.weeklyBanThreshold)
            return
        }

        assignmentBlockedMessage = nil
        shifts.append(shift)
        savePersistedShifts()
        evaluateSchedule()
    }

    func updateShift(_ shift: Shift) {
        guard let index = indexOfShift(shift) else { return }
        shifts[index] = shift
        savePersistedShifts()
        evaluateSchedule()
    }

    func updateShiftStatus(_ shift: Shift, to status: ShiftStatus) {
        guard let index = indexOfShift(shift) else { return }
        shifts[index].status = status
        savePersistedShifts()
        evaluateSchedule()
    }

    func signInShift(_ shift: Shift) {
        guard let index = indexOfShift(shift) else { return }
        shifts[index].signedIn = true
        savePersistedShifts()
        evaluateSchedule()
    }

    func signOutShift(_ shift: Shift) {
        guard let index = indexOfShift(shift) else { return }
        shifts[index].signedIn = false
        savePersistedShifts()
        evaluateSchedule()
    }

    func deleteShift(_ shift: Shift) {
        shifts.removeAll { $0.id == shift.id }
        savePersistedShifts()
        evaluateSchedule()
    }

    private func indexOfShift(_ shift: Shift) -> Int? {
        shifts.firstIndex { $0.id == shift.id }
    }

    private func evaluateSchedule() {
        let now = Date()
        let windowEnd = Calendar.current.date(byAdding: .hour, value: 48, to: now)!
        let plannedShifts = shifts.filter { $0.end > now && $0.start < windowEnd && $0.status != .unassigned }

        let careWindows = careWindows(in: now...windowEnd)
        uncoveredIntervals = careWindows.flatMap { careWindow in
            let shiftsWithinWindow = plannedShifts.filter { $0.end > careWindow.start && $0.start < careWindow.end }
            return findUncoveredIntervals(in: careWindow.start...careWindow.end, using: shiftsWithinWindow)
        }

        if !uncoveredIntervals.isEmpty {
            let hours = uncoveredIntervals.reduce(0) { $0 + $1.duration / 3600 }
            let template = AppSettings.shared.localized("schedule.gapAlertMessage")
            gapAlert = String(format: template, Int(hours))
        } else {
            gapAlert = nil
        }

        let unsignedShifts = shifts.filter { $0.status == .assigned && !$0.signedIn && $0.start <= Calendar.current.date(byAdding: .hour, value: 1, to: now)! }
        if !unsignedShifts.isEmpty {
            let template = AppSettings.shared.localized("schedule.missingSignInMessage")
            missingSignInAlert = String(format: template, unsignedShifts.count)
        } else {
            missingSignInAlert = nil
        }

        let pendingUnassigned = shifts.filter { $0.status == .unassigned && $0.end > now }
        if !pendingUnassigned.isEmpty {
            appointmentAssignmentWarning = AppSettings.shared.localized("home.appointmentAssignmentWarningMessage")
        } else {
            appointmentAssignmentWarning = nil
        }

        // Dedicated tally + short warning for the homepage so the user
        // sees at a glance how many shifts are still unassigned.
        unassignedShiftCount = pendingUnassigned.count
        if unassignedShiftCount > 0 {
            let template = AppSettings.shared.localized("home.unassignedShiftWarningMessage")
            unassignedShiftWarning = String(format: template, unassignedShiftCount)
        } else {
            unassignedShiftWarning = nil
        }
        
        evaluateTodaySchedule()
        evaluateNextWeekSchedule()
        evaluateUpcomingScheduleCoverage()
        evaluateWeeklyAssignments()
    }

    private func evaluateUpcomingScheduleCoverage() {
        let threshold = max(1, AppSettings.shared.scheduleWarningThreshold)
        let unscheduled = upcomingUnscheduledDates(from: Date(), days: threshold)
        upcomingUnscheduledDates = unscheduled

        if unscheduled.isEmpty {
            upcomingScheduleWarning = nil
        } else {
            let formattedDates = unscheduled.map { isoDate($0) }.joined(separator: ", ")
            let template = AppSettings.shared.localized("schedule.upcomingScheduleWarning")
            upcomingScheduleWarning = String(format: template, threshold, formattedDates)
        }
    }

    func upcomingUnscheduledDates(from start: Date = Date(), days: Int) -> [Date] {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        var dates: [Date] = []
        for offset in 1...days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            if !hasSchedule(on: date) {
                dates.append(date)
            }
        }
        return dates
    }

    /// True when the given date has at least one shift and every shift on
    /// that date is `.completed`. Used by the calendar to draw a tick mark
    /// on fully wrapped-up days so the user can see at a glance which
    /// previous days are "done".
    func allShiftsCompleted(on date: Date) -> Bool {
        let calendar = Calendar.current
        let dayShifts = shifts.filter { calendar.isDate($0.start, inSameDayAs: date) }
        guard !dayShifts.isEmpty else { return false }
        return dayShifts.allSatisfy { $0.status == .completed }
    }

    func hasSchedule(on date: Date) -> Bool {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return shifts.contains { shift in
            shift.status != .unassigned && shift.end > dayStart && shift.start < dayEnd
        }
    }

    private func evaluateWeeklyAssignments() {
        let selectedDate = Date()
        weeklyOverbookedAssignees = getWeeklyOverbookedAssignees(for: selectedDate)
        bannedAssignees = getWeeklyBlockedAssignees(for: selectedDate)
    }

    func getWeeklyOverbookedAssignees(for date: Date) -> [String: Int] {
        let calendar = Calendar.current
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [:] }

        var counts: [String: Set<String>] = [:]
        for shift in shifts where shift.status != .unassigned {
            if shift.end <= weekInterval.start || shift.start >= weekInterval.end { continue }
            counts[shift.assignee, default: Set<String>()].insert(isoDate(shift.start))
        }

        var overbooked: [String: Int] = [:]
        for (assignee, days) in counts {
            let dayCount = days.count
            if dayCount >= AppSettings.shared.weeklyReminderThreshold {
                overbooked[assignee] = dayCount
            }
        }
        return overbooked
    }

    func getWeeklyBlockedAssignees(for date: Date) -> Set<String> {
        let calendar = Calendar.current
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }

        var counts: [String: Set<String>] = [:]
        for shift in shifts where shift.status != .unassigned {
            if shift.end <= weekInterval.start || shift.start >= weekInterval.end { continue }
            counts[shift.assignee, default: Set<String>()].insert(isoDate(shift.start))
        }

        var blocked: Set<String> = []
        for (assignee, days) in counts {
            if days.count >= AppSettings.shared.weeklyBanThreshold {
                blocked.insert(assignee)
            }
        }
        return blocked
    }

    func isAssigneeBlocked(_ assignee: String, for date: Date) -> Bool {
        let calendar = Calendar.current
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else { return false }

        var days: Set<String> = []
        for shift in shifts where shift.assignee == assignee && shift.status != .unassigned {
            if shift.end <= weekInterval.start || shift.start >= weekInterval.end { continue }
            days.insert(isoDate(shift.start))
        }
        return days.count >= AppSettings.shared.weeklyBanThreshold
    }
    
    private func evaluateNextWeekSchedule() {
        var problematicDates = Set<String>()
        let today = Date()
        let calendar = Calendar.current
        
        for day in 0..<7 {
            guard let targetDate = calendar.date(byAdding: .day, value: day, to: today) else { continue }
            if checkDateHasIssue(targetDate) {
                let dateKey = isoDate(targetDate)
                problematicDates.insert(dateKey)
            }
        }
        
        DispatchQueue.main.async {
            self.problematicDatesNextWeek = problematicDates
        }
    }
    
    func getUncoveredPeriodsForDate(_ date: Date) -> [DateInterval] {
        let careWindows = careWindows(in: Calendar.current.startOfDay(for: date)...(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date))
        let dateShifts = shifts.filter { shift in
            Calendar.current.isDate(shift.start, inSameDayAs: date) && shift.status != .unassigned
        }.sorted { $0.start < $1.start }

        return careWindows.flatMap { careWindow in
            let shiftsWithinWindow = dateShifts.filter { $0.end > careWindow.start && $0.start < careWindow.end }
            return findUncoveredIntervals(in: careWindow.start...careWindow.end, using: shiftsWithinWindow)
        }
    }

    func hasOverlappingShifts(for date: Date) -> [Shift] {
        let dateShifts = shifts.filter { shift in
            Calendar.current.isDate(shift.start, inSameDayAs: date) && shift.status != .unassigned
        }.sorted { $0.start < $1.start }

        var overlapping: [Shift] = []
        for i in 0..<dateShifts.count - 1 {
            if dateShifts[i].end > dateShifts[i + 1].start {
                if !overlapping.contains(dateShifts[i]) {
                    overlapping.append(dateShifts[i])
                }
                if !overlapping.contains(dateShifts[i + 1]) {
                    overlapping.append(dateShifts[i + 1])
                }
            }
        }
        return overlapping
    }

    private func isoDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private func evaluateTodaySchedule() {
        let today = Date()
        let careWindows = careWindows(in: Calendar.current.startOfDay(for: today)...(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: today)) ?? today))

        let todayShifts = shifts.filter { shift in
            Calendar.current.isDate(shift.start, inSameDayAs: today) && shift.status != .unassigned
        }.sorted { $0.start < $1.start }

        let hasGap = careWindows.contains { careWindow in
            let shiftsWithinWindow = todayShifts.filter { $0.end > careWindow.start && $0.start < careWindow.end }
            return !findUncoveredIntervals(in: careWindow.start...careWindow.end, using: shiftsWithinWindow).isEmpty
        }
        let hasOverlap = careWindows.contains { careWindow in
            let shiftsWithinWindow = todayShifts.filter { $0.end > careWindow.start && $0.start < careWindow.end }
            return detectOverlaps(in: shiftsWithinWindow)
        }

        todayHasIssue = hasGap || hasOverlap
    }

    func checkDateHasIssue(_ date: Date) -> Bool {
        let careWindows = careWindows(in: Calendar.current.startOfDay(for: date)...(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date))

        let dateShifts = shifts.filter { shift in
            Calendar.current.isDate(shift.start, inSameDayAs: date) && shift.status != .unassigned
        }.sorted { $0.start < $1.start }

        let hasGap = careWindows.contains { careWindow in
            let shiftsWithinWindow = dateShifts.filter { $0.end > careWindow.start && $0.start < careWindow.end }
            return !findUncoveredIntervals(in: careWindow.start...careWindow.end, using: shiftsWithinWindow).isEmpty
        }
        let hasOverlap = careWindows.contains { careWindow in
            let shiftsWithinWindow = dateShifts.filter { $0.end > careWindow.start && $0.start < careWindow.end }
            return detectOverlaps(in: shiftsWithinWindow)
        }

        return hasGap || hasOverlap
    }

    private func detectOverlaps(in sortedShifts: [Shift]) -> Bool {
        guard sortedShifts.count > 1 else { return false }

        for i in 0..<sortedShifts.count - 1 {
            if sortedShifts[i].end > sortedShifts[i + 1].start {
                return true
            }
        }
        return false
    }

    private func findUncoveredIntervals(in window: ClosedRange<Date>, using shifts: [Shift]) -> [DateInterval] {
        let sorted = shifts.sorted { $0.start < $1.start }
        var uncovered: [DateInterval] = []
        var currentStart = window.lowerBound

        for shift in sorted {
            if shift.start > currentStart {
                uncovered.append(DateInterval(start: currentStart, end: min(shift.start, window.upperBound)))
            }
            currentStart = max(currentStart, shift.end)
            if currentStart >= window.upperBound {
                break
            }
        }

        if currentStart < window.upperBound {
            uncovered.append(DateInterval(start: currentStart, end: window.upperBound))
        }

        return uncovered.filter { $0.duration >= 1800 }
    }

    private func careWindows(in window: ClosedRange<Date>) -> [DateInterval] {
        let calendar = Calendar.current
        var result: [DateInterval] = []
        var currentDate = calendar.startOfDay(for: window.lowerBound)
        let endDate = calendar.startOfDay(for: window.upperBound)

        while currentDate <= endDate {
            for careWindow in dailyCareWindows {
                if careWindow.endTime <= careWindow.startTime { continue }
                let startComponents = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSinceReferenceDate: careWindow.startTime))
                let endComponents = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSinceReferenceDate: careWindow.endTime))
                guard let start = calendar.date(bySettingHour: startComponents.hour ?? 0,
                                               minute: startComponents.minute ?? 0,
                                               second: 0,
                                               of: currentDate) else {
                    continue
                }

                let end: Date
                if careWindow.endTime >= 24 * 3600 {
                    end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: currentDate))!
                } else if let computedEnd = calendar.date(bySettingHour: endComponents.hour ?? 0,
                                                         minute: endComponents.minute ?? 0,
                                                         second: 0,
                                                         of: currentDate) {
                    end = computedEnd
                } else {
                    continue
                }

                guard end > start else {
                    continue
                }
                let interval = DateInterval(start: start, end: end)
                let intersection = interval.intersection(with: DateInterval(start: window.lowerBound, end: window.upperBound))
                if let intersection = intersection, intersection.duration >= 1800 {
                    result.append(intersection)
                }
            }
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDate
        }
        return result
    }

    private func initialShifts() -> [Shift] {
        let calendar = Calendar.current
        let today = Date()
        let currentYear = calendar.component(.year, from: today)

        // Build a fixed date in the current year — used for the historical
        // sample shift on 06/23 so the demo always has a "past completed"
        // entry visible in the schedule list.
        func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            return calendar.date(from: comps) ?? Date()
        }

        return [
            // Past completed shift — demo data to show that historical
            // records are preserved and visible in the schedule list.
            Shift(assignee: "印尼看護",
                  start: date(year: currentYear, month: 6, day: 23, hour: 8),
                  end:   date(year: currentYear, month: 6, day: 23, hour: 14),
                  taskSummary: "體温、換藥", status: .completed,
                  note: "請注意傷口",
                  contactEmail: "secdcs01@ctshkpcc.edu.hk",
                  contactPhone: "+852 98765430",
                  signedIn: true),
            Shift(assignee: "印尼看護",
                  start: calendar.date(bySettingHour: 8, minute: 0, second: 0, of: today) ?? today,
                  end: calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today) ?? today,
                  taskSummary: "服藥、體溫、換藥", status: .assigned,
                  note: "請注意傷口乾燥，若體溫升高立即通知子女。",
                  contactEmail: "secdcs01@ctshkpcc.edu.hk",
                  contactPhone: "+852 98765430"),
            Shift(assignee: "大兒子",
                  start: calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today) ?? today,
                  end: calendar.date(bySettingHour: 20, minute: 0, second: 0, of: today) ?? today,
                  taskSummary: "換藥、記錄血壓", status: .assigned,
                  note: "請幫忙補上交班紀錄。",
                  contactEmail: "secdcs02@ctshkpcc.edu.hk",
                  contactPhone: "+852 98765431"),
        ]
    }
}
