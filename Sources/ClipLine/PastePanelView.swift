import AppKit
import SwiftUI

/// 「底部卡片（Paste 式）」面板——设置里与晾衣绳二选一。
/// 版式对照 Paste 快捷面板实拍逐像素：贴底 327 / 顶栏 63 / 卡 231.5×230 / 卡圆角 20 / 间距 12。
struct PastePanelView: View {
    @ObservedObject var store: ClipStore

    // 几何全部按 Paste 快捷面板实拍像素实测（2x 截图折算）：
    // 面板贴屏幕底边、高 327pt；卡片 231.5×230（近正方）；间距 12。
    static let panelHeight: CGFloat = 327
    static let sideMargin: CGFloat = 6
    /// 玻璃面板圆角：REA 逆向 setCornerRadius(26.0)，实拍角弧像素拟合 R=52px@2x=26pt 吻合；旧系统 20。
    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 26 }
        return 20
    }
    static let cardWidth: CGFloat = 231.5
    static let cardHeight: CGFloat = 230
    static let cardSpacing: CGFloat = 12
    /// 卡片圆角：REA 逆向 macOS 26+ = 20（旧 14，kCACornerCurveCircular）；实拍亚像素拟合 ≈21.8pt 佐证。
    static var cardCornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 20 }
        return 14
    }
    static let headerHeight: CGFloat = 47.5
    static let rowPadding: CGFloat = 14
    /// 顶栏占位（PanelProbe 点卡几何依赖此值）：paddingTop 14 + toolbar 30 + 卡顶距 19 = 63。
    static let chromeHeight: CGFloat = 63

    private static let startAnchor = "paste.row.start"

    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false
    @State private var searchExpanded = false
    /// 「+」新建标签时的行内输入（对齐 Paste：顶栏出现「未命名」输入框，回车落定）。
    @State private var creatingBoard = false
    /// 正在行内改名的标签。
    @State private var renamingBoard: UUID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: 30)
                .padding(.top, 14)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                        Color.clear.frame(width: 1, height: 1).id(Self.startAnchor)
                        ForEach(store.shown) { item in
                            PasteCardView(item: item, store: store, onCreateBoard: createBoardAndPin)
                        }
                    }
                    .padding(.horizontal, Self.rowPadding)
                    .frame(height: Self.cardHeight, alignment: .top)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.shown.map(\.id))
                }
                .frame(height: Self.cardHeight)
                .padding(.top, 19)
                .onChange(of: store.scrollRequest) { _, request in
                    guard let request else { return }
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if store.shown.isEmpty {
                let hint = Self.emptyHint(for: store)
                Hint(text: hint.text, detail: hint.detail)
                    .padding(.top, 96)
                    .transition(.opacity)
            }
        }
        .background {
            ZStack {
                PanelGlass(cornerRadius: Self.cornerRadius)
                if scheme == .dark { Rectangle().fill(.black.opacity(0.22)) }
                // 点空白收起：最底层兄弟层，避免吞掉卡片点击。
                Color.clear.contentShape(Rectangle()).onTapGesture { store.onRequestTuck?() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .circular))
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .circular)
                    .strokeBorder(.white.opacity(scheme == .dark ? 0.08 : 0.55), lineWidth: 0.5)
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .circular)
                    .strokeBorder(.black.opacity(scheme == .dark ? 0.45 : 0.06), lineWidth: 0.5)
            }
        }
        .onDrop(of: [.fileURL, .url, .image, .text], isTargeted: $dropTargeted) { providers in
            store.acceptDrop(providers)
            return true
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Hint(text: "松手，把它放进来")
                    .padding(.top, 96)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .animation(.easeOut(duration: 0.15), value: store.activeBoardID)
        .animation(.easeOut(duration: 0.15), value: store.boards.map(\.id))
        // 出现动画：0.15s cubic-bezier(0.2, 0.8, 0.2, 1.0)（REA / 实拍）。
        .offset(y: store.revealed ? 0 : Self.panelHeight + 14)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1.0, duration: 0.15), value: store.revealed)
        .environment(\.searchQuery, store.search)
        .onReceive(NotificationCenter.default.publisher(for: .clipLineCreateBoard)) { _ in
            creatingBoard = true   // ⇧⌘N：与 Paste 的「创建 Pinboard」对齐
        }
        .onChange(of: store.fieldHasText) { _, typing in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                searchExpanded = typing
            }
        }
    }

    /// 空态提示。按有没有搜索词分：条目全归入了标签时 `items` 不空，但历史页同样是「还没东西」。
    static func emptyHint(for store: ClipStore) -> (text: String, detail: String?) {
        if let board = store.board(id: store.activeBoardID) {
            return store.search.isEmpty
                ? ("「\(board.name)」还是空的", "去剪贴板历史里右键卡片，固定到「\(board.name)」")
                : ("「\(board.name)」里没有匹配「\(excerpt(store.query))」的", "Esc 清除")
        }
        return store.search.isEmpty
            ? ("复制点什么，它就会出现在这里", nil)
            : ("没有匹配「\(excerpt(store.query))」", "Esc 清除")
    }

    // MARK: 顶栏（对照 paste-header 实拍）

    /// 居中：搜索 · 剪贴板历史药丸 · 各标签（色点 + 名字）· 新建 ⊕；右侧 … 溢出菜单。
    /// 标签多或名字长时整条横向可滚；内容不超宽时仍整组居中。
    private var toolbar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    searchCluster
                    historyTab
                    ForEach(store.boards) { board in
                        boardTab(board)
                    }
                    if creatingBoard {
                        InlineTextField(initial: "未命名",
                                        onCommit: { name in
                                            creatingBoard = false
                                            store.addBoard(name: name)
                                        },
                                        onCancel: { creatingBoard = false })
                            .frame(width: 110, height: 20)
                    }
                    plusButton
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)   // 比视口窄时撑满，交给外层居中
            }
            // 顶栏空白处点击仍然收起面板（ScrollView 会把空白处的点击吃掉，用底垫补回来）。
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { store.onRequestTuck?() })
            overflowMenu
                .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// 搜索：常态只露放大镜（Paste 实拍）；击键仍进隐藏 NSTextField；有字时向右展开输入区。
    private var searchCluster: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.primary.opacity(0.75))
                .frame(width: 18, height: 18)
            SearchField(store: store, ink: .primary, placeholder: .secondary, placeholderText: "")
                .frame(width: searchExpanded ? 132 : 1, height: 18)
                .opacity(searchExpanded ? 1 : 0.02)
                .clipped()
            if searchExpanded {
                Button { store.replaceQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索（Esc）")
                .transition(.opacity)
            }
        }
        // 点搜索区不穿透到 tuck。
        .background(Color.clear.contentShape(Rectangle()).onTapGesture {})
    }

    private var historyTab: some View {
        let selected = store.activeBoardID == nil
        return Button {
            store.activeBoardID = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                Text("剪贴板历史")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(selected ? pillFill : Color.clear))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.88))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("全部剪贴板历史")
    }

    /// 一个标签页：色点 + 名字；右键 = 重命名 / 颜色 / 删除（对齐 Paste 标签右键菜单）。
    @ViewBuilder
    private func boardTab(_ board: Pinboard) -> some View {
        let selected = store.activeBoardID == board.id
        if renamingBoard == board.id {
            HStack(spacing: 6) {
                Circle().fill(board.color.color).frame(width: 8, height: 8)
                InlineTextField(initial: board.name,
                                onCommit: { name in
                                    renamingBoard = nil
                                    store.renameBoard(board.id, to: name)
                                },
                                onCancel: { renamingBoard = nil })
                    .frame(width: 96, height: 20)
            }
        } else {
            Button {
                store.activeBoardID = board.id
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(board.color.color)
                        .frame(width: 8, height: 8)
                    Text(board.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, selected ? 11 : 2)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(selected ? pillFill : Color.clear))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.88))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("标签「\(board.name)」")
            .contextMenu {
                Button("重命名") { renamingBoard = board.id }
                Menu("颜色") {
                    // 菜单里的 Toggle 渲染成带勾选列的菜单项，文字对齐；手写「✓ 」前缀会把选中项挤歪。
                    ForEach(PinboardColor.allCases, id: \.self) { color in
                        Toggle(color.displayName, isOn: Binding(
                            get: { color == board.color },
                            set: { if $0 { store.setBoardColor(board.id, color) } }))
                    }
                }
                Divider()
                Button("删除标签…", role: .destructive) { confirmDelete(board) }
            }
        }
    }

    /// 药丸底色：实拍浅灰 ≈ RGB(222,224,225)；非 REA 报告里的紫调。
    private var pillFill: Color {
        scheme == .dark
            ? Color.white.opacity(0.14)
            : Color(.sRGB, red: 222 / 255, green: 224 / 255, blue: 225 / 255)
    }

    private var plusButton: some View {
        Button { creatingBoard = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.primary.opacity(0.75))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("新建标签（⇧⌘N）")
    }

    /// 删除标签前的确认（对齐 Paste：标签及其内容删除后无法恢复）。
    private func confirmDelete(_ board: Pinboard) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除「\(board.name)」？"
        alert.informativeText = "只在这个标签里的条目会一起删除，无法恢复；同时属于其他标签的条目会保留。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.deleteBoard(board.id) }
    }

    /// 卡片右键「创建标签…」：建一个未命名标签、把这张卡固定进去，并就地开始改名。
    private func createBoardAndPin(_ item: ClipItem) {
        let board = store.addBoard(name: "未命名")
        store.pin(item, to: board.id)
        creatingBoard = false
        renamingBoard = board.id
    }

    private var overflowMenu: some View {
        Menu {
            Button("新建标签") { creatingBoard = true }
            Button("添加文件到历史…") { addFiles() }
            Divider()
            Button("设置…") {
                NotificationCenter.default.post(name: .clipLineOpenSettings, object: nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.75) : Color.primary.opacity(0.55))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22, height: 22)
        .help("更多")
    }

    private func addFiles() {
        // 先收起：面板在 Dock 层之上，会盖住打开面板底部的按钮；同确认框一样先激活再弹。
        store.onRequestTuck?()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "所选文件会记入剪贴板历史"
        guard panel.runModal() == .OK else { return }
        let providers = panel.urls.map { url -> NSItemProvider in
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }.filter { !$0.registeredTypeIdentifiers.isEmpty }
        if !providers.isEmpty { store.acceptDrop(providers) }
    }

    private static func excerpt(_ query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.count > 12 ? String(text.prefix(12)) + "…" : text
    }
}

extension Notification.Name {
    static let clipLineOpenSettings = Notification.Name("ClipLine.openSettings")
    /// ⇧⌘N：新建标签（Paste 的「创建 Pinboard」同款快捷键）。
    static let clipLineCreateBoard = Notification.Name("ClipLine.createBoard")
}

// MARK: - Card

/// 一张 Paste 式大卡：来源色头部 / 内容预览 / 选中环与悬停移除。
private struct PasteCardView: View {
    let item: ClipItem
    let store: ClipStore
    /// 右键「固定到 ▸ 创建标签…」：由面板建标签并接线改名。
    let onCreateBoard: (ClipItem) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var shape: RoundedRectangle {
        // REA 逆向量：kCACornerCurveCircular（圆角，非 continuous 超椭圆）。
        RoundedRectangle(cornerRadius: PastePanelView.cardCornerRadius, style: .circular)
    }

    /// Paste 实拍选中环：固定系统蓝，不跟来源色走。
    private var selectionBlue: Color {
        Color(.sRGB, red: 52 / 255, green: 120 / 255, blue: 246 / 255)
    }

    var body: some View {
        let palette = CardPalette.of(item.source, scheme: scheme)
        let selected = store.selectedID == item.id
        VStack(spacing: 0) {
            header(CardPalette.cuffed(item.source, scheme: scheme))
            PasteCardBody(item: item, palette: palette)
        }
        .frame(width: PastePanelView.cardWidth, height: PastePanelView.cardHeight)
        .background(
            LinearGradient(colors: [palette.bodyTop, palette.bodyBottom],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.black.opacity(scheme == .dark ? 0.35 : 0.05), lineWidth: 0.5)
        }
        .overlay {
            if selected {
                shape.strokeBorder(selectionBlue, lineWidth: 2.5)
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? (hovering ? 0.45 : 0.32) : (hovering ? 0.14 : 0.08)),
                radius: hovering ? 8 : 5, y: hovering ? 3 : 1.5)
        .scaleEffect(hovering && !selected ? 1.012 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .overlay(alignment: .topTrailing) {
            if hovering {
                // 标签视图里 × 是「移出本标签」（不是彻底删除）；历史视图里仍是移除这条。
                let inBoard = store.activeBoardID.flatMap { active in item.boards.contains(active) ? active : nil }
                Button {
                    if let inBoard {
                        store.unpin(item, from: inBoard)
                    } else {
                        store.remove(item)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.95), .black.opacity(0.38))
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
                .buttonStyle(.plain)
                .padding(7)
                .help(inBoard == nil ? "移除这条" : "移出本标签")
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture { store.onRequestPaste?(item) }
        .contextMenu { cardMenu }
        .id(item.id)
    }

    /// 卡片右键菜单（对齐 Paste：粘贴/复制/固定到 ▸ …；下方是置顶与移除）。
    @ViewBuilder
    private var cardMenu: some View {
        Button("粘贴") { store.onRequestPaste?(item) }
        Button("复制") { _ = store.writeToPasteboard(item) }
        Divider()
        Button(item.pinned ? "取消置顶" : "置顶") { store.togglePin(item) }
        Menu("固定到") {
            ForEach(store.boards) { board in
                Toggle(board.name, isOn: Binding(
                    get: { item.boards.contains(board.id) },
                    set: { $0 ? store.pin(item, to: board.id) : store.unpin(item, from: board.id) }))
            }
            if !store.boards.isEmpty { Divider() }
            Button("创建标签…") { onCreateBoard(item) }
        }
        if let activeID = store.activeBoardID, item.boards.contains(activeID),
           let board = store.board(id: activeID) {
            // 标签视图里只有「移出」：彻底删除去历史视图操作，避免误删多标签共有的条目。
            Button("从「\(board.name)」移出") { store.unpin(item, from: activeID) }
        } else {
            Divider()
            Button("移除", role: .destructive) { store.remove(item) }
        }
    }

    /// `palette` 来自 `CardPalette.cuffed`，一定带色头。
    private func header(_ palette: CardPalette) -> some View {
        ZStack {
            if let cuff = palette.cuff {
                LinearGradient(colors: [cuff.top, cuff.bottom], startPoint: .top, endPoint: .bottom)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.title(of: item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: Self.relative(item.copiedAt))
                        .font(.system(size: 10, weight: .regular))
                        .opacity(0.88)
                }
                .foregroundStyle(palette.cuffInk)
                .shadow(color: palette.cuffInkShadow ? .black.opacity(0.22) : .clear, radius: 0.5, y: 0.5)
                Spacer(minLength: 4)
                if let icon = item.source.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: PastePanelView.headerHeight)
    }

    static func title(of item: ClipItem) -> String {
        if case .files(let paths) = item.kind {
            return "\(paths.count) 个文件"
        }
        return item.kind.label
    }

    /// 紧凑相对时间，对齐 Paste「1小时前 / 17分钟前」（无空格）。
    static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 45 { return "刚刚" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1))分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 30 { return "\(days)天前" }
        let months = days / 30
        if months < 12 { return "\(months)个月前" }
        return "\(days / 365)年前"
    }
}

// MARK: - Card body

/// 卡身：按类型给内容预览（大卡尺寸下的紧凑版）。
private struct PasteCardBody: View {
    let item: ClipItem
    let palette: CardPalette

    @Environment(\.searchQuery) private var query
    @Environment(\.colorScheme) private var scheme

    private var mark: Color { palette.mark(scheme) }

    /// 卡面只放得下十来行：文本只排前这么多字（同绳式 `TextBody.tidy`），代码每行只取前这么多字，
    /// 几十万字的正文不再在每次重绘时整篇建 AttributedString、排版。
    private static let textPreviewCharacters = 1200
    private static let codeLineCharacters = 200

    var body: some View {
        Group {
            switch item.kind {
            case .text(let text):
                fadedPreview {
                    Text(query.marked(String(text.prefix(Self.textPreviewCharacters)), mark: mark))
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(palette.ink)
                }
            case .code(let code):
                codePreview(code)
            case .link(let url, let title):
                linkPreview(url, title)
            case .color(let color, let literal):
                colorPreview(color, literal)
            case .image(let image, let pixelSize):
                imagePreview(image, pixelSize)
            case .files(let paths):
                filesPreview(paths)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func fadedPreview<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .clipped()
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
    }

    private func codePreview(_ code: String) -> some View {
        let lines = code.split(maxSplits: 12, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(12)
            .map { $0.prefix(Self.codeLineCharacters).replacingOccurrences(of: "\t", with: "  ") }
        return fadedPreview {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(query.marked(String(line), mark: mark))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(palette.codeText)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.codeBase, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func linkPreview(_ url: URL, _ title: String?) -> some View {
        let parts = LinkBody.parts(of: url)
        return VStack(alignment: .leading, spacing: 4) {
            Text(query.marked(title ?? parts.domain, mark: mark))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .foregroundStyle(palette.ink)
            Text(query.marked(parts.path.isEmpty ? url.absoluteString : parts.path, mark: mark))
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundStyle(palette.ink2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func colorPreview(_ color: NSColor, _ literal: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            if color.alphaComponent < 1 { Checkerboard() }
            Color(nsColor: color)
            Text(verbatim: literal)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
        }
    }

    private func imagePreview(_ image: NSImage, _ pixelSize: CGSize) -> some View {
        let tall = pixelSize.width > 0 && pixelSize.height / pixelSize.width > 1.6
        let bodyHeight = PastePanelView.cardHeight - PastePanelView.headerHeight
        return ZStack(alignment: .bottomLeading) {
            Checkerboard()
            // 显式 frame + clipped：fill 不得撑宽容器裁掉尺寸徽标。
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: PastePanelView.cardWidth, height: bodyHeight,
                       alignment: tall ? .top : .center)
                .clipped()
            if pixelSize.width > 0 {
                Text(verbatim: "\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(.black.opacity(0.48)))
                    .padding(9)
            }
        }
        .frame(width: PastePanelView.cardWidth, height: bodyHeight)
        .clipped()
    }

    private func filesPreview(_ paths: [String]) -> some View {
        let show = Array(paths.prefix(3))
        return VStack(spacing: 0) {
            Spacer(minLength: 8)
            ZStack {
                ForEach(Array(show.enumerated().reversed()), id: \.offset) { index, path in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .offset(x: CGFloat(index) * 10 - CGFloat(show.count - 1) * 5,
                                y: CGFloat(index) * -4)
                }
            }
            .frame(height: 78)
            Spacer(minLength: 6)
            Text(verbatim: footerLabel(paths))
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.ink2)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footerLabel(_ paths: [String]) -> String {
        if paths.count > 1 { return "多个文件" }
        guard let first = paths.first else { return "文件" }
        let name = (first as NSString).lastPathComponent
        if name.count > 28 {
            return "…" + String(name.suffix(26))
        }
        return name
    }
}

// MARK: - Chrome helpers

/// 面板玻璃：macOS 26+ 用官方「液态玻璃」NSGlassEffectView（REA 逆向证实 Paste 同款做法：
/// 玻璃容器 + setCornerRadius）；旧系统回退 NSVisualEffectView material = menu。
private struct PanelGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = cornerRadius
            return view
        }
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
    }
}

/// 面板内的小提示胶囊（空态/拖入态）。
private struct Hint: View {
    let text: String
    var detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
            if let detail { Text(detail).opacity(0.7) }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

/// 顶栏行内输入框（新建/重命名标签）：出现即聚焦并全选，回车落定，Esc 取消，失焦也落定。
private struct InlineTextField: NSViewRepresentable {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initial)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ view: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let onCommit: (String) -> Void
        private let onCancel: () -> Void
        /// 回车与失焦都会到；只认第一个。
        private var settled = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                settle(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            settle(field.stringValue)
        }

        private func settle(_ text: String) {
            guard !settled else { return }
            settled = true
            onCommit(text)
        }

        private func cancel() {
            guard !settled else { return }
            settled = true
            onCancel()
        }
    }
}
