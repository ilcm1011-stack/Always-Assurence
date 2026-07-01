//
//  ThermometerView.swift
//  VibeCoding1
//
//  Created by chapman on 1/9/2025.
//

import SwiftUI
import iREdFramework

struct ThermometerView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject var ble = iREdBluetooth.shared
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showAlert = false
    @State private var lastAutoThermometerUpload: Date? = nil
    @State private var alerter = VitalAlerter()

    /// Status of the current reading vs. clinical reference range.
    /// Drives the inline warning icon, value color, and audio alert.
    private var tempStatus: VitalStatus {
        VitalRanges.status(ble.iredDeviceData.thermometerData.data.temperature,
                           in: VitalRanges.temperatureC)
    }

    var body: some View {
        VStack(spacing: 30) {
            Text(settings.localized("device.thermometer.title"))
                .font(settings.scaledFont(24, weight: .bold))

            EmptyView()

            VStack(spacing: 10) {
                Text(settings.localized("common.temperature"))
                    .font(settings.scaledFont(18, weight: .semibold))

                if let temperature = ble.iredDeviceData.thermometerData.data.temperature {
                    HStack(spacing: 6) {
                        Text("\(temperature, specifier: "%.1f")\(settings.localized("unit.celsius"))")
                            .font(settings.scaledFont(22, weight: .semibold))
                            .foregroundColor(temperatureWarningColor)
                        VitalWarningIcon(status: tempStatus, size: 18)
                    }
                } else {
                    Text("--.-\(settings.localized("unit.celsius"))")
                        .font(settings.scaledFont(22, weight: .semibold))
                }

                Text(settings.localized("reference.temperature"))
                    .font(settings.scaledFont(13))
                    .foregroundColor(.secondary)

                VStack(spacing: 5) {
                    if let mode = ble.iredDeviceData.thermometerData.data.modeDescription {
                        Text(settings.localized("common.mode") + ": \(mode)")
                            .font(settings.scaledFont(16))
                    }

                    if let battery = ble.iredDeviceData.thermometerData.data.battery {
                        Text(settings.localized("common.battery") + ": \(battery)")
                            .font(settings.scaledFont(16))
                    }
                }
            }
            
            VStack(spacing: 5) {
                HStack {
                    Text(settings.localized("common.connectionStatus"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Spacer()
                    Text(connectionStatusText)
                        .font(settings.scaledFont(16))
                }

                if ble.iredDeviceData.thermometerData.state.isPairing {
                    Text(settings.localized("common.pairing"))
                        .font(settings.scaledFont(16))
                        .foregroundColor(.orange)
                } else if ble.iredDeviceData.thermometerData.state.isPaired {
                    Text(settings.localized("common.paired"))
                        .font(settings.scaledFont(16))
                        .foregroundColor(.blue)
                } else {
                    Text(settings.localized("common.notPaired"))
                        .font(settings.scaledFont(16))
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 15) {
                Button(action: {
                    if ble.iredDeviceData.thermometerData.state.isPairing {
                        ble.stopPairing()
                    } else {
                        ble.startPairing(to: .thermometer)
                    }
                }) {
                    Text(ble.iredDeviceData.thermometerData.state.isPairing ? settings.localized("common.stopPairing") : settings.localized("common.startPairing"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }

                Button(action: {
                    if ble.iredDeviceData.thermometerData.state.isConnected {
                        ble.disconnect(from: .thermometer)
                    } else {
                        ble.connect(from: .thermometer)
                    }
                }) {
                    HStack {
                        Image(systemName: ble.iredDeviceData.thermometerData.state.isConnected ? "link.badge.plus" : "link")
                        Text(ble.iredDeviceData.thermometerData.state.isConnected ? settings.localized("device.disconnect") : settings.localized("device.connect"))
                    }
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(.systemBlue))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                Button(action: {
                    saveThermometerData()
                }) {
                    HStack {
                        if isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(isSaving ? settings.localized("common.saving") : settings.localized("device.saveData"))
                    }
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(.systemTeal))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                NavigationLink(destination: ThermometerDataChartView().environmentObject(settings)) {
                    Text(settings.localized("common.viewChart"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(.systemGray4))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                }
            }

            Spacer()
        }
        .padding()
        .onChange(of: ble.iredDeviceData.thermometerData.state.isMeasurementCompleted) { _, completed in
            if completed {
                autoSaveThermometerDataIfNeeded()
            }
        }
        // Beep + vibrate the first time a new reading lands outside
        // the reference range. The alerter itself debounces so we
        // don't replay while the value stays abnormal.
        .onChange(of: ble.iredDeviceData.thermometerData.data.temperature) { _, _ in
            alerter.evaluate(tempStatus)
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(settings.localized("device.saveResult")),
                message: Text(saveMessage),
                dismissButton: .default(Text(settings.localized("device.understood")))
            )
        }
    }

    private func autoSaveThermometerDataIfNeeded() {
        guard let temperature = ble.iredDeviceData.thermometerData.data.temperature else { return }

        if let last = lastAutoThermometerUpload, Date().timeIntervalSince(last) < 10 {
            return
        }
        lastAutoThermometerUpload = Date()

        HealthKitManager.shared.recordMeasurements(for: Date(), temperature: temperature)
    }

    private var thermometerUploadStatusText: String {
        return ""
    }

    private var connectionStatusText: String {
        if ble.iredDeviceData.thermometerData.state.isConnected {
            return settings.localized("common.connected")
        } else {
            return settings.localized("common.disconnected")
        }
    }

    private var temperatureWarningColor: Color {
        // Use the shared VitalRanges thresholds (36.0–37.5 °C) so
        // the value color, inline warning icon, and chart guide
        // lines all agree on what counts as abnormal.
        tempStatus.isAbnormal ? tempStatus.tint : .primary
    }

    private func saveThermometerData() {
        guard let temperature = ble.iredDeviceData.thermometerData.data.temperature else {
            saveMessage = settings.localized("device.noValidData")
            showAlert = true
            return
        }

        HealthKitManager.shared.recordMeasurements(for: Date(), temperature: temperature)
        isSaving = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())

        let mode = ble.iredDeviceData.thermometerData.data.modeDescription ?? settings.localized("common.mode")
        let sheetName = "thermometer"

        var urlComponents = URLComponents(string: Setting.shared.appScriptUrl)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: sheetName),
            URLQueryItem(name: "datetime", value: timestamp),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "temperature", value: String(format: "%.1f", temperature)),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]

        guard let url = urlComponents.url else {
            saveMessage = settings.localized("device.saveResult")
            showAlert = true
            isSaving = false
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isSaving = false

                if let error = error {
                    saveMessage = String(format: settings.localized("device.saveError"), error.localizedDescription)
                    showAlert = true
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
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
        }.resume()
    }
}

#Preview {
    NavigationView {
        ThermometerView()
            .environmentObject(AppSettings.shared)
    }
}
