//
//  ContentView.swift
//  HealthKitNoModify
//
//  Redesigned home view — same navigation, scheduling, HealthKit and
//  warning logic as the original; only the visual layer changes.
//
//  Requires KindredDesignSystem.swift to be added to the target.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    // Default to the light theme — caregivers asked for the brighter,
    // higher-contrast appearance to be the out-of-box experience.
    @AppStorage("preferredColorScheme") private var preferredColorScheme = "light"
    @StateObject private var hk = HealthKitManager.shared
    @StateObject private var scheduleManager = CareScheduleManager.shared
    @Environment(\.openURL) private var openURL
    @State private var showNotifyAlert = false
    @State private var notifyResultMessage = ""
    @State private var lastSentScheduleWarning: String? = nil
    @State private var showAppointmentScanner = false
    @State private var showMedicineScanner = false

    private var colorScheme: ColorScheme? {
        switch preferredColorScheme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    // ── Atmospheric background ───────────────────────────
                    KindredGradients.atmosphere
                        .ignoresSafeArea()

                    // Floating color orbs for depth (very subtle).
                    backgroundOrbs
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    VStack(spacing: 12) {
                        // ── Brand header card ────────────────────────────
                        brandHeaderCard
                            .padding(.horizontal)
                            .padding(.top, 2)

                        // ── Family + caregivers row ──────────────────────
                        familyAndCaregiversSection(totalWidth: geometry.size.width)
                            .padding(.horizontal)

                        // ── Reminders section (scrollable) ───────────────
                        // Slimmer cap so the Care Schedule tile below
                        // can move up the screen.
                        AlwaysVisibleScrollView {
                            remindersSection
                                .padding(.bottom, 4)
                        }
                        .frame(maxHeight: geometry.size.height * 0.20)

                        // ── Function tiles ───────────────────────────────
                        // Small top padding so the Care Schedule hero
                        // tile's rounded top edge + shadow aren't clipped
                        // by AlwaysVisibleScrollView's content bounds,
                        // while still sitting close to the reminders row.
                        AlwaysVisibleScrollView {
                            functionTiles
                                .padding(.horizontal)
                                .padding(.top, 10)
                                .padding(.bottom, 12)
                        }
                        .frame(minHeight: geometry.size.height * 0.5)
                    }
                    .padding(.vertical)
                    .id(settings.fontScale)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                NSLog("[HealthKitNoModify] ContentView onAppear")
                print("[HealthKitNoModify] ContentView onAppear")
                // Seed demo "Check Now" vitals for the default 晨婆
                // profile so the colour-coded warnings + check-now pill
                // are visible immediately on a fresh install. Real
                // measurements (HealthKit / BLE) override these as soon
                // as they come in.
                hk.seedDemoDefaultsIfNeeded(patientName: settings.patientName)
                if let warning = scheduleManager.upcomingScheduleWarning {
                    autoNotifyMissingScheduleIfNeeded(warning: warning)
                }
            }
            .fullScreenCover(isPresented: $showAppointmentScanner) {
                AppointmentScannerView(initialCameraScan: true)
                    .environmentObject(settings)
            }
            .fullScreenCover(isPresented: $showMedicineScanner) {
                MedicineScannerView()
                    .environmentObject(settings)
            }
            .onChange(of: scheduleManager.upcomingScheduleWarning) { _, newValue in
                if let warning = newValue {
                    autoNotifyMissingScheduleIfNeeded(warning: warning)
                }
            }
        }
        .preferredColorScheme(colorScheme)
        .tint(KindredPalette.lavender)
    }

    // MARK: - Background

    private var backgroundOrbs: some View {
        ZStack {
            Circle()
                .fill(KindredPalette.sky.opacity(0.35))
                .frame(width: 320, height: 320)
                .blur(radius: 60)
                .offset(x: -140, y: -260)
            Circle()
                .fill(KindredPalette.lavender.opacity(0.30))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: 160, y: -120)
            Circle()
                .fill(KindredPalette.apricot.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 65)
                .offset(x: -100, y: 320)
        }
    }

    // MARK: - Brand header

    private var brandHeaderCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                appIconImage
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(KindredPalette.lavender.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: KindredPalette.lavender.opacity(0.35), radius: 10, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.localized("home.title"))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(KindredPalette.ink)
                        .minimumScaleFactor(0.55)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(KindredPalette.mint)
                            .frame(width: 6, height: 6)
                        Text(settings.localized("home.subtitle"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(KindredPalette.inkMuted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(KindredPalette.surface.opacity(0.85))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(KindredGradients.icon.opacity(0.10))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(KindredPalette.lavender.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: KindredPalette.lavender.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    // MARK: - Function tiles

    @ViewBuilder
    private var functionTiles: some View {
        VStack(spacing: 14) {
            // Hero schedule tile — compact (no longer overlaps the
            // reminder banner above or the tile grid below) but with
            // a larger, centered icon + title.
            NavigationLink(destination: ScheduleBoardView().environmentObject(settings)) {
                Label(settings.localized("home.scheduleBoard"), systemImage: "calendar")
                    .labelStyle(BigIconLabelStyle(iconSize: 42))
            }
            .buttonStyle(HealthButtonStyle(accent: KindredGradients.primary, hero: true))

            HStack(spacing: 14) {
                NavigationLink(destination: OximeterView().environmentObject(settings)) {
                    Label(settings.localized("home.oximeter"), systemImage: "waveform.path.ecg")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.vitals))
                }
                .buttonStyle(GreenButtonStyle())

                Button {
                    showAppointmentScanner = true
                } label: {
                    Label(settings.localized("health.scanAppointment"), systemImage: "doc.text.viewfinder")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.warmth))
                }
                .buttonStyle(HealthButtonStyle())
            }

            HStack(spacing: 14) {
                NavigationLink(destination: ThermometerView().environmentObject(settings)) {
                    Label(settings.localized("home.thermometer"), systemImage: "thermometer")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.warmth))
                }
                .buttonStyle(GreenButtonStyle())

                Button {
                    showMedicineScanner = true
                } label: {
                    Label(settings.localized("health.scanMedicine"), systemImage: "pills.fill")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.calm))
                }
                .buttonStyle(HealthButtonStyle())
            }

            HStack(spacing: 14) {
                NavigationLink(destination: BloodPressureMeterView().environmentObject(settings)) {
                    Label(settings.localized("home.bloodPressure"), systemImage: "heart.circle")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.warmth))
                }
                .buttonStyle(GreenButtonStyle())

                NavigationLink(destination: HandoffView().environmentObject(settings)) {
                    Label(settings.localized("home.handoff"), systemImage: "book")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.primary))
                }
                .buttonStyle(HealthButtonStyle())
            }

            HStack(spacing: 14) {
                // Invisible spacer to keep Settings in the right column.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 110)

                NavigationLink(destination: SettingsView().environmentObject(settings)) {
                    Label(settings.localized("home.settings"), systemImage: "gearshape")
                        .labelStyle(BigIconLabelStyle(spacing: 12, badgeGradient: KindredGradients.vitals))
                }
                .buttonStyle(HealthButtonStyle())
            }
        }
    }

    // MARK: - Notification helpers (unchanged from original)

    private func sendMissingScheduleEmail(to caregiver: Caregiver, message: String) {
        guard !caregiver.email.isEmpty else { return }

        var components = URLComponents(string: Setting.shared.appScriptUrl)
        components?.queryItems = [
            URLQueryItem(name: "sheetId",   value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: "email_reminder"),
            URLQueryItem(name: "recipient", value: caregiver.email),
            URLQueryItem(name: "subject",   value: settings.localized("schedule.emailAlertSubject")),
            URLQueryItem(name: "body",      value: message),
            URLQueryItem(name: "user",      value: Setting.shared.username)
        ]

        guard let url = components?.url else { return }
        URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
    }

    private func sendMissingScheduleSMS(to phones: [String], body: String) {
        let toList = phones
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: ",")
        guard !toList.isEmpty,
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let finalUrl = URL(string: "sms:\(toList)?body=\(encodedBody)") else { return }
        openURL(finalUrl)
    }

    private func notifyAllCaregivers() {
        let caregivers = scheduleManager.caregivers
        guard !caregivers.isEmpty else {
            notifyResultMessage = settings.localized("home.noCaregivers")
            showNotifyAlert = true
            return
        }

        let message = String(format: settings.localized("schedule.emailAlertBody"),
                             scheduleManager.upcomingScheduleWarning ?? "")

        for caregiver in caregivers where !caregiver.email.isEmpty {
            sendMissingScheduleEmail(to: caregiver, message: message)
        }

        let phones = caregivers.compactMap { $0.phone.isEmpty ? nil : $0.phone }
        if !phones.isEmpty {
            sendMissingScheduleSMS(to: phones, body: message)
        }

        notifyResultMessage = settings.localized("schedule.notifyAllCaregiversSent")
        showNotifyAlert = true
    }

    private func autoNotifyMissingScheduleIfNeeded(warning: String) {
        guard lastSentScheduleWarning != warning else { return }
        lastSentScheduleWarning = warning

        let message = String(format: settings.localized("schedule.emailAlertBody"), warning)
        for caregiver in scheduleManager.caregivers where !caregiver.email.isEmpty {
            sendMissingScheduleEmail(to: caregiver, message: message)
        }
    }

    // MARK: - Reminder cards (re-skinned)

    private var scheduleAlertCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                KindredIconBadge(systemName: "calendar.badge.exclamationmark",
                                 gradient: KindredGradients.warmth,
                                 size: 36)
                Text(settings.localized("home.scheduleMissingWarningTitle"))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(KindredPalette.ink)
            }
            Text(settings.localized("home.scheduleMissingWarningMessage"))
                .font(settings.scaledFont(14))
                .foregroundStyle(KindredPalette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text(scheduleManager.upcomingScheduleWarning ?? "")
                .font(settings.scaledFont(13, weight: .semibold))
                .foregroundStyle(KindredPalette.apricotDark)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: notifyAllCaregivers) {
                Text(settings.localized("schedule.notifyAllCaregivers"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(KindredGradients.primary)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: KindredPalette.lavender.opacity(0.35), radius: 10, x: 0, y: 6)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(KindredPalette.apricotTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(KindredPalette.apricot.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal)
        .alert(settings.localized("schedule.notifyAllCaregivers"), isPresented: $showNotifyAlert) {
            Button(settings.localized("home.ok"), role: .cancel) {}
        } message: {
            Text(notifyResultMessage)
        }
    }

    private func gapAlertCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                KindredIconBadge(systemName: "exclamationmark.bubble.fill",
                                 gradient: KindredGradients.warmth,
                                 size: 32)
                Text(settings.localized("home.scheduleGapWarningTitle"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(KindredPalette.ink)
            }
            Text(message)
                .font(settings.scaledFont(13))
                .foregroundStyle(KindredPalette.apricotDark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KindredPalette.apricotTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(KindredPalette.apricot.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func unassignedShiftWarningCard(message: String) -> some View {
        NavigationLink(destination: ScheduleBoardView().environmentObject(settings)) {
            HStack(alignment: .center, spacing: 12) {
                KindredIconBadge(systemName: "person.fill.questionmark",
                                 gradient: KindredGradients.warmth,
                                 size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.localized("home.unassignedShiftWarningTitle"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(KindredPalette.ink)
                    Text(message)
                        .font(settings.scaledFont(12))
                        .foregroundStyle(KindredPalette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KindredPalette.inkFaint)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KindredPalette.apricotTint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(KindredPalette.apricot.opacity(0.30), lineWidth: 1)
            )
            .padding(.horizontal)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func appointmentAssignmentWarningCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                KindredIconBadge(systemName: "stethoscope",
                                 gradient: KindredGradients.warmth,
                                 size: 36)
                Text(settings.localized("home.appointmentAssignmentWarningTitle"))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(KindredPalette.ink)
            }
            Text(message)
                .font(settings.scaledFont(14))
                .foregroundStyle(KindredPalette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(destination: ScheduleBoardView().environmentObject(settings)) {
                Text(settings.localized("home.viewScheduleBoard"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(KindredGradients.primary)
                    )
                    .foregroundStyle(.white)
                    .shadow(color: KindredPalette.lavender.opacity(0.30), radius: 10, x: 0, y: 6)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(KindredPalette.apricotTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(KindredPalette.apricot.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // MARK: - Header helpers

    private var appIconImage: some View {
        Group {
            if let uiImage = Self.loadAppIcon() {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback gradient mark that matches the brand.
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(KindredGradients.icon)
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private static func loadAppIcon() -> UIImage? {
        if let direct = UIImage(named: "AppIcon") {
            return direct
        }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let lastFile = files.last else {
            return nil
        }
        return UIImage(named: lastFile)
    }

    // MARK: - Family + caregivers row

    private func familyAndCaregiversSection(totalWidth: CGFloat) -> some View {
        let horizontalPadding: CGFloat = 32
        let spacing: CGFloat = 12
        let usableWidth = max(totalWidth - horizontalPadding, 0)
        let patientWidth = max((usableWidth - spacing) * 0.62, 0)
        let caregiversWidth = max(usableWidth - spacing - patientWidth, 0)

        return HStack(alignment: .top, spacing: spacing) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("home.familyInfoTitle", systemImage: "person.2.fill")
                patientOverviewCard
            }
            .frame(width: patientWidth, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("home.caregiversTitle", systemImage: "heart.text.square.fill")
                caregiversListCard
            }
            .frame(width: caregiversWidth, alignment: .topLeading)
        }
    }

    private func sectionLabel(_ key: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(KindredPalette.lavender)
            Text(settings.localized(key))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(KindredPalette.inkMuted)
                .textCase(.uppercase)
        }
    }

    private var caregiversListCard: some View {
        // Tapping the caregivers card on the home screen jumps straight
        // into Family Info → Add Caregiver (per family caregiver request).
        NavigationLink(destination: PatientProfileView(openAddCaregiverOnAppear: true).environmentObject(settings)) {
            VStack(alignment: .leading, spacing: 10) {
                if scheduleManager.caregivers.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(KindredPalette.lavender)
                        Text(settings.localized("home.noCaregivers"))
                            .font(settings.scaledFont(13))
                            .foregroundStyle(KindredPalette.inkMuted)
                    }
                } else {
                    ForEach(Array(scheduleManager.caregivers.prefix(4).enumerated()), id: \.element.id) { index, caregiver in
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(caregiverDotColor(index: index))
                                    .frame(width: 28, height: 28)
                                Text(caregiver.icon.isEmpty ? "👤" : caregiver.icon)
                                    .font(.system(size: 15))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(caregiver.name)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(KindredPalette.ink)
                                    .lineLimit(1)
                                if !caregiver.phone.isEmpty {
                                    Text(caregiver.phone)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(KindredPalette.inkMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if scheduleManager.caregivers.count > 4 {
                        Text(String(format: settings.localized("home.caregiversMore"),
                                    scheduleManager.caregivers.count - 4))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(KindredPalette.lavender)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(KindredPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(KindredPalette.hairline, lineWidth: 0.7)
            )
            .shadow(color: KindredPalette.lavender.opacity(0.10), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func caregiverDotColor(index: Int) -> Color {
        let colors: [Color] = [
            KindredPalette.mint,
            KindredPalette.apricot,
            KindredPalette.lavender,
            KindredPalette.rose
        ]
        return colors[index % colors.count].opacity(0.85)
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        let hasUnassigned = scheduleManager.unassignedShiftWarning != nil
        let hasAppt = scheduleManager.appointmentAssignmentWarning != nil
        let hasSched = scheduleManager.upcomingScheduleWarning != nil
        let hasAny = hasUnassigned || hasAppt || hasSched

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(KindredPalette.apricot.opacity(0.18))
                        .frame(width: 24, height: 24)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(KindredPalette.apricotDark)
                }
                Text(settings.localized("home.remindersTitle"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(KindredPalette.inkSoft)
                Spacer()
                if hasAny {
                    Text("\((hasUnassigned ? 1 : 0) + (hasAppt ? 1 : 0) + (hasSched ? 1 : 0))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(KindredPalette.apricotDark))
                }
            }
            .padding(.horizontal)

            if !hasAny {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(KindredPalette.mint)
                    Text(settings.localized("home.remindersEmpty"))
                        .font(settings.scaledFont(14))
                        .foregroundStyle(KindredPalette.inkMuted)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(KindredPalette.mintTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(KindredPalette.mint.opacity(0.20), lineWidth: 0.8)
                )
                .padding(.horizontal)
            } else {
                VStack(spacing: 12) {
                    if let unassignedWarning = scheduleManager.unassignedShiftWarning {
                        unassignedShiftWarningCard(message: unassignedWarning)
                    }
                    if let warning = scheduleManager.appointmentAssignmentWarning {
                        appointmentAssignmentWarningCard(message: warning)
                    }
                    if scheduleManager.upcomingScheduleWarning != nil {
                        scheduleAlertCard
                    }
                }
            }
        }
    }

    // MARK: - Patient overview card

    private var patientOverviewCard: some View {
        NavigationLink(destination: PatientProfileView().environmentObject(settings)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    // Patient avatar
                    ZStack {
                        Circle()
                            .fill(KindredGradients.warmth)
                            .shadow(color: KindredPalette.rose.opacity(0.35), radius: 6, x: 0, y: 4)
                        Text(initialFor(name: settings.patientName))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.patientName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(KindredPalette.ink)
                            .lineLimit(1)
                        Text("\(settings.localized("home.patientAge")) \(settings.patientAge) · \(settings.localized(settings.patientGenderKey))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(KindredPalette.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // "Check Now" pill — appears in the top-right
                    // whenever ANY vital is outside the reference range
                    // (low or high). Replaces the old generic anomaly
                    // badge so caregivers know to take immediate action.
                    if anyVitalAbnormal {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(settings.localized("health.checkNow"))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .background(
                            Capsule().fill(VitalStatus.high.tint)
                        )
                        .shadow(color: VitalStatus.high.tint.opacity(0.4), radius: 6, x: 0, y: 3)
                    } else if hk.anomalyMessage != nil {
                        Text(settings.localized("health.anomalyAlert"))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 9)
                            .background(
                                Capsule().fill(KindredGradients.warmth)
                            )
                            .shadow(color: KindredPalette.rose.opacity(0.4), radius: 6, x: 0, y: 3)
                    }
                }

                // Vitals chips — color shifts based on reference range
                // (blue=low, mint=normal, red=high, grey=unknown).
                HStack(spacing: 6) {
                    vitalChip(
                        label: settings.localized("schedule.temperature"),
                        value: hk.temperature.map { String(format: "%.1f°", $0) } ?? "—",
                        status: tempStatus,
                        systemImage: "thermometer"
                    )
                    vitalChip(
                        label: settings.localized("schedule.spo2"),
                        value: hk.oxygenSaturation.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                        status: spo2Status,
                        systemImage: "lungs.fill"
                    )
                    vitalChip(
                        label: settings.localized("schedule.bloodPressureMeasurement"),
                        value: bpString(),
                        status: bpStatus,
                        systemImage: "heart.fill"
                    )
                }
            }
            .padding(14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(KindredPalette.surface)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(KindredGradients.icon.opacity(0.08))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(KindredPalette.hairline, lineWidth: 0.7)
            )
            .shadow(color: KindredPalette.lavender.opacity(0.12), radius: 12, x: 0, y: 6)
        }
        .fullScreenCover(isPresented: $showAppointmentScanner) {
            AppointmentScannerView(initialCameraScan: true)
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showMedicineScanner) {
            MedicineScannerView()
                .environmentObject(settings)
        }
        .onChange(of: scheduleManager.upcomingScheduleWarning) { _, newValue in
            if let warning = newValue {
                autoNotifyMissingScheduleIfNeeded(warning: warning)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func vitalChip(label: String,
                           value: String,
                           status: VitalStatus,
                           systemImage: String) -> some View {
        // Background colour intensity scales with status:
        //  • normal  → faint mint wash
        //  • low/high → stronger tinted background so the abnormal
        //               chip stands out from the calm ones
        //  • unknown → flat grey wash
        let bgOpacity: Double = status.isAbnormal ? 0.22 : 0.10
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: status.isAbnormal ? "exclamationmark.circle.fill" : systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(status.tint)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(status.isAbnormal ? status.tint : KindredPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(status.tint.opacity(bgOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(status.tint.opacity(status.isAbnormal ? 0.5 : 0), lineWidth: 1)
        )
    }

    // MARK: - Vital status helpers (driven by VitalRanges)

    private var tempStatus: VitalStatus {
        VitalRanges.status(hk.temperature, in: VitalRanges.temperatureC)
    }

    private var spo2Status: VitalStatus {
        // hk.oxygenSaturation is stored as a 0–1 fraction; convert to %.
        VitalRanges.status(hk.oxygenSaturation.map { $0 * 100 }, in: VitalRanges.spO2Percent)
    }

    private var systolicStatus: VitalStatus {
        VitalRanges.status(hk.systolicPressure, in: VitalRanges.systolicMmHg)
    }

    private var diastolicStatus: VitalStatus {
        VitalRanges.status(hk.diastolicPressure, in: VitalRanges.diastolicMmHg)
    }

    /// Worst-of systolic & diastolic so the BP chip reflects either being out of range.
    private var bpStatus: VitalStatus {
        if systolicStatus.isAbnormal || diastolicStatus.isAbnormal { return .high } // either out-of-range = warn
        if systolicStatus == .unknown && diastolicStatus == .unknown { return .unknown }
        return .normal
    }

    /// True if any of the tracked vitals is out of its reference range.
    /// Drives the "Check Now" pill in the patient overview card.
    private var anyVitalAbnormal: Bool {
        tempStatus.isAbnormal ||
        spo2Status.isAbnormal ||
        systolicStatus.isAbnormal ||
        diastolicStatus.isAbnormal
    }

    private func bpString() -> String {
        if let sys = hk.systolicPressure, let dia = hk.diastolicPressure {
            return "\(Int(sys))/\(Int(dia))"
        }
        return "—"
    }

    private func initialFor(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first)
    }
}

// MARK: - Settings (re-skinned)

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("preferredColorScheme") private var preferredColorScheme = "light"
    @State private var tempLanguage: AppLanguage? = nil
    @State private var showLanguageAlert = false
    @State private var tempFontScale: Double = 1.0
    @State private var showFontConfirm = false
    @State private var pendingFontScale: Double? = nil

    var body: some View {
        ZStack {
            KindredGradients.atmosphere.ignoresSafeArea()

            Form {
                Section {
                    HStack {
                        Label(settings.localized("home.fontSize"),
                              systemImage: "textformat.size")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(KindredPalette.ink)
                        Spacer()
                        Text(String(format: "%.0f%%", settings.fontScale * 100))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(KindredPalette.lavender)
                    }
                    Slider(value: $tempFontScale, in: 0.8...1.4, step: 0.05) { editing in
                        if !editing, abs(tempFontScale - settings.fontScale) > 0.001 {
                            pendingFontScale = tempFontScale
                            showFontConfirm = true
                        }
                    }
                    .tint(KindredPalette.lavender)
                    .onAppear { tempFontScale = settings.fontScale }
                } header: {
                    Text(settings.localized("home.fontSize"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(KindredPalette.inkMuted)
                }

                Section {
                    Picker(settings.localized("home.language"), selection: Binding(
                        get: { tempLanguage ?? settings.language },
                        set: { newLanguage in
                            if newLanguage != settings.language {
                                tempLanguage = newLanguage
                                showLanguageAlert = true
                            }
                        }
                    )) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(settings.localized("home.language"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(KindredPalette.inkMuted)
                }

                Section {
                    Picker(settings.localized("home.theme"), selection: $preferredColorScheme) {
                        Text(settings.localized("home.system")).tag("system")
                        Text(settings.localized("home.light")).tag("light")
                        Text(settings.localized("home.dark")).tag("dark")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(settings.localized("home.theme"))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(KindredPalette.inkMuted)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(settings.localized("home.settings"))
        .alert(settings.localized("home.changeLanguageTitle"), isPresented: $showLanguageAlert) {
            Button(settings.localized("home.cancel"), role: .cancel) { tempLanguage = nil }
            Button(settings.localized("home.save")) {
                if let newLanguage = tempLanguage {
                    settings.language = newLanguage
                    tempLanguage = nil
                }
            }
        } message: {
            if let lang = tempLanguage {
                Text(String(format: settings.localized("home.changeLanguageMessage"), lang.displayName))
            }
        }
        .alert(settings.localized("home.fontSize"), isPresented: $showFontConfirm) {
            Button(settings.localized("home.cancel"), role: .cancel) {
                tempFontScale = settings.fontScale
                pendingFontScale = nil
            }
            Button(settings.localized("home.save")) {
                if let v = pendingFontScale {
                    settings.fontScale = v
                    pendingFontScale = nil
                }
            }
        } message: {
            if let v = pendingFontScale {
                Text(String(format: "Apply font size %.0f%%?", v * 100))
            }
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppSettings.shared)
    }
}
