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
            // 点击类断言按底部面板的版式计算；绳式骨架不同，只跑与版式无关的键盘/搜索项。
            let isBottom = board is PastePanel

            // 1) 点第一张卡中心 → 应触发粘贴
            let first = store.shown.first
            if isBottom {
                click(board, atCardIndex: 0)
                await sleep(0.5)
                note("点卡粘贴: \(pasted.first?.id == first?.id ? "OK" : "FAIL")（pasted=\(pasted.count)，期望 1）")
            } else {
                note("点卡粘贴: SKIP（绳式）")
            }

            // 2) 点卡行下方空白 → 应收起
            if isBottom, let b = panel(), b.isVisible {
                let p = b.frame
                clickScreen(b, at: NSPoint(x: p.midX, y: p.minY + 14))
                await sleep(0.7)
                note("点空白收起: \(store.revealed ? "FAIL（没收起）" : "OK")")
            } else {
                note("点空白收起: SKIP（绳式或面板已不可见）")
            }

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
                click(board, atCardIndex: 0)   // 点一张卡（等价于点到行内框之外）
                await sleep(0.4)
                postKey(6, to: panel(), characters: "z")   // 键入 z
                await sleep(0.4)
                note("行内输入收笔: \(store.query == "z" ? "OK" : "FAIL")（query=\"\(store.query)\"，期望 z）")
                store.replaceQuery("")
                await sleep(0.2)
            } else {
                note("行内输入收笔: SKIP（绳式）")
            }

            finish()
        }
    }

    // MARK: 事件合成

    /// 点第 index 张卡的中心（几何按 PastePanelView 常量折算；绳式请用 CLIPLINE_PANEL_STYLE=paste）。
    private func click(_ board: ClipPanel, atCardIndex index: Int) {
        let p = board.frame
        let firstLeft = p.minX + PastePanelView.rowPadding + 1 + PastePanelView.cardSpacing
        let centerX = firstLeft + PastePanelView.cardWidth / 2
            + CGFloat(index) * (PastePanelView.cardWidth + PastePanelView.cardSpacing)
        let centerY = p.maxY - PastePanelView.chromeHeight - PastePanelView.cardHeight / 2
        clickScreen(board, at: NSPoint(x: centerX, y: centerY))
    }

    private func clickScreen(_ board: ClipPanel, at screenPoint: NSPoint) {
        let local = NSPoint(x: screenPoint.x - board.frame.minX, y: screenPoint.y - board.frame.minY)
        for (type, pressure): (NSEvent.EventType, Float) in [(.leftMouseDown, 1), (.leftMouseUp, 0)] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: board.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: pressure) else { continue }
            NSApp.postEvent(event, atStart: false)
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
