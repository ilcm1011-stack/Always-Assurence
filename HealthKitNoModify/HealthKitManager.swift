import Foundation
import HealthKit
import Combine

class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
    private let healthStore = HKHealthStore()

    @Published var temperature: Double?
    @Published var oxygenSaturation: Double?
    @Published var systolicPressure: Double?
    @Published var diastolicPressure: Double?
    @Published var authorizationStatus: HKAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?
    @Published var anomalyMessage: String?
    @Published private var localMeasurements: [String: DailyVitals] = [:]
    @Published var uploadState: UploadState = .idle

    enum MeasurementType: String {
        case temperature
        case spo2
        case bloodPressure
        case summary
    }

    enum UploadState {
        case idle
        case uploading(MeasurementType)
        case success(MeasurementType, Date)
        case failed(MeasurementType, String)
    }

    private var lastAnomalyMessage: String?
    private let measurementStorageKey = "dailyVitalsHistory"

    private init() {
        loadPersistedMeasurements()
        // Guard against missing HealthKit authorization - defer status check
        DispatchQueue.main.async { [weak self] in
            self?.updateAuthorizationStatus()
        }
    }

    private func populatePublishedFromPersisted() {
        // Load the latest persisted measurement, not only today's.
        guard !localMeasurements.isEmpty else { return }
        let latestVitals = localMeasurements.values
            .sorted(by: { $0.recordedAt > $1.recordedAt })
            .first

        guard let vitals = latestVitals else { return }
        DispatchQueue.main.async {
            if let t = vitals.temperature { self.temperature = t }
            if let s = vitals.oxygenSaturation { self.oxygenSaturation = s }
            if let sys = vitals.systolicPressure { self.systolicPressure = sys }
            if let dia = vitals.diastolicPressure { self.diastolicPressure = dia }
            self.evaluateAnomalies()
        }
    }

    // Notification for when a measurement is recorded
    static let didRecordMeasurementNotification = Notification.Name("HealthKitManagerDidRecordMeasurement")

    struct DailyVitals: Codable {
        let temperature: Double?
        let oxygenSaturation: Double?
        let systolicPressure: Double?
        let diastolicPressure: Double?
        let recordedAt: Date
    }

    func updateAuthorizationStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async {
                self.authorizationStatus = .notDetermined
            }
            return
        }

        let types: Set<HKObjectType> = Self.readTypes()
        DispatchQueue.global(qos: .utility).async {
            let statuses = types.compactMap { type in
                self.healthStore.authorizationStatus(for: type)
            }
            let newStatus: HKAuthorizationStatus
            if statuses.isEmpty {
                newStatus = .notDetermined
            } else if statuses.contains(.sharingDenied) {
                newStatus = .sharingDenied
            } else {
                newStatus = .sharingAuthorized
            }
            DispatchQueue.main.async {
                self.authorizationStatus = newStatus
            }
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "此裝置不支援 HealthKit。"
            completion(false)
            return
        }

        let readTypes: Set<HKObjectType> = Self.readTypes()
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.updateAuthorizationStatus()
                if let error = error {
                    self?.errorMessage = error.localizedDescription
                }
                completion(success)
            }
        }
    }

    func recordMeasurements(for date: Date,
                            temperature: Double? = nil,
                            oxygenSaturation: Double? = nil,
                            systolicPressure: Double? = nil,
                            diastolicPressure: Double? = nil) {
        let key = Self.isoDate(date)
        let existing = localMeasurements[key]
        let vitals = DailyVitals(
            temperature: temperature ?? existing?.temperature,
            oxygenSaturation: oxygenSaturation ?? existing?.oxygenSaturation,
            systolicPressure: systolicPressure ?? existing?.systolicPressure,
            diastolicPressure: diastolicPressure ?? existing?.diastolicPressure,
            recordedAt: Date()
        )
        localMeasurements[key] = vitals
        savePersistedMeasurements()

        // If the recorded date is today, update published latest values
        if Calendar.current.isDateInToday(date) {
            DispatchQueue.main.async {
                if let t = vitals.temperature { self.temperature = t }
                if let s = vitals.oxygenSaturation { self.oxygenSaturation = s }
                if let sys = vitals.systolicPressure { self.systolicPressure = sys }
                if let dia = vitals.diastolicPressure { self.diastolicPressure = dia }
            }
        }

        // Also save into CareScheduleManager so the schedule board keeps a copy
        CareScheduleManager.shared.setDailyMeasurement(for: date,
                                                     temperature: vitals.temperature,
                                                     oxygenSaturation: vitals.oxygenSaturation,
                                                     systolicPressure: vitals.systolicPressure,
                                                     diastolicPressure: vitals.diastolicPressure)

        // Post notification so UI can update schedule board / dashboards
        NotificationCenter.default.post(name: Self.didRecordMeasurementNotification, object: nil, userInfo: ["dateKey": key, "date": date])

        // Remote upload to configured app script (non-blocking) with status updates
        DispatchQueue.global(qos: .utility).async {
            // determine measurement type for upload labeling
            let mType: MeasurementType
            if vitals.systolicPressure != nil || vitals.diastolicPressure != nil {
                mType = .bloodPressure
            } else if vitals.temperature != nil && vitals.oxygenSaturation == nil {
                mType = .temperature
            } else if vitals.oxygenSaturation != nil && vitals.temperature == nil {
                mType = .spo2
            } else {
                mType = .summary
            }

            DispatchQueue.main.async { self.uploadState = .uploading(mType) }
            var components = URLComponents(string: Setting.shared.appScriptUrl)
            var items: [URLQueryItem] = []
            items.append(URLQueryItem(name: "sheetId", value: Setting.shared.sheetId))
            items.append(URLQueryItem(name: "sheetName", value: "daily_measurements"))

            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            items.append(URLQueryItem(name: "datetime", value: fmt.string(from: date)))

            if let temp = vitals.temperature {
                items.append(URLQueryItem(name: "temperature", value: String(format: "%.1f", temp)))
            }
            if let spo2 = vitals.oxygenSaturation {
                items.append(URLQueryItem(name: "spo2", value: String(format: "%.0f", spo2 * 100.0)))
            }
            if let sys = vitals.systolicPressure {
                items.append(URLQueryItem(name: "systolic", value: String(format: "%.0f", sys)))
            }
            if let dia = vitals.diastolicPressure {
                items.append(URLQueryItem(name: "diastolic", value: String(format: "%.0f", dia)))
            }

            items.append(URLQueryItem(name: "user", value: Setting.shared.username))
            components?.queryItems = items

            guard let url = components?.url else {
                DispatchQueue.main.async { self.uploadState = .failed(mType, "invalid_url") }
                return
            }

            let task = URLSession.shared.dataTask(with: url) { _, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.uploadState = .failed(mType, error.localizedDescription)
                    } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        self.uploadState = .failed(mType, "HTTP \(http.statusCode)")
                    } else {
                        self.uploadState = .success(mType, Date())
                    }
                }
            }
            task.resume()
        }
    }

    func measurement(for date: Date) -> (temp: Double?, spo2: Double?, sys: Double?, dia: Double?)? {
        guard let vitals = localMeasurements[Self.isoDate(date)] else {
            return nil
        }
        return (vitals.temperature, vitals.oxygenSaturation, vitals.systolicPressure, vitals.diastolicPressure)
    }

    private func loadPersistedMeasurements() {
        guard let data = UserDefaults.standard.data(forKey: measurementStorageKey) else {
            localMeasurements = [:]
            return
        }

        if let measurements = try? JSONDecoder().decode([String: DailyVitals].self, from: data) {
            localMeasurements = measurements
            // populate published properties from persisted data when loading
            populatePublishedFromPersisted()
        }
    }

    private func savePersistedMeasurements() {
        if let data = try? JSONEncoder().encode(localMeasurements) {
            UserDefaults.standard.set(data, forKey: measurementStorageKey)
        }
    }

    func refreshLatestMeasurements(saveAndUpload: Bool = false) {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }

        let group = DispatchGroup()

        var latestTemperature: Double?
        var latestOxygen: Double?
        var latestSystolic: Double?
        var latestDiastolic: Double?

        group.enter()
        fetchLatestSample(for: .bodyTemperature) { value in
            latestTemperature = value
            group.leave()
        }

        group.enter()
        fetchLatestSample(for: .oxygenSaturation) { value in
            latestOxygen = value
            group.leave()
        }

        group.enter()
        fetchLatestSample(for: .bloodPressureSystolic) { value in
            latestSystolic = value
            group.leave()
        }

        group.enter()
        fetchLatestSample(for: .bloodPressureDiastolic) { value in
            latestDiastolic = value
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.temperature = latestTemperature
            self.oxygenSaturation = latestOxygen
            self.systolicPressure = latestSystolic
            self.diastolicPressure = latestDiastolic
            self.evaluateAnomalies()

            if saveAndUpload, latestTemperature != nil || latestOxygen != nil || latestSystolic != nil || latestDiastolic != nil {
                self.recordMeasurements(
                    for: Date(),
                    temperature: latestTemperature,
                    oxygenSaturation: latestOxygen,
                    systolicPressure: latestSystolic,
                    diastolicPressure: latestDiastolic
                )
            }
        }
    }

    func fetchMeasurements(for date: Date, completion: @escaping (Double?, Double?, Double?, Double?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(nil, nil, nil, nil)
            return
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            completion(nil, nil, nil, nil)
            return
        }

        let group = DispatchGroup()

        var latestTemperature: Double?
        var latestOxygen: Double?
        var latestSystolic: Double?
        var latestDiastolic: Double?

        group.enter()
        fetchLatestSampleInRange(for: .bodyTemperature, start: start, end: end) { value in
            latestTemperature = value
            group.leave()
        }

        group.enter()
        fetchLatestSampleInRange(for: .oxygenSaturation, start: start, end: end) { value in
            latestOxygen = value
            group.leave()
        }

        group.enter()
        fetchLatestSampleInRange(for: .bloodPressureSystolic, start: start, end: end) { value in
            latestSystolic = value
            group.leave()
        }

        group.enter()
        fetchLatestSampleInRange(for: .bloodPressureDiastolic, start: start, end: end) { value in
            latestDiastolic = value
            group.leave()
        }

        group.notify(queue: .main) {
            completion(latestTemperature, latestOxygen, latestSystolic, latestDiastolic)
        }
    }

    private func evaluateAnomalies() {
        var alerts: [String] = []

        if let spo2 = oxygenSaturation, spo2 < 93 {
            alerts.append("血氧低於 93%：注意呼吸與缺氧風險。")
        }
        if let temp = temperature, temp > 38.5 {
            alerts.append("體溫高於 38.5°C：可能為感染或術後發炎徵兆。")
        }
        if let systolic = systolicPressure, systolic >= 140 {
            alerts.append("收縮壓偏高：可能需要調整照護或通知醫療團隊。")
        }
        if let diastolic = diastolicPressure, diastolic >= 90 {
            alerts.append("舒張壓偏高：請注意心血管壓力與舒緩照護。")
        }

        if alerts.isEmpty {
            anomalyMessage = nil
            lastAnomalyMessage = nil
            return
        }

        let message = alerts.joined(separator: "\n")
        anomalyMessage = message

        if message != lastAnomalyMessage {
            CareNotificationManager.shared.sendLocalNotification(
                title: AppSettings.shared.localized("health.anomalyAlert"),
                body: message
            )
            lastAnomalyMessage = message
        }
    }

    private func fetchLatestSample(for identifier: HKQuantityTypeIdentifier,
                                   completion: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil)
            return
        }

        let now = Date()
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.date(byAdding: .day, value: -7, to: now), end: now, options: .strictEndDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, error in
            guard error == nil, let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }

            let value = sample.quantity.doubleValue(for: Self.unit(for: identifier))
            completion(value)
        }

        healthStore.execute(query)
    }

    private func fetchLatestSampleInRange(for identifier: HKQuantityTypeIdentifier, start: Date, end: Date, completion: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, error in
            guard error == nil, let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }

            let value = sample.quantity.doubleValue(for: Self.unit(for: identifier))
            completion(value)
        }

        healthStore.execute(query)
    }

    private static func isoDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func readTypes() -> Set<HKObjectType> {
        var types = Set<HKObjectType>()

        if let bodyTemperature = HKObjectType.quantityType(forIdentifier: .bodyTemperature) {
            types.insert(bodyTemperature)
        }
        if let oxygenSaturation = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) {
            types.insert(oxygenSaturation)
        }
        if let systolic = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic) {
            types.insert(systolic)
        }
        if let diastolic = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) {
            types.insert(diastolic)
        }

        return types
    }

    private static func unit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
        switch identifier {
        case .bodyTemperature:
            return HKUnit.degreeCelsius()
        case .oxygenSaturation:
            return HKUnit.percent()
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return HKUnit.millimeterOfMercury()
        default:
            return HKUnit.count()
        }
    }
}
