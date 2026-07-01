//
//  ThermometerDataChartView.swift
//  VibeCoding1
//
//  Created by chapman on 1/9/2025.
//

import SwiftUI
import Charts

struct ThermometerDataPoint: Identifiable, Codable {
    let id: UUID
    let time: Date
    let mode: String
    let temperature: Double

    init(date: Date, mode: String, temperature: Double) {
        self.id = UUID()
        self.time = date
        self.mode = mode
        self.temperature = temperature
    }
}

struct ThermometerDataChartView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var dataPoints: [ThermometerDataPoint] = []
    @State private var isLoading = false
    @State private var selectedTime: Date? = nil          // x-axis tap selection
    @Environment(\.dismiss) private var dismiss

    /// Stable colour mapping so the same mode keeps the same hue across
    /// chart updates / re-renders.
    private static let modePalette: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .teal, .brown]
    private func color(for mode: String, in modes: [String]) -> Color {
        guard let idx = modes.firstIndex(of: mode) else { return .gray }
        return Self.modePalette[idx % Self.modePalette.count]
    }

    /// Returns the data point closest in time to the user's tap, used to
    /// surface the *mode* badge above the chart. Only consider matches
    /// within ±2 minutes so the badge disappears when the user taps a
    /// blank area.
    private func nearestPoint(to time: Date) -> ThermometerDataPoint? {
        guard let target = dataPoints.min(by: {
            abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time))
        }) else { return nil }
        return abs(target.time.timeIntervalSince(time)) <= 120 ? target : nil
    }

    var body: some View {
        VStack(spacing: 20) {
            headerView
            contentView
            Spacer()
        }
        .navigationTitle(settings.localized("chart.thermometerTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadThermometerData()
        }
    }

    private var headerView: some View {
        VStack(spacing: 10) {
            Text(settings.localized("chart.thermometerTitle"))
                .font(settings.scaledFont(24, weight: .bold))
        }
        .padding(.top)
    }

    private var contentView: some View {
        Group {
            if isLoading {
                Text(settings.localized("chart.loading"))
                    .font(settings.scaledFont(16))
            } else if dataPoints.isEmpty {
                Text(settings.localized("chart.noData"))
                    .font(settings.scaledFont(16))
            } else {
                chartContentView
            }
        }
    }

    private var chartContentView: some View {
        AlwaysVisibleScrollView {
            VStack(spacing: 20) {
                combinedTemperatureChart
            }
            .padding(.vertical)
        }
    }

    /// All modes plotted on a single chart. Each measurement is a point
    /// coloured by mode; the line that connects them is neutral grey so
    /// the eye reads "temperature over time" first, with mode as a
    /// secondary attribute. Tap a point (or anywhere on the chart) to
    /// surface the mode label for the nearest measurement.
    private var combinedTemperatureChart: some View {
        let modes = Array(Set(dataPoints.map(\.mode))).sorted()
        let modeColorRange = modes.map { color(for: $0, in: modes) }
        let selected = selectedTime.flatMap { nearestPoint(to: $0) }

        return VStack(alignment: .leading, spacing: 10) {
            // Header row: title + tap-revealed mode badge.
            HStack(alignment: .firstTextBaseline) {
                Text(settings.localized("common.temperature"))
                    .font(settings.scaledFont(18, weight: .semibold))
                Spacer()
                if let s = selected {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: s.mode, in: modes))
                            .frame(width: 10, height: 10)
                        Text(String(format: "%.1f°C  ·  %@",
                                    s.temperature,
                                    "\(s.mode) \(settings.localized("common.mode"))"))
                            .font(settings.scaledFont(13, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(.systemBackground))
                    )
                    .overlay(
                        Capsule().stroke(Color(.separator), lineWidth: 0.7)
                    )
                } else {
                    Text(settings.localized("chart.tapToSeeMode"))
                        .font(settings.scaledFont(12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            Chart {
                // Single continuous line for trend (neutral grey).
                ForEach(dataPoints) { dataPoint in
                    LineMark(
                        x: .value(settings.localized("chart.time"), dataPoint.time),
                        y: .value(settings.localized("common.temperature"), dataPoint.temperature)
                    )
                    .foregroundStyle(Color.gray.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }

                // Point marks coloured by mode so users can spot at a
                // glance which measurements were taken in which mode.
                ForEach(dataPoints) { dataPoint in
                    PointMark(
                        x: .value(settings.localized("chart.time"), dataPoint.time),
                        y: .value(settings.localized("common.temperature"), dataPoint.temperature)
                    )
                    .foregroundStyle(by: .value(settings.localized("common.mode"), dataPoint.mode))
                    .symbolSize(60)
                }

                // Reference range guide lines (low / high body temp).
                RuleMark(y: .value("Low",  VitalRanges.temperatureC.low))
                    .foregroundStyle(VitalStatus.low.tint.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text(String(format: "%.1f°C", VitalRanges.temperatureC.low))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(VitalStatus.low.tint)
                    }
                RuleMark(y: .value("High", VitalRanges.temperatureC.high))
                    .foregroundStyle(VitalStatus.high.tint.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text(String(format: "%.1f°C", VitalRanges.temperatureC.high))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(VitalStatus.high.tint)
                    }

                // Highlight ring + vertical rule for the tapped point.
                if let s = selected {
                    RuleMark(x: .value(settings.localized("chart.time"), s.time))
                        .foregroundStyle(Color.gray.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value(settings.localized("chart.time"), s.time),
                        y: .value(settings.localized("common.temperature"), s.temperature)
                    )
                    .foregroundStyle(color(for: s.mode, in: modes))
                    .symbolSize(180)
                    .symbol(.circle)
                    .opacity(0.25)
                }
            }
            .chartForegroundStyleScale(domain: modes, range: modeColorRange)
            .chartLegend(position: .bottom, alignment: .center)
            .chartXSelection(value: $selectedTime)
            .frame(height: 240)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let temp = value.as(Double.self) {
                            Text(String(format: "%.1f°C", temp))
                                .font(settings.scaledFont(12))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month().day().hour().minute())
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }

    private func loadThermometerData() {
        isLoading = true

        let sheetName = "thermometer"
        let urlString = "\(Setting.shared.appScriptUrl)?sheetId=\(Setting.shared.sheetId)&sheetName=\(sheetName)&user=\(Setting.shared.username)"

        guard let url = URL(string: urlString) else {
            print("Failed to construct URL")
            isLoading = false
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false

                if let error = error {
                    print("Network error: \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    print("No data received")
                    return
                }

                let rawFormatter = DateFormatter()
                rawFormatter.locale = Locale(identifier: "en_US_POSIX")
                rawFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

                do {
                    let jsonObject = try JSONSerialization.jsonObject(with: data)

                    if let jsonDict = jsonObject as? [String: Any],
                       let dataArray = jsonDict["data"] as? [[String: Any]] {

                        var parsedData: [ThermometerDataPoint] = []

                        for row in dataArray {
                            guard let timeString = row["datetime"] as? String,
                                  let mode = row["mode"] as? String,
                                  let temperature = row["temperature"] as? Double,
                                  let date = rawFormatter.date(from: timeString) else {
                                continue
                            }

                            let dataPoint = ThermometerDataPoint(
                                date: date,
                                mode: mode,
                                temperature: temperature
                            )
                            parsedData.append(dataPoint)
                        }

                        self.dataPoints = parsedData.sorted { $0.time < $1.time }

                    } else {
                        print("Invalid data format received")
                    }
                } catch {
                    print("Failed to parse data: \(error.localizedDescription)")
                }
            }
        }.resume()
    }
}

#Preview {
    ThermometerDataChartView()
        .environmentObject(AppSettings.shared)
}
