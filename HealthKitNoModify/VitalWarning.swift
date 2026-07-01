//
//  VitalWarning.swift
//  HealthKitNoModify
//
//  Shared warning UI + alert helpers used by the three measurement
//  screens (Thermometer / Oximeter / Blood Pressure).
//
//  Two pieces:
//    1. `VitalWarningIcon`  – small inline ⚠︎ icon shown next to a
//       value when its `VitalStatus` is abnormal.
//    2. `VitalAlerter`      – stateful helper that plays a short
//       system warning beep + haptic the first time a value
//       transitions into the abnormal range. Debounced so a
//       fluctuating reading doesn't spam the user.
//

import SwiftUI
import AudioToolbox

// MARK: - Inline warning icon

/// Tiny inline warning glyph rendered beside a vital value text.
/// Renders nothing when the status is normal/unknown, so callers
/// can drop it into an `HStack` unconditionally.
struct VitalWarningIcon: View {
    let status: VitalStatus
    var size: CGFloat = 16

    var body: some View {
        if status.isAbnormal {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(VitalStatus.high.tint)
                .accessibilityLabel(Text("Out of normal range"))
        }
    }
}

// MARK: - Audible alerter

/// Plays a short system warning sound + vibration the first time
/// a measurement transitions from a normal/unknown state into an
/// abnormal one. We deliberately do NOT replay on every update
/// while the value stays abnormal — the icon stays visible to keep
/// the warning present without being annoying.
final class VitalAlerter {
    private var lastStatus: VitalStatus = .unknown
    private var lastFiredAt: Date = .distantPast

    /// Call whenever a new measurement is computed.
    /// - Parameter status: the freshly-evaluated `VitalStatus`.
    /// - Returns: `true` when a beep was actually emitted (useful
    ///   for tests / debug logging).
    @discardableResult
    func evaluate(_ status: VitalStatus) -> Bool {
        defer { lastStatus = status }
        guard status.isAbnormal, !lastStatus.isAbnormal else { return false }
        // 3 s debounce — guards against multiple onChange handlers
        // settling in quick succession when several BLE fields
        // update almost simultaneously (e.g. systolic + diastolic
        // arriving in the same frame).
        guard Date().timeIntervalSince(lastFiredAt) > 3 else { return false }
        lastFiredAt = Date()
        // SystemSoundID 1107 = "Anticipate" – short attention chime
        // that is available on every iOS device without bundling a
        // custom asset.
        AudioServicesPlaySystemSound(1107)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        return true
    }
}
