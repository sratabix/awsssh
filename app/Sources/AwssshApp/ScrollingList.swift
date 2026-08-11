import SwiftUI

struct ScrollingList<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var scrolled: CGFloat = 0

    private static var space: String { "scrollingList" }
    private static var fadeHeight: CGFloat { 24 }

    private var height: CGFloat { min(max(contentHeight, 1), maxHeight) }
    private var hidden: CGFloat { max(0, contentHeight - height - scrolled) }
    private var showsMore: Bool { hidden > 1 }

    var body: some View {
        scroll
            .frame(height: height)
            .mask(
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: showsMore ? Self.fadeHeight : 0)
                }
            )
            .animation(.easeOut(duration: 0.12), value: showsMore)
    }

    @ViewBuilder private var scroll: some View {
        if #available(macOS 13.3, *) {
            base.scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        } else {
            base
        }
    }

    private var base: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        let measured = proxy.size.height
                        let offset = -proxy.frame(in: .named(Self.space)).minY
                        Color.clear
                            .onAppear {
                                contentHeight = measured
                                scrolled = offset
                            }
                            .onChange(of: measured) { contentHeight = $0 }
                            .onChange(of: offset) { scrolled = $0 }
                    }
                )
                .background(HorizontalScrollLock().frame(width: 0, height: 0))
        }
        .scrollIndicators(.never)
        .coordinateSpace(name: Self.space)
    }
}
