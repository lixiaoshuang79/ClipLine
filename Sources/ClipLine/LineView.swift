import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 220
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 178
    static let cardWidth: CGFloat = 150
    static let cardHeight: CGFloat = 104
    static let pinAbove: CGFloat = 9.5
    static let sideMargin: CGFloat = 90

    /// 绳从两端垂下，越宽的绳弧越深（封顶）。
    static func sag(width: CGFloat) -> CGFloat { min(34, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// 内容比屏幕宽时横向滚动；否则整组居中（同 Tendedero）。
    static func contentWidth(count: Int, screenWidth: CGFloat) -> CGFloat {
        let span = CGFloat(max(count - 1, 0)) * spacing + cardWidth + sideMargin * 2
        return max(screenWidth, span)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }
}

struct LineView: View {
    @ObservedObject var store: ClipStore

    var body: some View {
        GeometryReader { geometry in
            let width = Layout.contentWidth(count: store.items.count, screenWidth: geometry.size.width)
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // 点空白处收起。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { store.onRequestTuck?() }

                    Rope(width: width)

                    if store.items.isEmpty {
                        Hint()
                            .position(x: width / 2,
                                      y: Layout.ropeY(x: width / 2, width: width) + 44)
                            .transition(.opacity)
                    }

                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        let x = Layout.x(index: index, count: store.items.count, width: width)
                        let ropeY = Layout.ropeY(x: x, width: width)
                        PeggedView(item: item, index: index, store: store)
                            .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                            .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                    }
                }
                .frame(width: width, height: Layout.panelHeight)
                .animation(.spring(response: 0.55, dampingFraction: 0.78), value: store.items.map(\.id))
                .animation(.easeInOut(duration: 0.3), value: store.items.isEmpty)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // 收起时整条绳停在屏幕上沿之外，像自动隐藏的 Dock 一样滑出。
        .offset(y: store.revealed ? 0 : -(Layout.panelHeight + 16))
        .animation(store.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                  : .easeIn(duration: 0.22), value: store.revealed)
    }
}

private struct Hint: View {
    var body: some View {
        Text("复制点什么，它就会挂在这根绳上")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// 一根细而中性的绳：中灰芯 + 上缘高光 + 软阴影，浅色深色都读得出来；两端渐隐。
/// 取自 Tendedero（MIT）。
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}
