//
//  ContentView.swift
//  VibeCoding1
//
//  Created by chapman on 15/8/2025.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("preferredColorScheme") private var preferredColorScheme = "system"
    @StateObject private var hk = HealthKitManager.shared
    @StateObject private var scheduleManager = CareScheduleManager.shared
    @Environment(\.openURL) private var openURL
    @State private var showNotifyAlert = false
    @State private var notifyResultMessage = ""
    @State private var lastSentScheduleWarning: String? = nil
    @State private var showAppointmentScanner = false

    private var colorScheme: ColorScheme? {
        switch preferredColorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private let buttonColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(
                        colors: [Color(.systemTeal).opacity(0.15), Color(.systemBackground)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 18) {
                        // ── Top section: header, warnings, patient overview.
                        //    Wrapped in its own ScrollView with a visible
                        //    indicator so long alert text can be scrolled
                        //    without eating into the function-button area.
                        AlwaysVisibleScrollView {
                            VStack(spacing: 20) {
                                VStack(spacing: 14) {
                                    HStack(alignment: .center, spacing: 14) {
                                        Image(systemName: "checkmark.shield.fill")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 44, height: 44)
                                            .foregroundColor(.blue)

                                        Text(settings.localized("home.title"))
                                            .font(settings.scaledFont(36, weight: .bold))
                                            .multilineTextAlignment(.leading)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color(.systemBackground).opacity(0.92))
                                    .cornerRadius(18)
                                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 4)

                                    Text(settings.localized("home.subtitle"))
                                        .font(settings.scaledFont(18))
                                        .lineSpacing(6)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 8)

                                if let gapAlert = scheduleManager.gapAlert {
                                    gapAlertCard(message: gapAlert)
                                }
                                if let unassignedWarning = scheduleManager.unassignedShiftWarning {
                                    unassignedShiftWarningCard(message: unassignedWarning)
                                }
                                if let warning = scheduleManager.appointmentAssignmentWarning {
                                    appointmentAssignmentWarningCard(message: warning)
                                }
                                if scheduleManager.upcomingScheduleWarning != nil {
                                    scheduleAlertCard
                                }

                                patientOverviewCard
                                    .padding(.horizontal)
                            }
                            .padding(.bottom, 8)
                        }
                        .frame(maxHeight: geometry.size.height * 0.5)

                        // ── Bottom section: function buttons. Forced to
                        //    occupy at least half of the available height
                        //    so each tile is finger-friendly. Wrapped in
                        //    its own ScrollView (with visible indicator)
                        //    in case the user has scaled the font up and
                        //    the buttons no longer fit.
                        AlwaysVisibleScrollView {
                            VStack(spacing: 16) {
                                NavigationLink(destination: ScheduleBoardView().environmentObject(settings)) {
                                    Label(settings.localized("home.scheduleBoard"), systemImage: "calendar")
                                        .font(.title2)
                                        .frame(maxWidth: .infinity, minHeight: 110)
                                }
                                .buttonStyle(HealthButtonStyle())

                                HStack(spacing: 16) {
                                    NavigationLink(destination: OximeterView().environmentObject(settings)) {
                                        Label(settings.localized("home.oximeter"), systemImage: "waveform.path.ecg")
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                    }
                                    .buttonStyle(GreenButtonStyle())

                                    Button(action: {
                                        showAppointmentScanner = true
                                    }) {
                                        Label(settings.localized("health.scanAppointment"), systemImage: "doc.text.viewfinder")
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                    }
                                    .buttonStyle(HealthButtonStyle())
                                }

                                HStack(spacing: 16) {
                                    NavigationLink(destination: ThermometerView().environmentObject(settings)) {
                                        Label(settings.localized("home.thermometer"), systemImage: "thermometer")
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                    }
                                    .buttonStyle(GreenButtonStyle())

                                    NavigationLink(destination: HandoffView().environmentObject(settings)) {
                                        Label(settings.localized("home.handoff"), systemImage: "book")
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                    }
                                    .buttonStyle(HealthButtonStyle())
                                }

                                HStack(spacing: 16) {
                                    NavigationLink(destination: BloodPressureMeterView().environmentObject(settings)) {
                                        Label(settings.localized("home.bloodPressure"), systemImage: "heart.circle")
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                    }
                                    .buttonStyle(GreenButtonStyle())

                                    NavigationLink(destination: SettingsView().environmentObject(settings)) {
                                        Label(settings.localized("home.settings"), systemImage: "gearshape")
                                            .frame(maxWidth: .infinity, minHeight: 90)
                                    }
                                    .buttonStyle(HealthButtonStyle())
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }
                        .frame(minHeight: geometry.size.height * 0.5)
                    }
                    .padding(.vertical)
                    .id(settings.fontScale)
                }
            }
            .navigationTitle(settings.localized("home.healthDashboard"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                NSLog("[HealthKitNoModify] ContentView onAppear")
                print("[HealthKitNoModify] ContentView onAppear")
                if let warning = scheduleManager.upcomingScheduleWarning {
                    autoNotifyMissingScheduleIfNeeded(warning: warning)
                }
            }
            .fullScreenCover(isPresented: $showAppointmentScanner) {
                AppointmentScannerView(initialCameraScan: true)
                    .environmentObject(settings)
            }
            .onChange(of: scheduleManager.upcomingScheduleWarning) { _, newValue in
                if let warning = newValue {
                    autoNotifyMissingScheduleIfNeeded(warning: warning)
                }
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private func sendMissingScheduleEmail(to caregiver: Caregiver, message: String) {
        guard !caregiver.email.isEmpty else { return }

        var components = URLComponents(string: Setting.shared.appScriptUrl)
        components?.queryItems = [
            URLQueryItem(name: "sheetId", value: Setting.shared.sheetId),
            URLQueryItem(name: "sheetName", value: "email_reminder"),
            URLQueryItem(name: "recipient", value: caregiver.email),
            URLQueryItem(name: "subject", value: settings.localized("schedule.emailAlertSubject")),
            URLQueryItem(name: "body", value: message),
            URLQueryItem(name: "user", value: Setting.shared.username)
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

        let message = String(format: settings.localized("schedule.emailAlertBody"), scheduleManager.upcomingScheduleWarning ?? "")

        let emails = caregivers.filter { !$0.email.isEmpty }
        for caregiver in emails {
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
        let emails = scheduleManager.caregivers.filter { !$0.email.isEmpty }
        for caregiver in emails {
            sendMissingScheduleEmail(to: caregiver, message: message)
        }
    }

    private var scheduleAlertCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.localized("home.scheduleMissingWarningTitle"))
                .font(settings.scaledFont(18, weight: .semibold))
            Text(settings.localized("home.scheduleMissingWarningMessage"))
                .font(settings.scaledFont(14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(scheduleManager.upcomingScheduleWarning ?? "")
                .font(settings.scaledFont(13))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: notifyAllCaregivers) {
                Text(settings.localized("schedule.notifyAllCaregivers"))
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBlue))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
        }
        .padding()
        .background(Color(.systemRed).opacity(0.12))
        .cornerRadius(18)
        .padding(.horizontal)
        .alert(settings.localized("schedule.notifyAllCaregivers"), isPresented: $showNotifyAlert) {
            Button(settings.localized("home.ok"), role: .cancel) {}
        } message: {
            Text(notifyResultMessage)
        }
    }

    private func gapAlertCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.localized("home.scheduleGapWarningTitle"))
                .font(settings.scaledFont(18, weight: .semibold))
            Text(message)
                .font(settings.scaledFont(14))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color(.systemRed).opacity(0.12))
        .cornerRadius(18)
        .padding(.horizontal)
    }

    /// Small red banner on the homepage that's visible whenever any
    /// future shift is in the `.unassigned` state. Tapping the banner
    /// takes the user straight to the Care Schedule Board where they
    /// can assign a caregiver.
    private func unassignedShiftWarningCard(message: String) -> some View {
        NavigationLink(destination: ScheduleBoardView().environmentObject(settings)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.localized("home.unassignedShiftWarningTitle"))
                        .font(settings.scaledFont(16, weight: .semibold))
                        .foregroundColor(.red)
                    Text(message)
                        .font(settings.scaledFont(13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemRed).opacity(0.12))
            .cornerRadius(14)
            .padding(.horizontal)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func appointmentAssignmentWarningCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.localized("home.appointmentAssignmentWarningTitle"))
                .font(settings.scaledFont(18, weight: .semibold))
            Text(message)
                .font(settings.scaledFont(14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(destination: ScheduleBoardView().environmentObject(settings)) {
                Text(settings.localized("home.viewScheduleBoard"))
                    .font(settings.scaledFont(16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBlue))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
        }
        .padding()
        .background(Color(.systemOrange).opacity(0.12))
        .cornerRadius(18)
        .padding(.horizontal)
    }

    private var patientOverviewCard: some View {
        NavigationLink(destination: PatientProfileView().environmentObject(settings)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.localized("home.profileTitle"))
                            .font(settings.scaledFont(16, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(settings.patientName)
                            .font(settings.scaledFont(22, weight: .bold))
                        Text("\(settings.localized("home.patientAge")): \(settings.patientAge) · \(settings.localized(settings.patientGenderKey))")
                            .font(settings.scaledFont(14))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if hk.anomalyMessage != nil {
                        Text(settings.localized("health.anomalyAlert"))
                            .font(settings.scaledFont(12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.red)
                            .cornerRadius(12)
                    }
                }

                HStack(spacing: 12) {
                    if let temp = hk.temperature {
                        Text(String(format: "%@ %.1f°C", settings.localized("schedule.temperature"), temp))
                            .font(settings.scaledFont(12))
                            .foregroundColor(temp > 37.2 || temp < 36.0 ? .red : .primary)
                    } else {
                        Text(settings.localized("schedule.temperature") + " --")
                            .font(settings.scaledFont(12))
                            .foregroundColor(.secondary)
                    }

                    if let spo2 = hk.oxygenSaturation {
                        Text(String(format: "%@ %.0f%%", settings.localized("schedule.spo2"), spo2 * 100.0))
                            .font(settings.scaledFont(12))
                            .foregroundColor(spo2 < 0.95 ? .red : .primary)
                    } else {
                        Text(settings.localized("schedule.spo2") + " --")
                            .font(settings.scaledFont(12))
                            .foregroundColor(.secondary)
                    }

                    if let sys = hk.systolicPressure, let dia = hk.diastolicPressure {
                        Text(String(format: "%@ %d/%d", settings.localized("schedule.bloodPressureMeasurement"), Int(sys), Int(dia)))
                            .font(settings.scaledFont(12))
                            .foregroundColor((sys > 120 || dia > 80) ? .red : .primary)
                    } else {
                        Text(settings.localized("schedule.bloodPressureMeasurement") + " --")
                            .font(settings.scaledFont(12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(18)
        }
        .fullScreenCover(isPresented: $showAppointmentScanner) {
            AppointmentScannerView(initialCameraScan: true)
                .environmentObject(settings)
        }
        .onChange(of: scheduleManager.upcomingScheduleWarning) { _, newValue in
            if let warning = newValue {
                autoNotifyMissingScheduleIfNeeded(warning: warning)
            }
        }

        .buttonStyle(PlainButtonStyle())
    }

}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("preferredColorScheme") private var preferredColorScheme = "system"
    @State private var tempLanguage: AppLanguage? = nil
    @State private var showLanguageAlert = false
    @State private var tempFontScale: Double = 1.0
    @State private var showFontConfirm = false
    @State private var pendingFontScale: Double? = nil

    var body: some View {
        Form {
            Section(header: Text(settings.localized("home.fontSize"))) {
                HStack {
                    Text(settings.localized("home.fontSize"))
                        .font(settings.scaledFont(16, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.0f%%", settings.fontScale * 100))
                        .font(settings.scaledFont(14))
                        .foregroundColor(.secondary)
                }

                Slider(value: $tempFontScale, in: 0.8...1.4, step: 0.05, onEditingChanged: { editing in
                    if !editing {
                        if abs(tempFontScale - settings.fontScale) > 0.001 {
                            pendingFontScale = tempFontScale
                            showFontConfirm = true
                        }
                    }
                })
                .onAppear { tempFontScale = settings.fontScale }
            }

            Section(header: Text(settings.localized("home.language"))) {
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
            }

            Section(header: Text(settings.localized("home.theme"))) {
                Picker(settings.localized("home.theme"), selection: $preferredColorScheme) {
                    Text(settings.localized("home.system")).tag("system")
                    Text(settings.localized("home.light")).tag("light")
                    Text(settings.localized("home.dark")).tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(settings.localized("home.settings"))
        .alert(settings.localized("home.changeLanguageTitle"), isPresented: $showLanguageAlert) {
            Button(settings.localized("home.cancel"), role: .cancel) {
                tempLanguage = nil
            }
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

struct HealthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 68)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemTeal))
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .shadow(color: Color(.black).opacity(configuration.isPressed ? 0.08 : 0.16), radius: 10, x: 0, y: 6)
    }
}

struct GreenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 68)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0/255, green: 177/255, blue: 64/255))
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .shadow(color: Color(.black).opacity(configuration.isPressed ? 0.08 : 0.16), radius: 10, x: 0, y: 6)
    }
}

// Schedule settings moved into ScheduleBoardView

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppSettings.shared)
    }
}
