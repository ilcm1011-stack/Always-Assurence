//
//  OximeterView.swift
//  VibeCoding1
//
//  Created by chapman on 1/9/2025.
//

import SwiftUI
import iREdFramework

struct OximeterView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject var ble = iREdBluetooth.shared
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showAlert = false
    @State private var lastAutoOximeterUpload: Date? = nil
    @State private var spo2Alerter = VitalAlerter()
    @State private var hrAlerter   = VitalAlerter()

    /// Status of SpO₂ against the 95–100 % reference range.
    private var spo2Status: VitalStatus {
        guard let spo2 = ble.iredDeviceData.oximeterData.data.spo2 else { return .unknown }
        return VitalRanges.status(Double(spo2), in: VitalRanges.spO2Percent)
    }

    /// Status of pulse rate against the 60–100 bpm reference range.
    /// The oximeter exposes pulse separately from BP, so we evaluate
    /// it here too and surface a separate warning icon next to the
    /// heart-rate value.
    private var pulseStatus: VitalStatus {
        guard let pulse = ble.iredDeviceData.oximeterData.data.pulse else { return .unknown }
        return VitalRanges.status(Double(pulse), in: VitalRanges.pulseBpm)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(settings.localized("device.oximeter.title"))
                .font(settings.scaledFont(24, weight: .bold))

            EmptyView()

            VStack(spacing: 10) {
                Text(settings.localized("common.connectionStatus"))
                    .font(settings.scaledFont(18, weight: .semibold))
                HStack {
                    Text(connectionStatusText)
                        .font(settings.scaledFont(16))
                        .foregroundColor(connectionStatusColor)
                }
            }

            VStack(spacing: 15) {
                Button(action: {
                    ble.startPairing(to: .oximeter)
                }) {
                    Text(settings.localized("common.pairing"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }

                Button(action: {
                    ble.connect(from: .oximeter)
                }) {
                    Text(settings.localized("device.connect"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemBlue))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Button(action: {
                    ble.disconnect(from: .oximeter)
                }) {
                    Text(settings.localized("device.disconnect"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray4))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }

                Button(action: {
                    saveOximeterData()
                }) {
                    HStack {
                        if isSaving {
                            ProgressView()
                        }
                        Text(isSaving ? settings.localized("common.saving") : settings.localized("device.saveData"))
                    }
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(.systemTeal))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                NavigationLink(destination: OximeterDataChartView().environmentObject(settings)) {
                    Text(settings.localized("common.viewDataCharts"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray4))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
            }

            VStack(spacing: 15) {
                Text(settings.localized("common.measurementStatus"))
                    .font(settings.scaledFont(18, weight: .semibold))

                HStack(spacing: 20) {
                    VStack {
                        Text(settings.localized("common.spO2"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        HStack(spacing: 4) {
                            Text(spo2Text)
                                .font(settings.scaledFont(16))
                                .foregroundColor(spo2WarningColor)
                            VitalWarningIcon(status: spo2Status)
                        }
                    }

                    VStack {
                        Text(settings.localized("common.heartRate"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        HStack(spacing: 4) {
                            Text(heartRateText)
                                .font(settings.scaledFont(16))
                                .foregroundColor(heartRateWarningColor)
                            VitalWarningIcon(status: pulseStatus)
                        }
                    }
                }

                Text(settings.localized("reference.oxygen"))
                    .font(settings.scaledFont(13))
                    .foregroundColor(.secondary)

                VStack {
                    Text(settings.localized("chart.perfusionIndex"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Text(piText)
                        .font(settings.scaledFont(16))
                }

                if let battery = ble.iredDeviceData.oximeterData.data.battery {
                    VStack {
                        Text(settings.localized("common.battery"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        Text("\(battery)%")
                            .font(settings.scaledFont(16))
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onChange(of: ble.iredDeviceData.oximeterData.state.isMeasurementCompleted) { _, completed in
            if completed {
                autoSaveOximeterDataIfNeeded()
            }
        }
        // Separate alerters for SpO₂ and pulse so each metric beeps
        // independently when it first crosses into the abnormal range.
        .onChange(of: ble.iredDeviceData.oximeterData.data.spo2) { _, _ in
            spo2Alerter.evaluate(spo2Status)
        }
        .onChange(of: ble.iredDeviceData.oximeterData.data.pulse) { _, _ in
            hrAlerter.evaluate(pulseStatus)
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(settings.localized("device.saveResult")),
                message: Text(saveMessage),
                dismissButton: .default(Text(settings.localized("device.understood")))
            )
        }
    }

    private func autoSaveOximeterDataIfNeeded() {
          guard let spo2 = ble.iredDeviceData.oximeterData.data.spo2,
              let _ = ble.iredDeviceData.oximeterData.data.pulse,
              let _ = ble.iredDeviceData.oximeterData.data.pi else {
            return
        }

        // simple debounce: avoid uploading multiple times within 10 seconds
        if let last = lastAutoOximeterUpload, Date().timeIntervalSince(last) < 10 {
            return
        }

        lastAutoOximeterUpload = Date()

        // persist locally and trigger centralized upload in HealthKitManager
        HealthKitManager.shared.recordMeasurements(for: Date(), oxygenSaturation: Double(spo2) / 100.0)
    }

    private var uploadStatusText: String {
        return ""
    }

    private var connectionStatusColor: Color {
        if ble.iredDeviceData.oximeterData.state.isConnected {
            return .green
        } else if ble.iredDeviceData.oximeterData.state.isPairing {
            return .orange
        } else if ble.iredDeviceData.oximeterData.state.isPaired {
            return .blue
        } else {
            return .gray
        }
    }

    private var connectionStatusText: String {
        if ble.iredDeviceData.oximeterData.state.isConnected {
            return settings.localized("common.connected")
        } else if ble.iredDeviceData.oximeterData.state.isPairing {
            return settings.localized("common.pairing")
        } else if ble.iredDeviceData.oximeterData.state.isPaired {
            return settings.localized("common.paired")
        } else {
            return settings.localized("common.notPaired")
        }
    }

    private var spo2Text: String {
        if let spo2 = ble.iredDeviceData.oximeterData.data.spo2 {
            return "\(spo2)%"
        } else {
            return "--"
        }
    }

    private var spo2WarningColor: Color {
        // Routed through VitalRanges so the threshold lives in one place.
        spo2Status.isAbnormal ? spo2Status.tint : .primary
    }

    private var heartRateText: String {
        if let pulse = ble.iredDeviceData.oximeterData.data.pulse {
            return "\(pulse) \(settings.localized("unit.bpm"))"
        } else {
            return "--"
        }
    }

    private var heartRateWarningColor: Color {
        pulseStatus.isAbnormal ? pulseStatus.tint : .primary
    }

    private var piText: String {
        if let pi = ble.iredDeviceData.oximeterData.data.pi {
            return String(format: "%.2f", pi)
        } else {
            return "--"
        }
    }

    private func saveOximeterData() {
        guard let spo2 = ble.iredDeviceData.oximeterData.data.spo2,
              let heartRate = ble.iredDeviceData.oximeterData.data.pulse,
              let pi = ble.iredDeviceData.oximeterData.data.pi else {
            saveMessage = settings.localized("device.noValidData")
            showAlert = true
            return
        }

        HealthKitManager.shared.recordMeasurements(for: Date(), oxygenSaturation: Double(spo2) / 100.0)
        isSaving = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())

        let sheetName = "oximeter"

        var urlComponents = URLComponents(string: Setting.shared.appScriptUrl)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: sheetName),
            URLQueryItem(name: "datetime", value: timestamp),
            URLQueryItem(name: "spo2", value: String(spo2)),
            URLQueryItem(name: "heart_rate", value: String(heartRate)),
            URLQueryItem(name: "pi", value: String(format: "%.2f", pi)),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]

        guard let url = urlComponents.url else {
            isSaving = false
            saveMessage = settings.localized("device.saveResult")
            showAlert = true
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isSaving = false

                if let error = error {
                    saveMessage = String(format: settings.localized("device.saveError"), error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        saveMessage = settings.localized("device.saveResult")
                    } else {
                        saveMessage = String(format: settings.localized("device.saveFailedStatus"), String(httpResponse.statusCode))
                    }
                } else {
                    saveMessage = settings.localized("device.unexpectedResponse")
                }

                showAlert = true
            }
        }

        task.resume()
    }
}

#Preview {
    NavigationView {
        OximeterView()
            .environmentObject(AppSettings.shared)
    }
}
