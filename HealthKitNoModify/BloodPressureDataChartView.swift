//
//  BloodPressureDataChartView.swift
//  VibeCoding1
//
//  Created by chapman on 1/9/2025.
//

import SwiftUI
import Charts

struct BloodPressureDataChartView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var bloodPressureData: [BloodPressureReading] = []
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 20) {
            if isLoading {
                Text(settings.localized("chart.loading"))
                    .font(settings.scaledFont(16))
            } else if bloodPressureData.isEmpty {
                Text(settings.localized("chart.noData"))
                    .font(settings.scaledFont(16))
            } else {
                AlwaysVisibleScrollView {
                    VStack(spacing: 20) {
                        bloodPressureChartView
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(settings.localized("chart.bloodPressureTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            fetchBloodPressureData()
        }
    }

    private var bloodPressureChartView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.localized("chart.bloodPressureHistory"))
                .font(settings.scaledFont(18, weight: .semibold))
            
            Chart(bloodPressureData) { reading in
                LineMark(
                    x: .value(settings.localized("chart.time"), reading.time),
                    y: .value(settings.localized("device.systolic"), reading.systolic)
                )
                .foregroundStyle(by: .value(settings.localized("common.type"), settings.localized("device.systolic")))
                .symbol(.circle)
                
                LineMark(
                    x: .value(settings.localized("chart.time"), reading.time),
                    y: .value(settings.localized("device.diastolic"), reading.diastolic)
                )
                .foregroundStyle(by: .value(settings.localized("common.type"), settings.localized("device.diastolic")))
                .symbol(.square)
                
                LineMark(
                    x: .value(settings.localized("chart.time"), reading.time),
                    y: .value(settings.localized("device.pulse"), reading.pulseRate)
                )
                .foregroundStyle(by: .value(settings.localized("common.type"), settings.localized("device.pulse")))
                .symbol(.triangle)
            }
            .frame(height: 200)
            .chartForegroundStyleScale([
                settings.localized("device.systolic"): .red,
                settings.localized("device.diastolic"): .orange,
                settings.localized("device.pulse"): .blue
            ])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month().day().hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartLegend(position: .bottom)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
    

    
    // MARK: - Helper Methods
    
    private func fetchBloodPressureData() {
        isLoading = true
        let sheetName = "blood_pressure_meter"
        
        // 直接使用字符串拼接 URL
        let urlString = "\(Setting.shared.appScriptUrl)?sheetId=\(Setting.shared.sheetId)&sheetName=\(sheetName)&user=\(Setting.shared.username)"
        guard let url = URL(string: urlString) else {
            isLoading = false
            print("Failed to create API URL")
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                
                if let error = error {
                    print("Error fetching data: \(error.localizedDescription)")
                    return
                }
                
                guard let data = data else {
                    print("No data received")
                    return
                }
                
                do {
                    guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("Invalid data format received")
                        return
                    }
                    
                    if let code = jsonObject["code"] as? Int, code != 200 {
                        let serverMessage = jsonObject["message"] as? String ?? "Unknown server error."
                        print("Server error: \(serverMessage)")
                        return
                    }
                    
                    guard let dataArray = jsonObject["data"] as? [[String: Any]] else {
                        print("Invalid data payload received")
                        return
                    }
                    
                    parseBloodPressureData(from: dataArray)
                } catch {
                    print("Error parsing data: \(error.localizedDescription)")
                }
            }
        }.resume()
    }
    
    private func parseBloodPressureData(from dataArray: [[String: Any]]) {
        var readings: [BloodPressureReading] = []
        
        let rawFormatter = DateFormatter()
        rawFormatter.locale = Locale(identifier: "en_US_POSIX")
        rawFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

        for (_, entry) in dataArray.enumerated() {
            guard let datetimeString = entry["datetime"] as? String,
                  let diastolicValue = entry["diastolic"] as? Int,
                  let systolicValue = entry["systolic"] as? Int,
                  let pulseRateValue = entry["pulse_rate"] as? Int,
                  let time = rawFormatter.date(from: datetimeString) else {
                continue
            }
            
            let reading = BloodPressureReading(
                time: time,
                diastolic: diastolicValue,
                systolic: systolicValue,
                pulseRate: pulseRateValue
            )
            
            readings.append(reading)
        }
        
        self.bloodPressureData = readings.sorted { $0.time < $1.time }
    }
    
}

// MARK: - Data Models

struct BloodPressureReading: Identifiable {
    let id = UUID()
    let time: Date
    let diastolic: Int
    let systolic: Int
    let pulseRate: Int
}


#Preview {
    NavigationView {
        BloodPressureDataChartView()
            .environmentObject(AppSettings.shared)
    }
}
