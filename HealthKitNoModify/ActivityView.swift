import SwiftUI

#if canImport(UIKit)
import UIKit

/// SwiftUI wrapper for `UIActivityViewController` (iOS / iPadOS share sheet).
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                 applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
import AppKit

/// SwiftUI wrapper for `NSSharingServicePicker` (macOS share sheet).
struct ActivityView: NSViewControllerRepresentable {
    var activityItems: [Any]

    func makeNSViewController(context: Context) -> NSViewController {
        let viewController = NSViewController()
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: activityItems)
            picker.show(relativeTo: viewController.view.bounds,
                        of: viewController.view,
                        preferredEdge: .minY)
        }
        return viewController
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}
#endif
