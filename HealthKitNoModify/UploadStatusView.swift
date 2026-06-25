import SwiftUI

struct UploadStatusView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var manager = HealthKitManager.shared

    var body: some View {
        HStack(spacing: 8) {
            if case .uploading = manager.uploadState {
                ProgressView()
            }
            Text(statusText)
                .font(settings.scaledFont(12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private var statusText: String {
        func typeLabel(_ t: HealthKitManager.MeasurementType) -> String {
            switch t {
            case .temperature:
                return settings.localized("device.thermometer.title")
            case .spo2:
                return settings.localized("device.oximeter.title")
            case .bloodPressure:
                return settings.localized("device.bloodPressure.title")
            case .summary:
                return settings.localized("health.title")
            }
        }

        switch manager.uploadState {
        case .idle:
            return settings.localized("device.upload.idle")
        case .uploading(let t):
            return "\(typeLabel(t)) · \(settings.localized("device.upload.uploading"))"
        case .success(let t, let date):
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
            return "\(typeLabel(t)) · \(String(format: settings.localized("device.upload.lastSuccess"), fmt.string(from: date)))"
        case .failed(let t, let msg):
            return "\(typeLabel(t)) · \(String(format: settings.localized("device.upload.failed"), msg))"
        }
    }
}

#if DEBUG
struct UploadStatusView_Previews: PreviewProvider {
    static var previews: some View {
        UploadStatusView()
            .environmentObject(AppSettings.shared)
    }
}
#endif
