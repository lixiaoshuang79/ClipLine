import SwiftUI

enum Layout {
    /// 绳与卡 248（见 spec §1）+ 下方搜索胶囊一条。
    static let panelHeight: CGFloat = 268
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 194
    static let cardWidth: CGFloat = 168
    static let cardHeight: CGFloat = 148     // 整卡：色头 28 + 卡身 120
    static let cuffHeight: CGFloat = 28
    static let pinAbove: CGFloat = 9.5
    static let sideMargin: CGFloat = 90
    /// 搜索胶囊：顶边离绳中点下的卡底约 27pt，悬停放大后仍留 20pt。
    static let searchTop: CGFloat = 226
    static let searchHeight: CGFloat = 30
    static let searchIdleWidth: CGFloat = 188
    static let searchWidth: CGFloat = 300

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
    @State private var dropTargeted = false

    private static let startAnchor = "clipline.rope.start"

    var body: some View {
        GeometryReader { geometry in
            let shown = store.shown
            let width = Layout.contentWidth(count: shown.count, screenWidth: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // 懒加载：几百条历史时只建视口附近的卡；x 由序号决定，绳弧上的高度照旧逐张算。
                    LazyHStack(alignment: .top, spacing: Layout.spacing - Layout.cardWidth) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            let x = Layout.x(index: index, count: shown.count, width: width)
                            let ropeY = Layout.ropeY(x: x, width: width)
                            let lands = store.landingIDs.contains(item.id)
                            PeggedView(item: item, index: index, store: store, lands: lands)
                                .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                                .padding(.top, ropeY - Layout.pinAbove)
                                .transition(lands ? .hangNew : .hang)
                        }
                    }
                    .padding(.leading, Layout.x(index: 0, count: shown.count, width: width) - Layout.cardWidth / 2)
                    .frame(width: width, height: Layout.panelHeight, alignment: .topLeading)
                    .background(alignment: .topLeading) { backdrop(width: width, empty: shown.isEmpty) }
                    .animation(.spring(response: 0.55, dampingFraction: 0.78), value: shown.map(\.id))
                    .animation(.easeInOut(duration: 0.3), value: shown.isEmpty)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: store.scrollRequest) { _, request in
                    guard let request else { return }
                    // 等这一轮过滤的布局落定再滚。
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            switch request.target {
                            case .start: proxy.scrollTo(Self.startAnchor, anchor: .leading)
                            case .item(let id): proxy.scrollTo(id)
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack(spacing: 10) {
                    if !Self.ropeIsBare(store) {
                        SearchCapsule(store: store)
                            .transition(.opacity)
                    }
                    if !store.boards.isEmpty {
                        TagSwitcher(store: store)
                    }
                }
                .padding(.top, Layout.searchTop)
            }
        }
        .environment(\.searchQuery, store.search)
        // 拖进来 = 当成一次复制收进历史。
        .onDrop(of: [.fileURL, .url, .image, .text], isTargeted: $dropTargeted) { providers in
            store.acceptDrop(providers)
            return true
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Hint(text: "松手，把它挂到绳上")
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        // 收起时整条绳停在屏幕上沿之外，像自动隐藏的 Dock 一样滑出。
        .offset(y: store.revealed ? 0 : -(Layout.panelHeight + 16))
        .animation(store.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                  : .easeIn(duration: 0.22), value: store.revealed)
    }

    /// 绳、点空白收起的底、空状态提示。
    private func backdrop(width: CGFloat, empty: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { store.onRequestTuck?() }
            Color.clear.frame(width: 1, height: 1).id(Self.startAnchor)
            Rope(width: width)
            if empty {
                Group {
                    if !store.search.isEmpty {
                        Hint(text: "绳上没有「\(Self.excerpt(store.query))」", detail: "Esc 清除")
                    } else if let board = store.board(id: store.activeBoardID) {
                        Hint(text: "「\(board.name)」还是空的")
                    } else {
                        Hint(text: "复制点什么，它就会挂在这根绳上")
                    }
                }
                .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 44)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: Layout.panelHeight)
    }

    /// 绳上没有可挂的历史（也没在搜索）。不能只看 `items`：归入标签的条目在里面，却不上绳。
    static func ropeIsBare(_ store: ClipStore) -> Bool {
        store.shown.isEmpty && store.search.isEmpty
    }

    private static func excerpt(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 16 ? String(trimmed.prefix(16)) + "…" : trimmed
    }
}

private struct Hint: View {
    let text: String
    var detail: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = CardPalette.of(.unknown, scheme: scheme)
        HStack(spacing: 8) {
            Text(text).foregroundStyle(p.ink2)
            if let detail { Text(detail).foregroundStyle(p.ink3) }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

/// 绳式的标签切换（搜索框旁）：默认「全部」= 含已归入标签的条目；选某个标签则只看它。
/// 与底部面板的标签页共用 `store.activeBoardID`。
private struct TagSwitcher: View {
    @ObservedObject var store: ClipStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = CardPalette.of(.unknown, scheme: scheme)
        let active = store.board(id: store.activeBoardID)
        Menu {
            Toggle("全部", isOn: Binding(
                get: { store.activeBoardID == nil },
                set: { if $0 { store.activeBoardID = nil } }))
            Divider()
            ForEach(store.boards) { board in
                Toggle(board.name, isOn: Binding(
                    get: { store.activeBoardID == board.id },
                    set: { if $0 { store.activeBoardID = board.id } }))
            }
        } label: {
            HStack(spacing: 6) {
                if let active {
                    Circle().fill(active.color.color).frame(width: 7, height: 7)
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(p.ink3)
                }
                Text(active?.name ?? "全部")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.ink2)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(p.ink3)
            }
            .padding(.horizontal, 11)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // 胶囊底盘放在 Menu 外层：borderlessButton 样式会把 label 的背景吃掉。
        .frame(maxWidth: 160, minHeight: Layout.searchHeight)
        .background {
            // 点控件空白处不该穿透到底下的"点空白收起"。
            Capsule().fill(Color.clear).contentShape(Capsule()).onTapGesture {}
        }
        .glassFrame(capsule: true, material: .regularMaterial)
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 10, y: 4)
        .help("按标签筛选（默认全部）")
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
