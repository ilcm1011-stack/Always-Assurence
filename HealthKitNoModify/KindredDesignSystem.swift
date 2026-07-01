//
//  KindredDesignSystem.swift
//  HealthKitNoModify
//
//  A drop-in design system that re-skins the app to match the soft
//  blue / lavender / heart aesthetic of the AppIcon.
//
//  USAGE
//  -----
//  1. Drag this file into the HealthKitNoModify target in Xcode.
//  2. Replace ContentView.swift with the redesigned version that ships
//     alongside this file.
//  3. Build & run — no other files need to change. All public API names
//     (HealthButtonStyle, GreenButtonStyle, BigIconLabelStyle) remain
//     identical so existing call sites keep compiling.
//
//  All colors auto-adapt to light / dark mode.
//

import SwiftUI

// MARK: - Brand palette

enum KindredPalette {
    /// Deep navy used for primary text and CTA buttons.
    static let ink         = Color(light: "#1A1B3A", dark: "#F4F2FF")
    static let inkSoft     = Color(light: "#353769", dark: "#D8D5F0")
    static let inkMuted    = Color(light: "#6B6E96", dark: "#9B9CC0")
    static let inkFaint    = Color(light: "#A5A7C5", dark: "#6A6C90")

    /// Soft cornflower → lavender (the icon's gradient).
    static let sky         = Color(hex: "#A4B8E0")
    static let skySoft     = Color(hex: "#CFDCF1")
    static let skyTint     = Color(light: "#E6EEF9", dark: "#1F2147")

    static let lavender    = Color(hex: "#8E89D2")
    static let lavenderSoft = Color(hex: "#B3B0E0")
    static let lavenderTint = Color(light: "#EFE9F5", dark: "#241F44")

    /// Warm apricot (the "spark" accent in the icon).
    static let apricot     = Color(hex: "#F4A574")
    static let apricotDark = Color(hex: "#DD7A3F")
    static let apricotTint = Color(light: "#FFEEDC", dark: "#3B2A1A")

    /// Rose (gentle alerts / hearts).
    static let rose        = Color(hex: "#E58FA8")
    static let roseTint    = Color(light: "#FFEDF2", dark: "#3B1F2A")

    /// Mint (calm vitals / success).
    static let mint        = Color(hex: "#6BB89A")
    static let mintSoft    = Color(hex: "#8DC9B0")
    static let mintTint    = Color(light: "#E5F3EC", dark: "#1A2E25")

    /// Backgrounds.
    static let canvas      = Color(light: "#F4F7FC", dark: "#0E1024")
    static let surface     = Color(light: "#FFFFFF", dark: "#181A33")
    static let surfaceAlt  = Color(light: "#F8FAFE", dark: "#13152B")
    static let hairline    = Color(light: "#1A1B3A", dark: "#FFFFFF").opacity(0.08)
}

// MARK: - Gradients

enum KindredGradients {
    /// The signature icon gradient.
    static let icon = LinearGradient(
        colors: [Color(hex: "#A4B8E0"), Color(hex: "#C5BCDA"), Color(hex: "#D8BFD8")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Page atmosphere — sky → lavender → cream.
    static let atmosphere = LinearGradient(
        colors: [
            Color(light: "#E6EEF9", dark: "#11132B"),
            Color(light: "#EFE9F5", dark: "#1B1735"),
            Color(light: "#F8EEE6", dark: "#251A2F")
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Hero schedule tile.
    static let primary = LinearGradient(
        colors: [Color(hex: "#6B8AD6"), Color(hex: "#8E89D2")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Vital signs (oximeter / BP / thermometer).
    static let vitals = LinearGradient(
        colors: [Color(hex: "#B59FE0"), Color(hex: "#8E89D2")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let warmth = LinearGradient(
        colors: [Color(hex: "#F4A574"), Color(hex: "#E58FA8")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let calm = LinearGradient(
        colors: [Color(hex: "#6BB89A"), Color(hex: "#8DC9B0")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Reusable card modifier

struct KindredCardStyle: ViewModifier {
    var radius: CGFloat = 22
    var padding: CGFloat = 16
    var tinted: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tinted ?? KindredPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(KindredPalette.hairline, lineWidth: 0.7)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func kindredCard(radius: CGFloat = 22, padding: CGFloat = 16, tinted: Color? = nil) -> some View {
        modifier(KindredCardStyle(radius: radius, padding: padding, tinted: tinted))
    }
}

// MARK: - Icon badge (used by tiles & headers)

struct KindredIconBadge: View {
    let systemName: String
    let gradient: LinearGradient
    var size: CGFloat = 40
    var iconScale: CGFloat = 0.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(gradient)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 5)

            Image(systemName: systemName)
                .font(.system(size: size * iconScale, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                .blendMode(.overlay)
        )
    }
}

// MARK: - Re-styled button & label styles
// (Same names as the originals so existing call sites need no changes.)

/// A premium tile button for primary navigation actions
/// (Schedule Board, Scan, Handoff, Settings, …).
/// Adapts automatically: tiles whose icon size hints they are "hero"
/// tiles get a richer gradient background; smaller tiles stay
/// frosted-white for a calm grid look.
struct HealthButtonStyle: ButtonStyle {
    var accent: LinearGradient = KindredGradients.primary
    var hero: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if hero {
                // ~10% slimmer than the previous hero tile so it takes
                // less vertical real estate on the homepage.
                configuration.label
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(accent)
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 126, height: 126)
                                .offset(x: 28, y: -46)
                                .blur(radius: 4)
                            Circle()
                                .fill(Color.white.opacity(0.10))
                                .frame(width: 72, height: 72)
                                .offset(x: -100, y: 22)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    )
                    .shadow(color: KindredPalette.lavender.opacity(0.32), radius: 12, x: 0, y: 7)
            } else {
                configuration.label
                    .foregroundStyle(KindredPalette.ink)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(KindredPalette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(KindredPalette.hairline, lineWidth: 0.7)
                    )
                    .shadow(color: KindredPalette.lavender.opacity(0.12), radius: 12, x: 0, y: 6)
            }
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .opacity(configuration.isPressed ? 0.92 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Vital-sign measurement tile (Oximeter / Thermometer / Blood Pressure).
/// Same footprint as the regular tile but with a warm tinted background
/// so caregivers can spot "things to measure right now" at a glance.
struct GreenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(KindredPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 110)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(KindredPalette.mintTint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(KindredPalette.mint.opacity(0.25), lineWidth: 0.8)
            )
            .shadow(color: KindredPalette.mint.opacity(0.18), radius: 12, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Refined label that renders the SF Symbol inside a rounded gradient
/// badge above the title — the "modern app tile" look.
/// When `iconSize >= 40` (used for the hero Schedule tile) the layout
/// switches to a horizontal arrangement.
struct BigIconLabelStyle: LabelStyle {
    var iconSize: CGFloat = 34
    var spacing: CGFloat = 10
    var badgeGradient: LinearGradient = KindredGradients.vitals
    var titleColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let isHero = iconSize >= 40

        if isHero {
            // Hero tile (Care Schedule): centered icon + title, scaled
            // ~10% smaller than before to free up vertical space.
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                    configuration.icon
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 50, height: 50)

                configuration.title
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(titleColor ?? .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // Standard tile — larger icon badge and label for easier
            // tapping / readability for elder caregivers.
            VStack(spacing: spacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(badgeGradient)
                        .frame(width: 56, height: 56)
                        .shadow(color: Color.black.opacity(0.18), radius: 7, x: 0, y: 5)
                    configuration.icon
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
                configuration.title
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(titleColor ?? KindredPalette.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Color helpers

extension Color {
    /// Hex helper: `Color(hex: "#1A1B3A")` or `Color(hex: "1A1B3A")`.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                   .replacingOccurrences(of: "#", with: "")
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch s.count {
        case 6: (a, r, g, b) = (255, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24 & 0xFF, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self = Color(.sRGB,
                     red:   Double(r) / 255,
                     green: Double(g) / 255,
                     blue:  Double(b) / 255,
                     opacity: Double(a) / 255)
    }

    /// Light / dark adaptive color via hex strings.
    init(light: String, dark: String) {
        #if canImport(UIKit)
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
        #else
        self = Color(hex: light)
        #endif
    }
}
