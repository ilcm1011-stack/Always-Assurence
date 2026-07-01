//
//  VitalRanges.swift
//  HealthKitNoModify
//
//  Single source of truth for adult vital-sign reference ranges.
//  Used by:
//   • Home-screen patient overview (color-coding + "Check Now" badge)
//   • Chart guide lines (low/high horizontal RuleMarks)
//   • Anomaly evaluation in HealthKitManager
//
//  These thresholds are intentionally simple/clinical defaults for an
//  adult ambulatory patient. They are NOT medical advice — they exist
//  so caregivers see an obvious "this looks off, go check now" signal.
//

import SwiftUI

// MARK: - Status enum

enum VitalStatus: Equatable {
    case low
    case normal
    case high
    case unknown

    var isAbnormal: Bool { self == .low || self == .high }

    /// Tint used on chips, badges, and "Check Now" pill. Intentionally
    /// distinct from the chart line colors so abnormal status reads as
    /// a warning, not just another metric.
    var tint: Color {
        switch self {
        case .low:     return Color(red: 0.18, green: 0.45, blue: 0.85) // calm blue
        case .normal:  return Color(red: 0.22, green: 0.66, blue: 0.46) // mint / OK
        case .high:    return Color(red: 0.86, green: 0.32, blue: 0.32) // warm red
        case .unknown: return Color.gray
        }
    }
}

// MARK: - Reference ranges

enum VitalRanges {
    struct Range {
        let low: Double          // anything below = .low
        let high: Double         // anything above = .high
        let unit: String
    }

    // Body temperature (oral / forehead, adult)
    static let temperatureC: Range  = Range(low: 36.0, high: 37.5, unit: "°C")

    // SpO₂ stored as percentage 0–100.
    static let spO2Percent: Range   = Range(low: 95.0, high: 100.0, unit: "%")

    // Blood pressure (adult guideline thresholds)
    static let systolicMmHg: Range  = Range(low: 90.0, high: 120.0, unit: "mmHg")
    static let diastolicMmHg: Range = Range(low: 60.0, high: 80.0,  unit: "mmHg")

    // Resting pulse rate
    static let pulseBpm: Range      = Range(low: 60.0, high: 100.0, unit: "bpm")

    /// Classify a single value against a range. Returns `.unknown`
    /// for missing measurements so chips render in a neutral grey.
    static func status(_ value: Double?, in range: Range) -> VitalStatus {
        guard let v = value else { return .unknown }
        if v < range.low  { return .low }
        if v > range.high { return .high }
        return .normal
    }
}
