import SwiftUI

/// 「底部卡片（Paste 式）」面板——设置里与晾衣绳二选一。
/// 版式参照 Paste 快捷面板实拍（`~/claude/projects/common/2026-10-12/paste样式逆向/REFERENCE.md`）：
/// 底部悬浮大圆角浮层 + 顶栏（搜索 + 标签药丸）+ 横向一排大卡（来源色头部 / 内容预览 / 底部说明）。
struct PastePanelView: View {
    @ObservedObject var store: ClipStore

    // 几何全部按 Paste 快捷面板实拍像素实测（2x 截图折算；见参照包 REFERENCE.md）：
    // 面板贴屏幕底边、高 327pt；卡片 231.5×230（近正方，别做扁）；圆角 14；间距 12。
    static let panelHeight: CGFloat = 327
    static let sideMargin: CGFloat = 6
    static let cornerRadius: CGFloat = 20
    static let cardWidth: CGFloat = 231.5
    static let cardHeight: CGFloat = 230
    static let cardSpacing: CGFloat = 12
    static let cardCornerRadius: CGFloat = 14
    static let headerHeight: CGFloat = 47.5
    static let rowPadding: CGFloat = 14

    private static let startAnchor = "paste.row.start"

    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false

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
                            PasteCardView(item: item, store: store)
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
        // 空态：搜索无结果时的提示（铺在卡片行位置）
        .overlay(alignment: .top) {
            if store.shown.isEmpty {
                Hint(text: store.items.isEmpty ? "复制点什么，它就会出现在这里" : "没有匹配「\(Self.excerpt(store.query))」", detail: "Esc 清除")
                    .padding(.top, 96)
                    .transition(.opacity)
            }
        }
        .background {
            ZStack {
                PanelGlass()
                if scheme == .dark { Rectangle().fill(.black.opacity(0.25)) }
                // 点空白收起：垫在最底层的兄弟层（与绳式同款做法）。
                // 不要把 tuck 手势挂在容器上——它会和卡片的点击手势抢事件，吞掉"点卡粘贴"。
                Color.clear.contentShape(Rectangle()).onTapGesture { store.onRequestTuck?() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(scheme == .dark ? 0.45 : 0.07), lineWidth: 0.5)
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
        // 收起时整块滑到屏幕下方之外，像 Dock 一样滑出。
        // 动画曲线照 REA 逆向：0.15s cubic-bezier(0.2, 0.8, 0.2, 1.0)（自 y=-窗高 滑入）。
        .offset(y: store.revealed ? 0 : Self.panelHeight + 14)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1.0, duration: 0.15), value: store.revealed)
    }

    /// 顶栏：搜索 + 「剪贴板历史」标签药丸（参照 Paste 顶栏的居中排布）。
    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(store: store, ink: .primary, placeholder: .secondary, placeholderText: "")
                .frame(width: 150, height: 20)
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                Text("剪贴板历史")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            // 高亮底色照 REA 逆向：(0.463, 0.463, 0.714) @ α0.12。
            .background(Capsule().fill(Color(.sRGB, red: 0.463, green: 0.463, blue: 0.714).opacity(0.12)))
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private static func excerpt(_ query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.count > 12 ? String(text.prefix(12)) + "…" : text
    }
}

/// 一张 Paste 式大卡：来源色头部（类型 + 时间 + 来源图标）/ 内容预览 / 悬停移除与选中环。
private struct PasteCardView: View {
    let item: ClipItem
    let store: ClipStore

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: PastePanelView.cardCornerRadius, style: .continuous) }

    var body: some View {
        let palette = CardPalette.of(item.source, scheme: scheme)
        VStack(spacing: 0) {
            header(palette)
            PasteCardBody(item: item, palette: palette)
        }
        .frame(width: PastePanelView.cardWidth, height: PastePanelView.cardHeight)
        .background(palette.bodyTop)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.black.opacity(scheme == .dark ? 0.4 : 0.06), lineWidth: 0.5)
        }
        .overlay {
            if store.selectedID == item.id {
                shape.strokeBorder(palette.ring, lineWidth: 2)
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 4, y: 1.5)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.92), .black.opacity(0.35))
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("移除这条")
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture { store.onRequestPaste?(item) }
        .id(item.id)
    }

    private func header(_ palette: CardPalette) -> some View {
        ZStack {
            LinearGradient(colors: [palette.cuff?.top ?? Color(white: 0.62),
                                    palette.cuff?.bottom ?? Color(white: 0.5)],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(of: item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(Self.relative(item.copiedAt))
                        .font(.system(size: 10))
                        .opacity(0.85)
                }
                .foregroundStyle(palette.cuffInk)
                Spacer(minLength: 4)
                if let icon = item.source.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: PastePanelView.headerHeight)
    }

    static func title(of item: ClipItem) -> String {
        if case .files(let paths) = item.kind { return "\(paths.count) 个文件" }
        return item.kind.label
    }
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 卡身：按类型给内容预览（大卡尺寸下的紧凑版）。
private struct PasteCardBody: View {
    let item: ClipItem
    let palette: CardPalette

    @Environment(\.searchQuery) private var query
    @Environment(\.colorScheme) private var scheme

    private var mark: Color { palette.mark(scheme) }

    var body: some View {
        Group {
            switch item.kind {
            case .text(let text):
                fadedPreview {
                    Text(query.marked(text, mark: mark))
                        .font(.system(size: 11.5))
                        .lineSpacing(2.5)
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

    /// 文本/代码这类流式内容：顶部对齐、底部渐隐（不用省略号）。
    private func fadedPreview<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .clipped()
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
    }

    private func codePreview(_ code: String) -> some View {
        let lines = code.replacingOccurrences(of: "\t", with: "  ")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(12)
        return fadedPreview {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(query.marked(String(line), mark: mark))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(palette.codeText)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.codeBase, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func linkPreview(_ url: URL, _ title: String?) -> some View {
        let parts = LinkBody.parts(of: url)
        return VStack(alignment: .leading, spacing: 3) {
            Text(query.marked(title ?? parts.domain, mark: mark))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(palette.ink)
            Text(query.marked(parts.path.isEmpty ? url.absoluteString : parts.path, mark: mark))
                .font(.system(size: 10.5))
                .lineLimit(2)
                .foregroundStyle(palette.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 11)
        .padding(.top, 9)
    }

    private func colorPreview(_ color: NSColor, _ literal: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            if color.alphaComponent < 1 { Checkerboard() }
            Color(nsColor: color)
            Text(literal)
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
            // 显式给定尺寸并就地裁切：fill 放大后的图片不能把 ZStack 撑宽，
            // 否则底左对齐的尺寸徽标会被卡片裁掉左端（"1920" 变 "20"）。
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: PastePanelView.cardWidth, height: bodyHeight,
                       alignment: tall ? .top : .center)
                .clipped()
            if pixelSize.width > 0 {
                // verbatim：Text 字面量插值会走本地化键与数字分组（"1,200"），尺寸要原样。
                Text(verbatim: "\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(9)
            }
        }
        .frame(width: PastePanelView.cardWidth, height: bodyHeight)
        .clipped()
    }

    private func filesPreview(_ paths: [String]) -> some View {
        VStack(spacing: 5) {
            if let first = paths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                    .resizable()
                    .frame(width: 62, height: 62)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 52))
                    .foregroundStyle(palette.ink3)
            }
            Text(paths.count > 1 ? "多个文件" : (paths.first.map { ($0 as NSString).lastPathComponent } ?? "文件"))
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.ink2)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 面板毛玻璃：NSVisualEffectView material = menu（REA 逆向值，同 Paste）——透亮、背后内容可见。
private struct PanelGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
