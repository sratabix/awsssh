import SwiftUI

struct OverflowMetrics: Equatable {
    var content: CGFloat
    var viewport: CGFloat
    var scrolled: CGFloat

    static let slack: CGFloat = 1

    var hidden: CGFloat { max(0, content - viewport - scrolled) }
    var overflows: Bool { content - viewport > OverflowMetrics.slack }
    var showsMore: Bool { hidden > OverflowMetrics.slack }
}

struct OverflowScroll<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var viewport: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var scrolled: CGFloat = 0

    private static var fadeWidth: CGFloat { 30 }
    private static var space: String { "overflowScroll" }

    private var metrics: OverflowMetrics {
        OverflowMetrics(content: contentWidth, viewport: viewport, scrolled: scrolled)
    }

    private var showsMore: Bool { metrics.showsMore }
    private var overflows: Bool { metrics.overflows }

    var body: some View {
        scroll
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .clear], startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: showsMore ? Self.fadeWidth : 0)
                }
            )
            .overlay(alignment: .trailing) {
                if showsMore {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsMore)
            .background(
                GeometryReader { proxy in
                    let width = proxy.size.width
                    Color.clear
                        .onAppear { viewport = width }
                        .onChange(of: width) { viewport = $0 }
                }
            )
    }

    @ViewBuilder private var scroll: some View {
        if #available(macOS 13.3, *) {
            base.scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            base
        }
    }

    private var base: some View {
        ScrollView(.horizontal) {
            content
                .fixedSize()
                .background(
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let offset = -proxy.frame(in: .named(Self.space)).minX
                        Color.clear
                            .onAppear {
                                contentWidth = width
                                scrolled = offset
                            }
                            .onChange(of: width) { contentWidth = $0 }
                            .onChange(of: offset) { scrolled = $0 }
                    }
                )
        }
        .scrollIndicators(.never)
        .scrollDisabled(!overflows)
        .coordinateSpace(name: Self.space)
    }
}
