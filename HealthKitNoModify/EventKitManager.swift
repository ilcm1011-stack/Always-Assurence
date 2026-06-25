import Foundation
import Combine
import EventKit

final class EventKitManager: ObservableObject {
    static let shared = EventKitManager()
    private let eventStore = EKEventStore()

    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var exportMessage: String?

    private init() {
        updateAuthorizationStatus()
    }

    private func updateAuthorizationStatus() {
        DispatchQueue.global(qos: .utility).async {
            let status = EKEventStore.authorizationStatus(for: .event)
            DispatchQueue.main.async {
                self.authorizationStatus = status
            }
        }
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(true)
            }

        case .notDetermined:
            if #available(iOS 17.0, *) {
                eventStore.requestFullAccessToEvents { granted, _ in
                    DispatchQueue.main.async {
                        self.updateAuthorizationStatus()
                        completion(granted)
                    }
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async {
                        self.updateAuthorizationStatus()
                        completion(granted)
                    }
                }
            }

        case .writeOnly:
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(true)
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(false)
            }

        @unknown default:
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(false)
            }
        }
    }

    func exportShiftsToCalendar(_ shifts: [Shift], completion: @escaping (Result<String, Error>) -> Void) {
        requestAccess { granted in
            guard granted else {
                completion(.failure(EventKitError.accessDenied))
                return
            }

            guard let calendar = self.calendarToUse() else {
                completion(.failure(EventKitError.calendarNotAvailable))
                return
            }

            do {
                try self.removeExistingShiftEvents(from: calendar, shifts: shifts)
                try self.saveShiftEvents(shifts, calendar: calendar)
                completion(.success("已成功將排班匯入行事曆。"))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func calendarToUse() -> EKCalendar? {
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == "HealthKit Care Schedule" }) {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "HealthKit Care Schedule"
        calendar.source = eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .local })
            ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
            ?? eventStore.sources.first(where: { $0.sourceType == .exchange })
        ?? eventStore.sources.first
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            return eventStore.defaultCalendarForNewEvents
        }
    }

    private func removeExistingShiftEvents(from calendar: EKCalendar, shifts: [Shift]) throws {
        let start = shifts.map { $0.start }.min() ?? Date()
        let end = shifts.map { $0.end }.max() ?? Date()
        let predicate = eventStore.predicateForEvents(withStart: start.addingTimeInterval(-3600), end: end.addingTimeInterval(3600), calendars: [calendar])
        let events = eventStore.events(matching: predicate)

        for event in events where event.notes?.contains("CareScheduleID:") == true {
            try eventStore.remove(event, span: .thisEvent, commit: false)
        }

        try eventStore.commit()
    }

    private func saveShiftEvents(_ shifts: [Shift], calendar: EKCalendar) throws {
        for shift in shifts where shift.status != .unassigned {
            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = "照護班次：\(shift.assignee)"
            event.startDate = shift.start
            event.endDate = shift.end
            event.location = "家庭照護"
            event.notes = "任務：\(shift.taskSummary)\n備註：\(shift.note)\nCareScheduleID:\(shift.id.uuidString)"
            event.url = URL(string: "healthkit://shift/\(shift.id.uuidString)")
            try eventStore.save(event, span: .thisEvent, commit: false)
        }
        try eventStore.commit()
    }

    enum EventKitError: LocalizedError {
        case accessDenied
        case calendarNotAvailable

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "行事曆存取權限被拒絕，請至設定允許後再試一次。"
            case .calendarNotAvailable:
                return "無法取得行事曆。"
            }
        }
    }
}
