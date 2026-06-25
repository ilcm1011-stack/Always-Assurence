import Foundation
import Combine
import UserNotifications

final class CareNotificationManager: ObservableObject {
    static let shared = CareNotificationManager()

    @Published private(set) var isAuthorized = false
    @Published private(set) var scheduledNotificationIdentifiers: Set<String> = []
    private init() {
        requestAuthorization { _ in }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                completion(granted)
            }
        }
    }

    func sendLocalNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("CareNotificationManager error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.scheduledNotificationIdentifiers.insert(identifier)
            }
        }
    }

    func scheduleLocalNotification(title: String, body: String, triggerDate: Date, identifier: String = UUID().uuidString) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("CareNotificationManager schedule error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.scheduledNotificationIdentifiers.insert(identifier)
            }
        }
    }

    func cancelScheduledNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        DispatchQueue.main.async {
            self.scheduledNotificationIdentifiers.remove(identifier)
        }
    }

    func cancelScheduledNotifications(matchingPrefix prefix: String) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map { $0.identifier }.filter { $0.hasPrefix(prefix) }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            DispatchQueue.main.async {
                for id in ids { self.scheduledNotificationIdentifiers.remove(id) }
            }
        }
    }
}
