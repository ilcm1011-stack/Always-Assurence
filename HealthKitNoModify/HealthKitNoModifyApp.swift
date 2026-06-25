//
//  HealthKitNoModifyApp.swift
//  HealthKitNoModify
//
//  Created by Kehong-IOS-Dev01 on 2025/11/24.
//

import SwiftUI
import UIKit

@main
struct HealthKitNoModifyApp: App {
    @StateObject private var appSettings = AppSettings.shared

    init() {
        // iPadOS 26 hides the system scroll indicator by default as part
        // of the Liquid Glass redesign. Force the underlying UIScrollView
        // to keep showing its native vertical indicator so users always
        // know they can scroll, even on pages that haven't been migrated
        // to AlwaysVisibleScrollView yet.
        UIScrollView.appearance().showsVerticalScrollIndicator = true
        UIScrollView.appearance().showsHorizontalScrollIndicator = true
        // .default is the dark-on-light style that's most visible across
        // both light and dark colour schemes.
        UIScrollView.appearance().indicatorStyle = .default
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appSettings)
                .onAppear {
                    NSLog("[HealthKitNoModify] App WindowGroup appeared")
                    print("[HealthKitNoModify] App WindowGroup appeared")
                    // Make sure newly created scroll views also pick up
                    // the always-on appearance setting at runtime.
                    UIScrollView.appearance().showsVerticalScrollIndicator = true
                    UIScrollView.appearance().showsHorizontalScrollIndicator = true
                }
        }
    }
}
