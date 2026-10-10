import SwiftUI

/// 一张挂在线上的卡片和它的衣夹：落绳、摆动、悬停扶正、入场高光、点 × 摘下来。卡面本身见 `CardView`。
/// 衣夹与摆动动画改编自 Tendedero（github.com/alejandrobujan/tendedero，MIT）。
struct PeggedView: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var store: ClipStore

    @State private var swing: Double = 0
    @State private var arrived: Bool
    @State private var hoveringCard = false
    @State private var hoveringRemove = false
    @State private var hoveringPin = false
    @State private var pulse: Double = 0
    @State private var sweep: Double = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `lands`：刚复制进来的卡第一次出现时落绳；滚动进视口、搜索后挂回的卡不重播。
    init(item: ClipItem, index: Int, store: ClipStore, lands: Bool) {
        self.item = item
        self.index = index
        self.store = store
        _arrived = State(initialValue: !lands)
    }

    private var hovering: Bool { hoveringCard || hoveringRemove || hoveringPin }
    private var showRing: Bool { store.selectedID == item.id && !hovering }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin(brass: item.pinned)
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + (hovering ? 0 : item.tilt)), anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .offset(y: arrived || reduceMotion ? 0 : -46)
        .opacity(arrived ? 1 : 0)
        .onAppear {
            if !arrived {
                arrive()
                store.landingIDs.remove(item.id)
            }
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
        // 拖出去 = 分享一份副本；拖进目标 App 后，绳上这条不动。
        .onDrag {
            Dragging.provider(for: item, store: store)
        } preview: {
            CardView(item: item, hovering: true, showRing: false, pulse: 0, sweep: 0)
                .frame(width: Layout.cardWidth, height: Layout.cardHeight)
        }
        .scaleEffect(hovering ? 1.04 : (showRing ? 1.02 : 1), anchor: .top)
        .overlay(alignment: .topLeading) { removeBadge.offset(x: -7, y: -7) }
        .overlay(alignment: .topTrailing) { pinBadge.offset(x: 7, y: -7) }
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
        .help("从绳上摘掉这条")
    }

    /// 置顶按钮：悬停出现；已置顶时保持半透明常驻，随时可以取消。
    private var pinBadge: some View {
        Button { store.togglePin(item) } label: {
            Image(systemName: item.pinned ? "pin.slash" : "pin")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(CardPalette.of(item.source, scheme: scheme).ink)
                .frame(width: 18, height: 18)
                .glassFrame(circle: true)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hoveringPin = $0 }
        .opacity(hovering ? 1 : (item.pinned ? 0.85 : 0))
        .scaleEffect(hovering || item.pinned ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: item.pinned)
        .help(item.pinned ? "取消置顶" : "置顶（不会被容量淘汰，清空历史时保留）")
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

// MARK: 上绳 / 下绳

/// 搜索过滤时：没命中的卡被"摘下"（上提、略缩、淡出），重新命中的卡"挂回"（从上方带一点摆角落下）。
private struct Hang: ViewModifier {
    let amount: Double     // 0 = 挂在绳上
    let lift: CGFloat
    let turn: Double
    let shrink: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let motion = reduceMotion ? 0 : amount
        content
            .rotationEffect(.degrees(turn * motion), anchor: .top)
            .scaleEffect(1 - shrink * motion, anchor: .top)
            .offset(y: lift * motion)
            .opacity(1 - amount)
    }
}

extension AnyTransition {
    private static var unclip: AnyTransition {
        .modifier(active: Hang(amount: 1, lift: -26, turn: 0, shrink: 0.06),
                  identity: Hang(amount: 0, lift: -26, turn: 0, shrink: 0.06))
    }

    /// 挂回 / 摘下。
    static var hang: AnyTransition {
        .asymmetric(insertion: .modifier(active: Hang(amount: 1, lift: -34, turn: 7, shrink: 0),
                                         identity: Hang(amount: 0, lift: -34, turn: 7, shrink: 0)),
                    removal: unclip)
    }

    /// 新复制的卡：入场交给 `PeggedView` 自己的落绳动画，这里只管摘下。
    static var hangNew: AnyTransition {
        .asymmetric(insertion: .identity, removal: unclip)
    }
}

/// 极简铝夹：金属渐变胶囊 + 一根线穿过的槽 + 软阴影（Tendedero，MIT）。永远不染色；置顶卡换成黄铜夹。
struct Clothespin: View {
    /// 置顶卡用黄铜夹，一眼认出来。
    var brass: Bool = false

    private var metal: LinearGradient {
        if brass {
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 0.70, green: 0.52, blue: 0.22), location: 0),
                    .init(color: Color(red: 0.94, green: 0.79, blue: 0.45), location: 0.35),
                    .init(color: Color(red: 0.86, green: 0.68, blue: 0.33), location: 0.65),
                    .init(color: Color(red: 0.60, green: 0.43, blue: 0.17), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(
            stops: [
                .init(color: Color(white: 0.70), location: 0),
                .init(color: Color(white: 0.93), location: 0.35),
                .init(color: Color(white: 0.82), location: 0.65),
                .init(color: Color(white: 0.62), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }

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
