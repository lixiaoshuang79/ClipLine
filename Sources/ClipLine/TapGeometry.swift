import AppKit

/// 点击定位的独立解算（2026-11-24 第三次「点某张卡、选中/贴出后一张」后加）。
///
/// 不再只信 SwiftUI 的命中结果：它会在三种时序里滞后于画面——
/// ①卡片行重建、②滚动定位动画进行中、③点击期间行被滚动/重排。
/// 这三种情况下指针下真实是哪张卡，只有「事件坐标 + NSScrollView 当时的偏移」说得准。
/// 所以每次鼠标按下先按底部面板的版式常量解一次「指针下的卡」，点击事件到达 store 时以它为准。
enum TapGeometry {
    struct Sample {
        let windowNumber: Int
        let at: Date
        /// 指针下的卡在 `shown` 里的下标；nil = 不在卡片行里（顶栏、面板空白、卡片之间的缝）。
        let index: Int?
    }

    static var lastDown: Sample?

    /// 鼠标按下时调用（在事件进入 SwiftUI 手势之前）。只对底部面板解算；绳式版式不同，暂不接管。
    static func captureDown(window: NSWindow, pointInWindow: NSPoint) {
        guard window is PastePanel else {
            lastDown = nil       // 换到绳式面板时的旧样本不能串过去
            return
        }
        lastDown = Sample(windowNumber: window.windowNumber,
                          at: Date(),
                          index: cardIndex(atWindowPoint: pointInWindow, in: window))
    }

    /// 指针下的卡下标（nil = 不在任何一张卡上）。
    /// 内容坐标 = 滚动视图真实偏移 + 指针在滚动视图里的 x；
    /// 第一张卡左缘 = 行内边距 + 1pt 起始锚 + 一个卡间距（见 PastePanelView 的行布局）。
    static func cardIndex(atWindowPoint point: NSPoint, in window: NSWindow) -> Int? {
        guard let scroll = cardRow(in: window) else { return nil }
        let inScroll = scroll.convert(point, from: nil)
        guard scroll.bounds.contains(inScroll) else { return nil }
        return cardIndex(viewportX: inScroll.x,
                         scrollOffset: scroll.contentView.bounds.origin.x)
    }

    /// 纯几何部分（单元测试直接调）：视口 x 在「滚动偏移为 offset」的卡片行里落在第几张。
    static func cardIndex(viewportX: CGFloat, scrollOffset: CGFloat) -> Int? {
        let contentX = scrollOffset + viewportX
        let firstLeft = PastePanelView.rowPadding + 1 + PastePanelView.cardSpacing
        let pitch = PastePanelView.cardWidth + PastePanelView.cardSpacing
        let raw = (contentX - firstLeft) / pitch
        guard raw >= 0 else { return nil }
        let index = Int(floor(raw))
        let localX = contentX - firstLeft - CGFloat(index) * pitch
        // 落在卡片之间的缝里，或者在最后一张右侧的留白里：不算点卡。
        guard localX <= PastePanelView.cardWidth else { return nil }
        return index
    }

    /// 窗口里那根卡片行滚动视图：顶栏也有一根横向滚动条，只有 30pt 高，靠高度区分
    /// （不能只看文档宽度——历史很短时顶栏的文档反而更宽）。
    private static func cardRow(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        var candidates: [NSScrollView] = []
        func walk(_ view: NSView) {
            if view is NSTextView { return }
            if let scroll = view as? NSScrollView, scroll.frame.height >= PastePanelView.cardHeight * 0.6 {
                candidates.append(scroll)
            }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        return candidates.max { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) }
    }
}
