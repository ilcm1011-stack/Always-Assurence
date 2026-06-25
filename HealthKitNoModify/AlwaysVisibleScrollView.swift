//
//  AlwaysVisibleScrollView.swift
//  HealthKitNoModify
//
//  A ScrollView replacement that draws its OWN scroll bar — entirely
//  hand-rendered SwiftUI shapes, not the system indicator. Works on
//  iPadOS 26 even with its new default-hidden scroll indicators.
//
//  Uses the iOS 18+ `onScrollGeometryChange` API to get the real
//  content size / viewport size / offset directly from UIScrollView,
//  which is far more reliable than reading the content geometry via
//  PreferenceKey on iPadOS 26.
//

import SwiftUI

private struct AVSVScrollInfo: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var offset: CGFloat = 0
}

struct AlwaysVisibleScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let content: Content

    @State private var info = AVSVScrollInfo()

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(axes, showsIndicators: false) {
                content
            }
            .modifier(ScrollGeometryReader(info: $info))

            customScrollBar()
        }
    }

    private func customScrollBar() -> some View {
        let viewportHeight = max(info.viewportHeight, 1)
        let measuredContent = max(info.contentHeight, viewportHeight)
        let trackInset: CGFloat = 8
        let trackHeight = max(40, viewportHeight - trackInset * 2)
        let thumbRatio = max(0.12, min(1.0, viewportHeight / measuredContent))
        let thumbHeight = max(50, trackHeight * thumbRatio)
        let maxScroll = max(measuredContent - viewportHeight, 1)
        let progress = min(max(info.offset / maxScroll, 0), 1)
        let thumbY = trackInset + (trackHeight - thumbHeight) * progress

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(.systemGray3))
                .frame(width: 8, height: trackHeight)
                .offset(y: trackInset)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(.label).opacity(0.55))
                .frame(width: 8, height: thumbHeight)
                .offset(y: thumbY)
                .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
        }
        .frame(width: 8, height: viewportHeight, alignment: .top)
        .padding(.trailing, 4)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: info)
    }
}

/// Bridges the iOS 18+ `onScrollGeometryChange` API into our state,
/// with a PreferenceKey fallback for older systems.
private struct ScrollGeometryReader: ViewModifier {
    @Binding var info: AVSVScrollInfo

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: AVSVScrollInfo.self) { geometry in
                    AVSVScrollInfo(
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height,
                        offset: geometry.contentOffset.y
                    )
                } action: { _, newValue in
                    info = newValue
                }
        } else {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { info.viewportHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, newValue in
                                info.viewportHeight = newValue
                            }
                    }
                )
        }
    }
}
