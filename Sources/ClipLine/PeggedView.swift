import SwiftUI

/// 一张挂在线上的卡片和它的衣夹：落绳、摆动、悬停抬起、点 × 摘下来。
/// 衣夹、玻璃卡与摆动动画改编自 Tendedero（github.com/alejandrobujan/tendedero，MIT）。
struct PeggedView: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var store: ClipStore

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false

    private var selected: Bool { store.selectedID == item.id }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin()
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        .opacity(arrived ? 1 : 0)
        .onAppear(perform: arrive)
        .onChange(of: store.gust) { _, _ in breeze() }
        .onChange(of: store.revealed) { _, shown in
            guard shown else { return }   // 绳落下来时，卡片们错峰摆一摆
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) { breeze() }
        }
    }

    /// 图片按原始比例缩进卡片内容区，白边随比例收放。
    static func photoSize(for size: CGSize) -> CGSize {
        let maxWidth = Layout.cardWidth - 14
        let maxHeight = Layout.cardHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var card: some View {
        content
            .padding(Frame.inset)
            .glassFrame(cornerRadius: Frame.radius)
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.85 : 0), lineWidth: 2)
            )
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18),
                    radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            .scaleEffect(hovering ? 1.035 : 1, anchor: .top)
            .overlay(alignment: .topLeading) { removeBadge }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { isHovering in
                hovering = isHovering
                if isHovering { store.selectedID = item.id }
            }
            .onTapGesture { store.onRequestPaste?(item) }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text(let text):
            Text(text)
                .font(.system(size: 10.5))
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .lineLimit(7)
                .truncationMode(.tail)
                .padding(10)
                .frame(width: Layout.cardWidth - 14, height: Layout.cardHeight, alignment: .topLeading)

        case .image(let image):
            let size = Self.photoSize(for: image.size)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )

        case .files(let paths):
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: paths[0]))
                    .resizable()
                    .frame(width: 42, height: 42)
                Text(fileLabel(paths))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .frame(width: Layout.cardWidth - 14, height: Layout.cardHeight)
        }
    }

    private func fileLabel(_ paths: [String]) -> String {
        paths.count > 1 ? "\(paths.count) 个文件" : URL(fileURLWithPath: paths[0]).lastPathComponent
    }

    private var removeBadge: some View {
        Button { store.remove(item) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .glassFrame(circle: true)
        }
        .buttonStyle(.plain)
        .padding(3)
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: 摆动

    private func arrive() {
        swing = 14
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    private func breeze() {
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
}

enum Frame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    /// 干净的玻璃卡：系统毛玻璃 + 上亮下暗的镜面描边（Tendedero，MIT）。
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

/// 极简铝夹：金属渐变胶囊 + 一根线穿过的槽 + 软阴影（Tendedero，MIT）。
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
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
