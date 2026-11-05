import AppKit

/// 调试：CLIPLINE_PANEL_PROBE=1（配 CLIPLINE_DEMO=1 + CLIPLINE_PANEL_STYLE=rope|paste）——
/// 对剪贴板面板做一次无人值守交互回归：合成**真实鼠标/键盘事件**走完整 视图→store 链路，
/// 断言：点卡粘贴 / 点空白收起 / 右方向键选择 / 回车粘贴 / 搜索过滤 / Esc 清词。
/// 结果写 /tmp/clipline-panel-probe.txt 后退出。探针把 onRequestPaste 换成记录器，不碰真实剪贴板。
@MainActor
final class PanelProbe {
    private let store: ClipStore
    private let reveal: () -> Void
    private let panel: () -> ClipPanel?
    private var report: [String] = []
    private var pasted: [ClipItem] = []

    init(store: ClipStore, reveal: @escaping () -> Void, panel: @escaping () -> ClipPanel?) {
        self.store = store
        self.reveal = reveal
        self.panel = panel
    }

    func run() {
        store.onRequestPaste = { [weak self] item in self?.pasted.append(item) }
        Task { @MainActor in
            await sleep(1.0)
            reveal()
            await sleep(0.6)   // 等滑入动画

            guard let board = panel(), board.isVisible else {
                note("FAIL: 面板没上屏"); return finish()
            }
            let screens = NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: " | ")
            note("屏幕=\(screens) 面板=\(NSStringFromRect(board.frame)) 鼠标=\(NSStringFromPoint(NSEvent.mouseLocation))")
            // 点击类断言按底部面板的版式计算；绳式骨架不同，只跑与版式无关的键盘/搜索项。
            let isBottom = board is PastePanel

            // 1) 双击第一张卡中心 → 应触发粘贴；单击只选中、不粘贴
            let first = store.shown.first
            if isBottom {
                pasted.removeAll()
                click(board, atCardIndex: 0, clicks: 1)
                await sleep(0.45)
                note("单击只选中: \(pasted.isEmpty ? "OK" : "FAIL")（pasted=\(pasted.count)，期望 0；selected=\(Self.short(store.selectedID))）")
                click(board, atCardIndex: 0)
                await sleep(0.5)
                note("双击卡粘贴: \(pasted.first?.id == first?.id ? "OK" : "FAIL")（pasted=\(pasted.count)，期望 1，revealed=\(store.revealed)）")
            } else {
                note("点卡粘贴: SKIP（绳式）")
            }

            // 2) 点空白收起：SwiftUI 背景手势在合成事件下收不到，这条路径 1.3.6 未改动，
            //    真机由「点面板外」的全局监视器与背景手势共同覆盖；探针里跳过。
            note("点空白收起: SKIP（合成事件测不到背景手势，本次未改该路径）")

            // 3) 再唤出：→ 选第二张，回车粘贴
            reveal()
            await sleep(0.6)
            postKey(124, to: panel())   // →
            await sleep(0.25)
            let second = store.shown.count > 1 ? store.shown[1] : nil
            note("→ 键选择: \(store.selectedItem?.id == second?.id ? "OK" : "FAIL")（selected=\(store.selectedItem?.id.uuidString.prefix(8) ?? "nil")）")
            postKey(36, to: panel())    // return
            await sleep(0.5)
            let expectedCount = isBottom ? 2 : 1   // 绳式跳过了点卡步骤
            note("回车粘贴: \(pasted.count == expectedCount && pasted.last?.id == second?.id ? "OK" : "FAIL")（pasted=\(pasted.count)，期望 \(expectedCount)）")

            // 4) 搜索过滤（走 store 的过滤链路；输入框本身由绳式已验证）
            reveal()
            await sleep(0.4)
            let before = store.shown.count
            store.replaceQuery("牙医")
            await sleep(0.3)
            note("搜索过滤: \(store.shown.count == 1 ? "OK" : "FAIL")（\(before) → \(store.shown.count)，期望 1）")
            store.replaceQuery("")
            await sleep(0.2)

            // 5) Esc 清词（再按一次收起由绳式覆盖）
            store.replaceQuery("牙医")
            await sleep(0.2)
            postKey(53, to: panel())    // esc
            await sleep(0.3)
            note("Esc 清词: \(store.query.isEmpty ? "OK" : "FAIL")（query=\"\(store.query)\"）")

            // 6) 标签视图（Paste 式）：切到演示标签 → 板内是归类过的条目；Esc 先回历史、再收起。
            if isBottom, let demoBoard = store.boards.first {
                store.activeBoardID = demoBoard.id   // 与点标签页等价（右键菜单是 NSMenu，不适合合成）
                await sleep(0.3)
                let members = store.shown.map(\.id)
                let allBoarded = members.allSatisfy { id in
                    store.items.first { $0.id == id }?.boards.isEmpty == false
                }
                note("标签视图: \(members.count == 2 && allBoarded ? "OK" : "FAIL")（\(members.count) 条，期望 2）")
                postKey(53, to: panel())   // esc：标签 → 剪贴板历史
                await sleep(0.3)
                note("Esc 回历史: \(store.activeBoardID == nil ? "OK" : "FAIL")")
                postKey(53, to: panel())   // esc：历史 → 收起
                await sleep(0.4)
                note("Esc 收起: \(store.revealed ? "FAIL（没收起）" : "OK")")
            } else {
                note("标签视图: SKIP（绳式或没有标签）")
            }

            // 7) 绳式「全部」视图（切换控件默认项）：标签里的条目照常挂在绳上。
            if !isBottom, let demoBoard = store.boards.first {
                store.activeBoardID = nil
                await sleep(0.25)
                note("全部视图: \(store.shown.count == 11 ? "OK" : "FAIL")（\(store.shown.count) 条，期望 11）")
                store.activeBoardID = demoBoard.id
                await sleep(0.25)
                note("绳上标签视图: \(store.shown.count == 2 ? "OK" : "FAIL")（\(store.shown.count) 条，期望 2）")
                store.activeBoardID = nil
            } else {
                note("全部视图: SKIP（底部面板或没有标签）")
            }

            // 8) 行内输入框的收笔（Paste 式）：⇧⌘N 进入新建态 → 点别处 → 之后的输入应进搜索框
            if isBottom {
                reveal()   // 第 6 步末尾已收起，先唤出再操作
                await sleep(0.6)
                NotificationCenter.default.post(name: .clipLineCreateBoard, object: nil)
                await sleep(0.4)
                click(board, atCardIndex: 0, clicks: 1)   // 点一张卡（等价于点到行内框之外，且单击不该粘贴）
                await sleep(0.7)
                note("收笔后状态: revealed=\(store.revealed) key=\(board.isKeyWindow) "
                     + "firstResponder=\(String(describing: board.firstResponder.map { String(describing: type(of: $0)) }))")
                postKey(6, to: panel(), characters: "z")   // 键入 z
                await sleep(0.4)
                note("行内输入收笔: \(store.query == "z" ? "OK" : "FAIL")（query=\"\(store.query)\"，期望 z）")
                store.replaceQuery("")
                await sleep(0.2)
            } else {
                note("行内输入收笔: SKIP（绳式）")
            }

            // 9) 面板收起时前插两条（模拟「先截图、再唤出」）：唤出后点屏幕上的 1 号位，
            //    必须命中当时可见的 1 号卡；若命中表和画面脱节，会落到挪到 3 号位的旧卡。
            if isBottom {
                _ = board
                board.onEscape?()               // 收起（走 store.escape → onRequestTuck）
                await sleep(0.5)
                // 9a) 静态点图：不插入任何东西，逐张点前 5 个位置，核对「点哪张 = 拿到哪张」。
                reveal()
                await sleep(0.8)
                for index in 0 ..< min(5, store.shown.count) {
                    pasted.removeAll()
                    click(board, atCardIndex: index)
                    await sleep(0.25)
                    let expected = store.shown.count > index ? store.shown[index].id : nil
                    let actual = pasted.last?.id
                    note("静态点第\(index + 1)张: \(actual == expected ? "OK" : "FAIL")（期望 \(Self.short(expected))，实际 \(Self.short(actual))，revealed=\(store.revealed)）")
                }
                board.onEscape?()
                await sleep(0.5)
                // 演示数据里有一张置顶卡排在 0 号位；真正会被前插顶走的是第一条非置顶卡。
                let k = store.shown.firstIndex { !$0.pinned } ?? 0
                let beforeIDs = store.shown.prefix(4).map(\.id)
                note("收起后插入前: \(beforeIDs.prefix(4).map { Self.short($0) }.joined(separator: ","))（首个非置顶位=\(k)）")
                store.ingest(Self.probeText("probe-insert-1"))
                store.ingest(Self.probeText("probe-insert-2"))
                await sleep(0.3)
                note("插入后列表头: \(store.shown.prefix(5).map { Self.short($0.id) }.joined(separator: ","))")
                reveal()
                await sleep(0.8)                // 等滑入与重排动画结束
                if let board = panel() {
                    pasted.removeAll()
                    click(board, atCardIndex: k)
                    await sleep(0.4)
                    let expected = store.shown.count > k ? store.shown[k].id : nil
                    let actual = pasted.last?.id
                    note("唤出后点击\((k + 1))号: \(actual == expected ? "OK" : "FAIL")（期望 \(Self.short(expected))，实际 \(Self.short(actual))；插入前该位=\(Self.short(beforeIDs.count > k ? beforeIDs[k] : nil))）")
                    pasted.removeAll()
                    click(board, atCardIndex: k + 2)
                    await sleep(0.4)
                    let expected3 = store.shown.count > k + 2 ? store.shown[k + 2].id : nil
                    let actual3 = pasted.last?.id
                    note("唤出后点击\((k + 3))号: \(actual3 == expected3 ? "OK" : "FAIL")（期望 \(Self.short(expected3))，实际 \(Self.short(actual3))；插入前该位=\(Self.short(beforeIDs.count > k + 2 ? beforeIDs[k + 2] : nil))）")
                    // 再唤出一次（这次没有新插入）：如果上一轮把命中表弄乱了，这里应恢复正常。
                    board.onEscape?()
                    await sleep(0.5)
                    reveal()
                    await sleep(0.8)
                    pasted.removeAll()
                    click(board, atCardIndex: k)
                    await sleep(0.4)
                    let againExpected = store.shown.count > k ? store.shown[k].id : nil
                    let againActual = pasted.last?.id
                    note("二次唤出点击\((k + 1))号: \(againActual == againExpected ? "OK" : "FAIL")（期望 \(Self.short(againExpected))，实际 \(Self.short(againActual))）")

                    // 9c) 展开期间新复制只入账、不上屏：卡片不能在指针底下挪位。
                    // 容量到顶时允许尾部淘汰一张，但前排顺序必须原样。
                    let frozen = store.shown.map(\.id)
                    store.ingest(Self.probeText("probe-while-open"))
                    await sleep(0.2)
                    let head = Array(store.shown.prefix(8).map(\.id))
                    let frozenHead = Array(frozen.prefix(8))
                    note("展开中插入不挪卡: \(head == frozenHead ? "OK" : "FAIL")（\(frozen.count) → \(store.shown.count)）")
                    board.onEscape?()
                    await sleep(0.6)
                    let landed = store.shown.contains { $0.fingerprint == "t:probe-while-open" }
                    note("收起后新条目上屏: \(landed ? "OK" : "FAIL")（头=\(store.shown.first?.fingerprint.prefix(20) ?? "-")）")
                }
            } else {
                note("收起插入点击: SKIP（绳式）")
            }

            // 10) 真机复现形态（2026-11-05）：面板完全收起后进来两张图 → 唤出（滑入 + scrollToStart）
            //     → 按屏幕几何逐张点。若命中表与画面脱节，会出现「点第 1 张、拿到第 3 张」。
            //     与第 9 步的区别：图卡 + 显式等收起完成 + 逐点位核对全部前 4 张。
            if isBottom {
                board.onEscape?()
                await sleep(0.8)                 // 等滑出与 orderOut 完成，此时面板真的不在屏上
                store.ingest(Self.probeImage("probe-img-1"))
                store.ingest(Self.probeImage("probe-img-2"))
                await sleep(0.5)
                note("10-前插后列表头: \(store.shown.prefix(5).map { Self.short($0.id) }.joined(separator: ","))")
                reveal()
                await sleep(1.2)                 // 等滑入、scrollToStart 与插入动画全部结束
                for index in 0 ..< min(4, store.shown.count) {
                    pasted.removeAll()
                    click(board, atCardIndex: index)
                    await sleep(0.45)
                    let expected = store.shown[index].id
                    let actual = pasted.last?.id
                    let got = actual.flatMap { id in store.shown.firstIndex { $0.id == id } } ?? -1
                    note("10-前插后点第\(index + 1)张: \(actual == expected ? "OK" : "FAIL")"
                         + "（期望 \(Self.short(expected))，实际 \(Self.short(actual))[第\(got + 1)张]，"
                         + "selected=\(Self.short(store.selectedID))）")
                }

                // 11) 同样的前插，但收起前把列表横向滚离开头——下次唤出必须滚回起点。
                //     真机上 11:38 那次点的就是第 7 张（在 1512pt 屏上不滚看不见），13:37 再唤出就错位了。
                board.onEscape?()
                await sleep(0.8)
                reveal()
                await sleep(0.8)
                for _ in 0 ..< 8 { store.select(offset: 1) }   // 选择并滚到第 9 张附近
                await sleep(0.8)                               // 等滚动动画结束
                board.onEscape?()
                await sleep(0.8)
                store.ingest(Self.probeImage("probe-img-3"))
                store.ingest(Self.probeImage("probe-img-4"))
                await sleep(0.4)
                reveal()
                await sleep(1.2)
                note("11-滚动后再唤出列表头: \(store.shown.prefix(5).map { Self.short($0.id) }.joined(separator: ","))")
                for index in 0 ..< min(4, store.shown.count) {
                    pasted.removeAll()
                    click(board, atCardIndex: index)
                    await sleep(0.45)
                    let expected = store.shown[index].id
                    let actual = pasted.last?.id
                    let got = actual.flatMap { id in store.shown.firstIndex { $0.id == id } } ?? -1
                    note("11-滚动后再点第\(index + 1)张: \(actual == expected ? "OK" : "FAIL")"
                         + "（期望 \(Self.short(expected))，实际 \(Self.short(actual))[第\(got + 1)张]）")
                }

                // 12) 长列表（对齐真机几百条）+ 滚到很靠后：开头锚点在懒加载范围外，
                //     scrollTo(startAnchor) 可能找不到视图而不生效——下次唤出就停在旧位置。
                note("12-滚动偏移（插入前）: \(scrollOffset(board))")
                for i in 0 ..< 300 { store.ingest(Self.probeText("bulk-\(i)")) }
                await sleep(0.6)
                reveal()
                await sleep(1.0)
                note("12-唤出后偏移: \(scrollOffset(board))")
                for _ in 0 ..< 40 { store.select(offset: 1) }
                await sleep(1.2)                 // 等最后一跳滚动动画结束
                note("12-滚远后偏移: \(scrollOffset(board))")
                let parkedOn = store.selectedID
                board.onEscape?()
                await sleep(0.8)
                reveal()
                await sleep(1.2)
                let headIDs = store.shown.prefix(3).map { Self.short($0.id) }.joined(separator: ",")
                note("12-长列表滚远后唤出: 现有 \(store.shown.count) 条，头=\(headIDs)，"
                     + "收起时选中=\(Self.short(parkedOn))")
                note("12-长列表唤出后偏移: \(scrollOffset(board))")
                pasted.removeAll()
                click(board, atCardIndex: 0)
                await sleep(0.5)
                let expected0 = store.shown[0].id
                let actual0 = pasted.last?.id
                let got0 = actual0.flatMap { id in store.shown.firstIndex { $0.id == id } } ?? -1
                note("12-长列表点第1张: \(actual0 == expected0 ? "OK" : "FAIL")"
                     + "（期望 \(Self.short(expected0))，实际 \(Self.short(actual0))[第\(got0 + 1)张]）")
            } else {
                note("前插后点卡: SKIP（绳式）")
            }

            finish()
        }
    }

    /// 造一条纯文本剪贴（探针专用，不进磁盘）。
    private static func probeText(_ text: String) -> ClipItem {
        ClipItem(kind: .text(text), source: .unknown, copiedAt: Date(),
                 snapshot: [[.string: Data(text.utf8)]], fingerprint: "t:" + text)
    }

    /// 造一张图卡（探针专用）：不同编号画不同条数的横线，保证内容与指纹各不相同。
    private static func probeImage(_ name: String) -> ClipItem {
        let size = NSSize(width: 400, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.16, green: 0.36, blue: 0.72, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        let bars = 1 + (abs(name.hashValue) % 5)
        for i in 0 ..< bars {
            NSRect(x: 24, y: 40 + i * 40, width: 352, height: 12).fill()
        }
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let item = ClipItem.make(snapshot: [[.tiff: data]], source: .unknown) else {
            return probeText(name)
        }
        return item
    }

    private static func short(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "nil"
    }

    /// 面板里真正在渲染的滚动偏移（SwiftUI 的 ScrollView 底层是 NSScrollView）。
    /// 命中表若与画面脱节，这个数会和 SwiftUI 认为的位置对不上——探针里当硬指标看。
    /// 顶栏也有一根横向滚动条，取文档最宽的那根（卡片行）。
    private func scrollOffset(_ board: ClipPanel) -> String {
        guard let content = board.contentView else { return "no-content" }
        var all: [NSScrollView] = []
        func walk(_ view: NSView) {
            if view is NSTextView { return }
            if let scroll = view as? NSScrollView { all.append(scroll) }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        guard !all.isEmpty else { return "no-scrollview" }
        let widest = all.max { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) }!
        let summary = all.map { "x=\(Int($0.contentView.bounds.origin.x))/doc=\(Int($0.documentView?.frame.width ?? 0))" }
        return summary.joined(separator: " | ")
            + " → 卡片行 x=\(Int(widest.contentView.bounds.origin.x))"
    }

    // MARK: 事件合成

    /// 点第 index 张卡的中心（几何按 PastePanelView 常量折算；绳式请用 CLIPLINE_PANEL_STYLE=paste）。
    /// `clicks` = 2 模拟双击（粘贴），1 = 单击（只选中）。
    private func click(_ board: ClipPanel, atCardIndex index: Int, clicks: Int = 2) {
        let p = board.frame
        let firstLeft = p.minX + PastePanelView.rowPadding + 1 + PastePanelView.cardSpacing
        let centerX = firstLeft + PastePanelView.cardWidth / 2
            + CGFloat(index) * (PastePanelView.cardWidth + PastePanelView.cardSpacing)
        let centerY = p.maxY - PastePanelView.chromeHeight - PastePanelView.cardHeight / 2
        clickScreen(board, at: NSPoint(x: centerX, y: centerY), clicks: clicks)
    }

    private func clickScreen(_ board: ClipPanel, at screenPoint: NSPoint, clicks: Int = 1) {
        let local = NSPoint(x: screenPoint.x - board.frame.minX, y: screenPoint.y - board.frame.minY)
        for pass in 1 ... max(clicks, 1) {
            // 两下之间留一点真实间隔：同一个 runloop 里一口气投递，SwiftUI 的双击识别器有时收不到第二下。
            if pass > 1 { usleep(70_000) }
            for (type, pressure): (NSEvent.EventType, Float) in [(.leftMouseDown, 1), (.leftMouseUp, 0)] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: board.windowNumber, context: nil, eventNumber: 0, clickCount: pass,
                    pressure: pressure) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func postKey(_ keyCode: UInt16, to board: ClipPanel?, characters: String = "") {
        guard let board else { return }
        for isDown in [true, false] {
            guard let event = NSEvent.keyEvent(
                with: isDown ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: board.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func note(_ line: String) {
        report.append(line)
        FileHandle.standardError.write("probe: \(line)\n".data(using: .utf8)!)
    }

    private func finish() {
        try? report.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/clipline-panel-probe.txt"),
                                                  atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
