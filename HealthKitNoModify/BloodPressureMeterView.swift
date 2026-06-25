//
//  BloodPressureMeterView.swift
//  VibeCoding1
//
//  Created by chapman on 1/9/2025.
//

import SwiftUI
import iREdFramework

struct BloodPressureMeterView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject var ble = iREdBluetooth.shared
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showSaveAlert = false
    @State private var lastAutoBPUpload: Date? = nil

    var body: some View {
        VStack(spacing: 20) {
            Text(settings.localized("device.bloodPressure.title"))
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
                    ble.startPairing(to: .sphygmometer)
                }) {
                    Text(settings.localized("common.pairing"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }

                Button(action: {
                    ble.connect(from: .sphygmometer)
                }) {
                    Text(settings.localized("device.connect"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemBlue))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Button(action: {
                    ble.disconnect(from: .sphygmometer)
                }) {
                    Text(settings.localized("device.disconnect"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray4))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }

                Button(action: {
                    saveBloodPressureData()
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

                NavigationLink(destination: BloodPressureDataChartView().environmentObject(settings)) {
                    Text(settings.localized("common.viewChart"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray4))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
            }

            VStack(spacing: 15) {
                Text(settings.localized("common.bloodPressureReading"))
                    .font(settings.scaledFont(18, weight: .semibold))

                HStack(spacing: 20) {
                    VStack {
                        Text(settings.localized("device.systolic"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        Text(systolicText)
                            .font(settings.scaledFont(16))
                            .foregroundColor(systolicWarningColor)
                    }

                    VStack {
                        Text(settings.localized("device.diastolic"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        Text(diastolicText)
                            .font(settings.scaledFont(16))
                            .foregroundColor(diastolicWarningColor)
                    }
                }

                HStack(spacing: 20) {
                    VStack {
                        Text(settings.localized("device.pulse"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        Text(pulseText)
                            .font(settings.scaledFont(16))
                    }

                    VStack {
                        Text(settings.localized("common.pressure"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        Text(pressureText)
                            .font(settings.scaledFont(16))
                            .foregroundColor(pressureWarningColor)
                    }
                }

                Text(settings.localized("reference.bloodPressure"))
                    .font(settings.scaledFont(13))
                    .foregroundColor(.secondary)

                if ble.iredDeviceData.sphygmometerData.state.isConnected {
                    VStack {
                        Text(settings.localized("common.status"))
                            .font(settings.scaledFont(16, weight: .semibold))
                        Text(measurementStatusText)
                            .font(settings.scaledFont(16))
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onChange(of: ble.iredDeviceData.sphygmometerData.state.isMeasurementCompleted) { _, completed in
            if completed {
                autoSaveBloodPressureIfNeeded()
            }
        }
        .alert(isPresented: $showSaveAlert) {
            Alert(
                title: Text(settings.localized("device.saveResult")),
                message: Text(saveMessage),
                dismissButton: .default(Text(settings.localized("device.understood")))
            )
        }
    }

    private func autoSaveBloodPressureIfNeeded() {
        guard let systolic = ble.iredDeviceData.sphygmometerData.data.systolic,
              let diastolic = ble.iredDeviceData.sphygmometerData.data.diastolic,
              let _ = ble.iredDeviceData.sphygmometerData.data.pulse else {
            return
        }

        if let last = lastAutoBPUpload, Date().timeIntervalSince(last) < 10 {
            return
        }
        lastAutoBPUpload = Date()

        HealthKitManager.shared.recordMeasurements(for: Date(), systolicPressure: Double(systolic), diastolicPressure: Double(diastolic))
    }

    private var bpUploadStatusText: String {
        return ""
    }

    private func saveBloodPressureData() {
        guard let systolic = ble.iredDeviceData.sphygmometerData.data.systolic,
              let diastolic = ble.iredDeviceData.sphygmometerData.data.diastolic,
              let pulseRate = ble.iredDeviceData.sphygmometerData.data.pulse else {
            saveMessage = settings.localized("device.noValidData")
            showSaveAlert = true
            return
        }

        HealthKitManager.shared.recordMeasurements(for: Date(), systolicPressure: Double(systolic), diastolicPressure: Double(diastolic))
        isSaving = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())

        let sheetName = "blood_pressure_meter"
        let urlString = "\(Setting.shared.appScriptUrl)?sheetId=\(Setting.shared.sheetId)&sheetName=\(sheetName)&datetime=\(timestamp)&diastolic=\(diastolic)&systolic=\(systolic)&pulse_rate=\(pulseRate)&user=\(Setting.shared.username)"

        guard let url = URL(string: urlString) else {
            isSaving = false
            saveMessage = settings.localized("device.saveResult")
            showSaveAlert = true
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                self.isSaving = false

                if let error = error {
                    self.saveMessage = String(format: settings.localized("device.saveError"), error.localizedDescription)
                    self.showSaveAlert = true
                    return
                }

                guard let data = data else {
                    self.saveMessage = settings.localized("device.noValidData")
                    self.showSaveAlert = true
                    return
                }

                do {
                    if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let code = jsonObject["code"] as? Int ?? 0
                        let message = jsonObject["message"] as? String

                        if code == 200 {
                            self.saveMessage = message ?? settings.localized("device.saveResult")
                        } else {
                            self.saveMessage = message ?? String(format: settings.localized("device.saveFailedStatus"), String(code))
                        }
                    } else if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            self.saveMessage = settings.localized("device.saveResult")
                        } else {
                            self.saveMessage = String(format: settings.localized("device.saveFailedStatus"), String(httpResponse.statusCode))
                        }
                    } else {
                        self.saveMessage = settings.localized("device.unexpectedResponse")
                    }
                } catch {
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        self.saveMessage = settings.localized("device.saveResult")
                    } else {
                        self.saveMessage = settings.localized("device.unexpectedResponse")
                    }
                }

                self.showSaveAlert = true
            }
        }.resume()
    }

    private var connectionStatusColor: Color {
        if ble.iredDeviceData.sphygmometerData.state.isConnected {
            return .green
        } else if ble.iredDeviceData.sphygmometerData.state.isPairing {
            return .orange
        } else if ble.iredDeviceData.sphygmometerData.state.isPaired {
            return .blue
        } else {
            return .gray
        }
    }

    private var connectionStatusText: String {
        if ble.iredDeviceData.sphygmometerData.state.isConnected {
            return settings.localized("common.connected")
        } else if ble.iredDeviceData.sphygmometerData.state.isPairing {
            return settings.localized("common.pairing")
        } else if ble.iredDeviceData.sphygmometerData.state.isPaired {
            return settings.localized("common.paired")
        } else {
            return settings.localized("common.notPaired")
        }
    }

    private var systolicText: String {
        if let systolic = ble.iredDeviceData.sphygmometerData.data.systolic {
            return "\(systolic)"
        } else {
            return "--"
        }
    }

    private var diastolicText: String {
        if let diastolic = ble.iredDeviceData.sphygmometerData.data.diastolic {
            return "\(diastolic)"
        } else {
            return "--"
        }
    }

    private var pulseText: String {
        if let pulse = ble.iredDeviceData.sphygmometerData.data.pulse {
            return "\(pulse) \(settings.localized("unit.bpm"))"
        } else {
            return "--"
        }
    }

    private var pressureText: String {
        if let pressure = ble.iredDeviceData.sphygmometerData.data.pressure {
            return "\(pressure) \(settings.localized("unit.mmHg"))"
        } else {
            return "--"
        }
    }

    private var systolicWarningColor: Color {
        if let systolic = ble.iredDeviceData.sphygmometerData.data.systolic, systolic > 120 {
            return .red
        }
        return .primary
    }

    private var diastolicWarningColor: Color {
        if let diastolic = ble.iredDeviceData.sphygmometerData.data.diastolic, diastolic > 80 {
            return .red
        }
        return .primary
    }

    private var pressureWarningColor: Color {
        if let systolic = ble.iredDeviceData.sphygmometerData.data.systolic, systolic > 120 {
            return .red
        }
        if let diastolic = ble.iredDeviceData.sphygmometerData.data.diastolic, diastolic > 80 {
            return .red
        }
        return .primary
    }

    private var measurementStatusText: String {
        if ble.iredDeviceData.sphygmometerData.state.isMeasurementCompleted {
            return settings.localized("common.measurementComplete")
        } else if ble.iredDeviceData.sphygmometerData.state.isConnected {
            return settings.localized("common.readyToMeasure")
        } else {
            return settings.localized("common.disconnected")
        }
    }
}

#Preview {
    NavigationView {
        BloodPressureMeterView()
            .environmentObject(AppSettings.shared)
    }
}
