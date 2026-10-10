import SwiftUI

enum Frame {
    static let radius: CGFloat = 14
}

/// 「染色吊牌」卡面：来源色染过的色头 + 磨砂纸卡身 + 页脚；状态（悬停/选中/按下/入场）只影响描边、阴影与光晕。
struct CardView: View {
    let item: ClipItem
    let hovering: Bool
    let showRing: Bool
    /// 入场光晕脉冲强度（0…0.9）。
    let pulse: Double
    /// 入场高光扫过色头的进度（0 → 1）。
    let sweep: Double

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.cardPressed) private var pressed

    var body: some View {
        let p = CardPalette.of(item.source, scheme: scheme)
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
        let lifted = hovering && !pressed
        let glowAmount = pressed ? 0 : max(lifted ? 1 : (showRing ? 0.6 : 0), pulse)
        let ambient = (dark ? 0.40 : 0.12) * (lifted ? 1.3 : 1)

        VStack(spacing: 0) {
            Cuff(item: item, palette: p, hovering: hovering, sweep: sweep)
            CardBody(item: item, palette: p, hovering: hovering)
        }
        .frame(width: Layout.cardWidth, height: Layout.cardHeight)
        .background { bodyFill(p) }
        .clipShape(shape)
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(p.ink3, lineWidth: 1)
            } else {
                shape.strokeBorder(p.rim, lineWidth: 0.5)
            }
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.14 : 0.6), .clear],
                                              startPoint: .top, endPoint: .center), lineWidth: 0.75)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Frame.radius + 0.5, style: .continuous)
                .stroke(.black.opacity(dark ? 0.5 : 0.10), lineWidth: 0.5)
                .padding(-0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Frame.radius + 3, style: .continuous)
                .strokeBorder(p.ring, lineWidth: 2)
                .padding(-3)
                .opacity(showRing ? 1 : 0)
        }
        .shadow(color: .black.opacity(dark ? 0.40 : 0.12), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(ambient), radius: lifted ? 18 : (dark ? 14 : 10),
                y: lifted ? 12 : (dark ? 8 : 6))
        .shadow(color: (p.glow ?? .clear).opacity(glowAmount * (dark ? 0.45 : 0.35)), radius: 20, y: 10)
    }

    @ViewBuilder private func bodyFill(_ p: CardPalette) -> some View {
        let solid = reduceTransparency || contrast == .increased
        ZStack {
            if !reduceTransparency { Rectangle().fill(.thinMaterial) }
            LinearGradient(colors: [p.bodyTop, p.bodyBottom], startPoint: .top, endPoint: .bottom)
                .opacity(solid ? 1 : (scheme == .dark ? 0.90 : 0.94))
        }
    }
}

// MARK: 色头

struct Cuff: View {
    let item: ClipItem
    let palette: CardPalette
    let hovering: Bool
    let sweep: Double

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            if let cuff = palette.cuff {
                LinearGradient(colors: [cuff.top, cuff.bottom], startPoint: .top, endPoint: .bottom)
                if let secondary = palette.secondary {
                    LinearGradient(colors: [.clear, secondary.opacity(0.5)],
                                   startPoint: UnitPoint(x: 0.35, y: 0.5), endPoint: .trailing)
                }
            }
            Rectangle().fill(.white.opacity(dark ? 0.18 : 0.35)).frame(height: 0.5)
            HStack(spacing: 0) {
                TypeLabel(kind: item.kind, palette: palette)
                    .frame(maxWidth: 52, alignment: .leading)
                Spacer(minLength: 34)   // 衣夹咬合禁区（x = 72–96）
                SourceBadge(source: item.source, palette: palette, hovering: hovering)
            }
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Layout.cuffHeight)
        .overlay { SweepGlint(progress: sweep) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)).frame(height: 0.5)
        }
    }
}

/// 入场高光：一道斜白光带从左扫到右，只落在色头里。
private struct SweepGlint: View {
    let progress: Double

    var body: some View {
        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: 36, height: Layout.cuffHeight * 2.4)
            .rotationEffect(.degrees(18))
            .offset(x: (Layout.cardWidth + 60) * (progress - 0.5))
            .blendMode(.plusLighter)
            .frame(width: Layout.cardWidth, height: Layout.cuffHeight)
            .clipped()
            .opacity(progress > 0 && progress < 1 ? 1 : 0)
            .allowsHitTesting(false)
    }
}

struct TypeLabel: View {
    let kind: ClipItem.Kind
    let palette: CardPalette

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(kind.label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.2)
                .lineLimit(1)
        }
        .foregroundStyle(palette.cuffInk)
        .shadow(color: .black.opacity(palette.cuffInkShadow ? 0.18 : 0), radius: 0.5, y: 0.5)
    }
}

/// 来源 App 徽标：20pt，不加底座；接力与未知来源各有专门的占位。
struct SourceBadge: View {
    let source: ClipSource
    let palette: CardPalette
    let hovering: Bool

    private static let genericAppIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    var body: some View {
        badge
            .frame(width: 20, height: 20)
            .scaleEffect(hovering ? 1.08 : 1)
            .animation(.spring(response: 0.25), value: hovering)
            .help(source.help)
    }

    @ViewBuilder private var badge: some View {
        switch source.kind {
        case .app:
            Image(nsImage: source.icon ?? Self.genericAppIcon)
                .resizable()
                .interpolation(.high)
                .shadow(color: .black.opacity(0.20), radius: 1.5, y: 1)
        case .continuity:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(0.22))
                .overlay {
                    Image(systemName: "iphone")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                }
        case .unknown:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(palette.ink3.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .overlay {
                    Image(systemName: "clipboard")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.ink3)
                }
        }
    }
}

// MARK: 卡身

struct CardBody: View {
    let item: ClipItem
    let palette: CardPalette
    let hovering: Bool

    private static let bodyHeight = Layout.cardHeight - Layout.cuffHeight
    /// 内容区：卡身去掉内边距（上 10、左右 12、下 9）、页脚 13 与间距 6。
    static let contentSize = CGSize(width: Layout.cardWidth - 24, height: 82)

    var body: some View {
        content.frame(width: Layout.cardWidth, height: Self.bodyHeight)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image(let image, let pixelSize):
            ImageBody(image: image, pixelSize: pixelSize)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 34)
                        .clipShape(BleedShape())
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) { footer(.fixed(.white.opacity(0.92))).bleedFooterPadding() }

        case .color(let color, let literal):
            let light = ColorBody.luminance(of: color) > 0.5
            ColorBody(color: color, literal: literal, palette: palette)
                .overlay(alignment: .bottom) {
                    footer(.fixed(light ? .black.opacity(0.7) : .white.opacity(0.9))).bleedFooterPadding()
                }

        case .code(let code):
            VStack(spacing: 4) {
                CodeBody(code: code, palette: palette)
                    .padding([.top, .horizontal], 8)
                    .frame(maxHeight: .infinity)
                footer(.ink)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }

        default:
            VStack(alignment: .leading, spacing: 6) {
                padded.frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .topLeading)
                footer(.ink)
            }
            .padding(.top, 10)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        }
    }

    @ViewBuilder private var padded: some View {
        switch item.kind {
        case .text(let text): TextBody(text: text, palette: palette)
        case .link(let url, let title): LinkBody(url: url, title: title, palette: palette)
        case .files(let paths): FileBody(paths: paths, palette: palette)
        default: EmptyView()
        }
    }

    private func footer(_ tone: CardFooter.Tone) -> some View {
        CardFooter(item: item, palette: palette, hovering: hovering, tone: tone)
            .frame(height: 13)
    }
}

/// 图片与颜色卡的卡身形状：上边接色头不留圆角，下边两角跟卡片圆角。
struct BleedShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: Frame.radius,
                               bottomTrailingRadius: Frame.radius, topTrailingRadius: 0,
                               style: .continuous).path(in: rect)
    }
}

private extension View {
    func bleedFooterPadding() -> some View {
        padding(.horizontal, 12).padding(.bottom, 9)
    }
}

// MARK: 页脚

struct CardFooter: View {
    enum Tone {
        case ink                 // 普通卡身：ink3
        case fixed(Color)        // 叠在图片/色块上
    }

    let item: ClipItem
    let palette: CardPalette
    let hovering: Bool
    let tone: Tone

    var body: some View {
        let base: Color = {
            if case .fixed(let color) = tone { return color }
            return palette.ink3
        }()
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Text(item.footnote).opacity(hovering ? 0 : 1)
                Text(item.source.footnote).opacity(hovering ? 1 : 0)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .animation(.easeInOut(duration: 0.18), value: hovering)
            .frame(maxWidth: .infinity, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let stamp = RelativeStamp(date: item.copiedAt, now: context.date)
                let accent: Color = {
                    if case .ink = tone { return palette.ring }
                    return base
                }()
                Text(stamp.text)
                    .fontWeight(stamp.isJustNow ? .semibold : .regular)
                    .foregroundStyle(stamp.isJustNow ? accent : base)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(base)
    }
}

/// "刚刚 / 3 分钟 / 2 小时 / 昨天 / 10月8日"。
struct RelativeStamp {
    let text: String
    let isJustNow: Bool

    init(date: Date, now: Date) {
        let seconds = now.timeIntervalSince(date)
        let calendar = Calendar.current
        isJustNow = seconds < 60
        if seconds < 60 {
            text = "刚刚"
        } else if seconds < 3600 {
            text = "\(Int(seconds / 60)) 分钟"
        } else if calendar.isDate(date, inSameDayAs: now) {
            text = "\(Int(seconds / 3600)) 小时"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            text = "昨天"
        } else {
            let parts = calendar.dateComponents([.month, .day], from: date)
            text = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        }
    }
}

extension ClipItem.Kind {
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .color: return "eyedropper"
        case .image: return "photo"
        case .files(let paths): return paths.count > 1 ? "doc.on.doc" : "doc"
        }
    }

    var label: String {
        switch self {
        case .text: return "文本"
        case .link: return "链接"
        case .code: return "代码"
        case .color: return "颜色"
        case .image: return "图片"
        case .files: return "文件"
        }
    }
}

extension ClipItem {
    /// 页脚左侧的类型信息。
    var footnote: String {
        switch kind {
        case .text(let text): return TextBody.countLabel(text)
        case .link(let url, let title): return title == nil ? "" : LinkBody.parts(of: url).domain
        case .code(let code): return "\(CodeBody.lines(of: code).count) 行"
        case .color(_, let literal): return ClipClassifier.colorFormat(literal)
        case .image(_, let size): return "\(Int(size.width)) × \(Int(size.height))"
        case .files(let paths): return FileFacts.summary(paths)
        }
    }
}

// MARK: 按下反馈 / 玻璃

private struct CardPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardPressed: Bool {
        get { self[CardPressedKey.self] }
        set { self[CardPressedKey.self] = newValue }
    }
}

/// 卡片按钮：按下时缩到 0.97（锚点顶部）并收起光晕；粘贴在 action 里执行。
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.cardPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1, anchor: .top)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    /// 临时控件用的玻璃：系统毛玻璃 + 上亮下暗的镜面描边（Tendedero，MIT）。
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}
