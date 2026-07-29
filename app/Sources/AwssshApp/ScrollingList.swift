import SwiftUI

struct ScrollingList<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0

    private var height: CGFloat { min(max(contentHeight, 1), maxHeight) }

    var body: some View {
        scroll.frame(height: height)
    }

    @ViewBuilder private var scroll: some View {
        if #available(macOS 13.3, *) {
            base.scrollBounceBehavior(.basedOnSize, axes: .vertical)
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
                        Color.clear
                            .onAppear { contentHeight = measured }
                            .onChange(of: measured) { contentHeight = $0 }
                    }
                )
        }
    }
}
