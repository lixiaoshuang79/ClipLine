import SwiftUI

/// 一张挂在线上的卡片和它的衣夹：落绳、摆动、悬停扶正、入场高光、点 × 摘下来。卡面本身见 `CardView`。
/// 衣夹与摆动动画改编自 Tendedero（github.com/alejandrobujan/tendedero，MIT）。
struct PeggedView: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var store: ClipStore

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hoveringCard = false
    @State private var hoveringRemove = false
    @State private var pulse: Double = 0
    @State private var sweep: Double = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hovering: Bool { hoveringCard || hoveringRemove }
    private var showRing: Bool { store.selectedID == item.id && !hovering }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin()
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + (hovering ? 0 : item.tilt)), anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .offset(y: arrived || reduceMotion ? 0 : -46)
        .opacity(arrived ? 1 : 0)
        .onAppear {
            arrive()
            playFreshIfNeeded()
        }
        .onChange(of: store.gust) { _, _ in breeze() }
        .onChange(of: store.revealed) { _, shown in
            guard shown else { return }   // 绳落下来时，卡片们错峰摆一摆
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) { breeze() }
            playFreshIfNeeded()
        }
    }

    private var card: some View {
        Button { store.onRequestPaste?(item) } label: {
            CardView(item: item, hovering: hovering, showRing: showRing, pulse: pulse, sweep: sweep)
        }
        .buttonStyle(CardPressStyle())
        .focusable(false)   // 方向键与回车由 LinePanel 处理，按钮不抢键盘焦点
        .scaleEffect(hovering ? 1.04 : (showRing ? 1.02 : 1), anchor: .top)
        .overlay(alignment: .topLeading) { removeBadge.offset(x: -7, y: -7) }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.18), value: showRing)
        .onHover { isHovering in
            hoveringCard = isHovering
            if isHovering { store.selectedID = item.id }
        }
    }

    private var removeBadge: some View {
        Button { store.remove(item) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(CardPalette.of(item.source, scheme: scheme).ink)
                .frame(width: 18, height: 18)
                .glassFrame(circle: true)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hoveringRemove = $0 }
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: 摆动

    private func arrive() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { arrived = true }
            return
        }
        swing = 14
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    private func breeze() {
        guard !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0 ... 0.3)) {
            nudge(Double.random(in: 1.4 ... 3.0))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }

    // MARK: 入场高光

    /// 面板展开时，给上次展开后新进来的卡扫一道色头高光，同时光晕脉冲一次。
    private func playFreshIfNeeded() {
        guard store.revealed, store.freshIDs.contains(item.id) else { return }
        store.freshIDs.remove(item.id)
        guard !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(index) * 0.04) {
            sweep = 0
            withAnimation(.easeInOut(duration: 0.7)) { sweep = 1 }
            withAnimation(.easeOut(duration: 0.35)) { pulse = 0.9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeIn(duration: 0.75)) { pulse = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { sweep = 0 }
        }
    }
}

/// 极简铝夹：金属渐变胶囊 + 一根线穿过的槽 + 软阴影（Tendedero，MIT）。永远不染色。
struct Clothespin: View {
    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.8, style: .continuous)
            .fill(metal)
            .frame(width: 10, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5.5, height: 1.5)
                    .padding(.top, 9)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .background(alignment: .bottom) {
                // 咬合阴影：落在色头上，让夹子像真的夹住卡片。
                Ellipse()
                    .fill(Color.black.opacity(0.25))
                    .frame(width: 12, height: 4)
                    .blur(radius: 1.5)
                    .offset(y: 1.5)
            }
            .allowsHitTesting(false)
    }
}
