let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 340),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Matrix Patch · Visual check"
private let surface = MatrixPatchSurface(frame: NSRect(x: 0, y: 0, width: 650, height: 340))
let names = ["CLICK", "GUIA", "BATERIA", "BAIXO", "GUITARRA BASE", "VOZ"] + (6...37).map { "Track \($0)" }
let ids = names.map { _ in UUID() }
surface.model.rows = [MatrixPatchRow(id: nil, number: "M", name: "Main", color: 0x68df97,
    sends: false, master: false, outputs: [.stereo], destinations: [])]
surface.model.columns = [MatrixPatchColumn(destination: .output(.master), name: "Main",
    badge: "M", color: 0x68df97, available: true)]
for patch in OutputPatch.choices(channels: 4, includeMaster: false) {
    surface.model.columns.append(MatrixPatchColumn(destination: .output(patch), name: patch.title,
        badge: patch.title, color: 0x67b9ee, available: true))
}
for index in names.indices {
    surface.model.rows.append(MatrixPatchRow(id: ids[index], number: String(index + 1), name: names[index],
        color: 0x68aacb, sends: true, master: true, outputs: [], destinations: []))
    surface.model.columns.append(MatrixPatchColumn(destination: .track(ids[index]), name: names[index],
        badge: String(index + 1), color: 0x68aacb, available: true))
}
window.contentView = surface
window.center(); window.orderFront(nil)

@MainActor private func verify() {
    surface.layoutSubtreeIfNeeded(); surface.updateContent(); surface.scroll.tile()
    let body = surface.scroll.documentView!
    var changes: [(UUID?, MatrixPatchDestination)] = []
    var enabled = false
    surface.apply = { points, connecting in
        enabled = connecting
        changes = points
    }
    func send(_ type: NSEvent.EventType, row: Int, column: Int, shift: Bool) {
        let local = NSPoint(x: (CGFloat(column) + 0.5) * MatrixPatchSurface.columnWidth,
                            y: (CGFloat(row) + 0.5) * MatrixPatchSurface.rowHeight)
        let event = NSEvent.mouseEvent(with: type, location: body.convert(local, to: nil),
            modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: body.mouseDown(with: event)
        case .leftMouseDragged: body.mouseDragged(with: event)
        default: body.mouseUp(with: event)
        }
    }
    func drawRange(fromRow: Int = 2, fromColumn: Int = 1, toRow: Int, toColumn: Int, shift: Bool = false) {
        send(.leftMouseDown, row: fromRow, column: fromColumn, shift: shift)
        send(.leftMouseDragged, row: toRow, column: toColumn, shift: shift)
        send(.leftMouseUp, row: toRow, column: toColumn, shift: shift)
    }
    drawRange(toRow: 3, toColumn: 3)
    assert(changes.count == 3 && changes.allSatisfy { $0.0 == ids[1] }, "Horizontal motion stays in the first row")
    drawRange(toRow: 5, toColumn: 2)
    assert(changes.count == 4 && changes.allSatisfy { $0.1 == surface.model.columns[1].destination }, "Vertical motion stays in the first column")
    drawRange(toRow: 2, toColumn: 3, shift: true)
    assert(enabled && changes.map { $0.0 } == [ids[1], ids[2], ids[3]] &&
           changes.map { $0.1 } == [1, 2, 3].map { surface.model.columns[$0].destination })
    for (row, col) in [(2, 1), (3, 2), (4, 3)] {
        guard case .output(let patch) = surface.model.columns[col].destination else { preconditionFailure() }
        let old = surface.model.rows[row]
        surface.model.rows[row] = MatrixPatchRow(id: old.id, number: old.number, name: old.name, color: old.color,
            sends: old.sends, master: old.master, outputs: [patch], destinations: old.destinations)
    }
    drawRange(fromRow: 4, fromColumn: 3, toRow: 5, toColumn: 1, shift: true)
    assert(!enabled && changes.map { $0.0 } == [ids[3], ids[2], ids[1]] &&
           changes.map { $0.1 } == [3, 2, 1].map { surface.model.columns[$0].destination })
    drawRange(toRow: 0, toColumn: 3, shift: true)
    assert(enabled && changes.isEmpty, "Drawing right across enabled cells must preserve them")

    surface.scroll.contentView.scroll(to: NSPoint(x: 160, y: 100))
    surface.scroll.reflectScrolledClipView(surface.scroll.contentView)
    assert(surface.scroll.contentView.bounds.minX > 0 && surface.scroll.contentView.bounds.minY > 0)
    let row = 12
    let column = surface.model.columns.indices.first { index in
        index >= 18 && surface.model.enabled(row, index)
    }!
    let expected = surface.model.columns[column].destination
    send(.leftMouseDown, row: row, column: column, shift: false)
    send(.leftMouseUp, row: row, column: column, shift: false)
    assert(changes.count == 1 && changes[0].0 == ids[row - 1] && changes[0].1 == expected)
    print("Matrix canvas: horizontal, vertical, Shift diagonals and scrolled hits passed")
    window.orderOut(nil); exit(0)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { verify() }
app.run()
