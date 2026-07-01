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
                        // Per request: 3 separate charts (Systolic /
                        // Diastolic / Pulse) so each metric gets its
                        // own y-axis range and a less busy plot area.
                        singleSeriesChart(
                            title: settings.localized("device.systolic"),
                            color: .red,
                            unit: "mmHg",
                            range: VitalRanges.systolicMmHg,
                            value: { Double($0.systolic) }
                        )

                        singleSeriesChart(
                            title: settings.localized("device.diastolic"),
                            color: .orange,
                            unit: "mmHg",
                            range: VitalRanges.diastolicMmHg,
                            value: { Double($0.diastolic) }
                        )

                        singleSeriesChart(
                            title: settings.localized("device.pulse"),
                            color: .blue,
                            unit: "bpm",
                            range: VitalRanges.pulseBpm,
                            value: { Double($0.pulseRate) }
                        )
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

    /// Generic single-series chart used for Systolic / Diastolic / Pulse.
    /// Pulling each metric out into its own chart prevents the pulse
    /// series (~60-100 bpm) from compressing the systolic/diastolic
    /// y-axis range, which made trends hard to read.
    private func singleSeriesChart(
        title: String,
        color: Color,
        unit: String,
        range: VitalRanges.Range,
        value: @escaping (BloodPressureReading) -> Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(settings.scaledFont(18, weight: .semibold))

            Chart {
                ForEach(bloodPressureData) { reading in
                    LineMark(
                        x: .value(settings.localized("chart.time"), reading.time),
                        y: .value(title, value(reading))
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value(settings.localized("chart.time"), reading.time),
                        y: .value(title, value(reading))
                    )
                    .foregroundStyle(color)
                    .symbolSize(50)
                }

                // Reference range guide lines (low / high horizontal rules).
                RuleMark(y: .value("Low",  range.low))
                    .foregroundStyle(VitalStatus.low.tint.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("\(Int(range.low)) \(unit)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(VitalStatus.low.tint)
                    }
                RuleMark(y: .value("High", range.high))
                    .foregroundStyle(VitalStatus.high.tint.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("\(Int(range.high)) \(unit)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(VitalStatus.high.tint)
                    }
            }
            .frame(height: 200)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month().day().hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v)) \(unit)")
                                .font(settings.scaledFont(12))
                        }
                    }
                }
            }
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
