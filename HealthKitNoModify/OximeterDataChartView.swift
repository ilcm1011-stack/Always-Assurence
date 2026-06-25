//
//  OximeterDataChartView.swift
//  VibeCoding1
//
//  Created by chapman on 1/9/2025.
//

import SwiftUI
import Charts

struct OximeterDataPoint: Identifiable {
    let id = UUID()
    let time: Date
    let spo2: Int
    let heartRate: Int
    let pi: Double
}

struct OximeterDataChartView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var dataPoints: [OximeterDataPoint] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 20) {
            if isLoading {
                ProgressView(settings.localized("chart.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if dataPoints.isEmpty {
                Text(settings.localized("chart.noData"))
                    .font(settings.scaledFont(16))
            } else {
                AlwaysVisibleScrollView {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(settings.localized("chart.spO2HeartRate"))
                                .font(settings.scaledFont(18, weight: .semibold))
                                .padding(.horizontal)
                                .padding(.top, 10)

                            Chart {
                                ForEach(dataPoints) { dataPoint in
                                    LineMark(
                                        x: .value(settings.localized("chart.time"), dataPoint.time),
                                        y: .value(settings.localized("common.spO2"), dataPoint.spo2)
                                    )
                                    .foregroundStyle(.blue)
                                    .interpolationMethod(.catmullRom)
                                    .symbol(by: .value(settings.localized("common.type"), settings.localized("common.spO2")))

                                    LineMark(
                                        x: .value(settings.localized("chart.time"), dataPoint.time),
                                        y: .value(settings.localized("common.heartRate"), dataPoint.heartRate)
                                    )
                                    .foregroundStyle(.red)
                                    .interpolationMethod(.catmullRom)
                                    .symbol(by: .value(settings.localized("common.type"), settings.localized("common.heartRate")))
                                }
                            }
                            .chartForegroundStyleScale([
                                settings.localized("common.spO2"): .blue,
                                settings.localized("common.heartRate"): .red
                            ])
                            .frame(height: 250)
                            .chartYAxisLabel(settings.localized("common.value"), position: .leading)
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel(format: .dateTime.month().day().hour().minute())
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 10)
                        }
                        .background(Color(.systemGray6))
                        .cornerRadius(12)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(settings.localized("chart.perfusionIndex"))
                                .font(settings.scaledFont(18, weight: .semibold))
                                .padding(.horizontal)
                                .padding(.top, 10)

                            Chart {
                                ForEach(dataPoints) { dataPoint in
                                    LineMark(
                                        x: .value(settings.localized("chart.time"), dataPoint.time),
                                        y: .value(settings.localized("chart.piValue"), dataPoint.pi)
                                    )
                                    .foregroundStyle(.purple)
                                    .interpolationMethod(.catmullRom)
                                    .symbol(by: .value(settings.localized("common.type"), settings.localized("chart.pi")))
                                }
                            }
                            .chartForegroundStyleScale([
                                settings.localized("chart.pi"): .purple
                            ])
                            .frame(height: 250)
                            .chartYAxisLabel(settings.localized("chart.piValue"), position: .leading)
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel(format: .dateTime.month().day().hour().minute())
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 10)
                        }
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle(settings.localized("chart.oximeterTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            fetchOximeterData()
        }
    }

    private func fetchOximeterData() {
        isLoading = true

        let sheetName = "oximeter"

        var urlComponents = URLComponents(string: Setting.shared.appScriptUrl)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: sheetName),
            URLQueryItem(name: "user", value: Setting.shared.username)
        ]

        guard let url = urlComponents.url else {
            isLoading = false
            print("Failed to create request URL.")
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false

                if let error = error {
                    print("Failed to fetch data: \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    print("No data received from server.")
                    return
                }

                do {
                    guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        print("Invalid data format received.")
                        return
                    }

                    if let code = jsonObject["code"] as? Int, code != 200 {
                        let serverMessage = jsonObject["message"] as? String ?? settings.localized("chart.unknownServerError")
                        print("serverMessage: \(serverMessage)")
                        return
                    }

                    guard let dataArray = jsonObject["data"] as? [[String: Any]] else {
                        print("Invalid data payload received.")
                        return
                    }

                    parseOximeterData(from: dataArray)

                } catch {
                    print("Failed to parse data: \(error.localizedDescription)")
                }
            }
        }

        task.resume()
    }

    private func parseOximeterData(from dataArray: [[String: Any]]) {
        print("dataArray: \(dataArray)")
        var newDataPoints: [OximeterDataPoint] = []

        let rawFormatter = DateFormatter()
        rawFormatter.locale = Locale(identifier: "en_US_POSIX")
        rawFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

        for (_, item) in dataArray.enumerated() {
            guard let timeString = item["datetime"] as? String,
                  let validTime = rawFormatter.date(from: timeString),
                  let spo2 = item["spo2"] as? Int,
                  let heartRate = item["heart_rate"] as? Int,
                  let pi = item["pi"] as? Double else {
                continue
            }

            let dataPoint = OximeterDataPoint(
                time: validTime,
                spo2: spo2,
                heartRate: heartRate,
                pi: pi
            )
            newDataPoints.append(dataPoint)
        }

        dataPoints = newDataPoints.sorted { $0.time < $1.time }
    }
}


#Preview {
    NavigationView {
        OximeterDataChartView()
            .environmentObject(AppSettings.shared)
    }
}
