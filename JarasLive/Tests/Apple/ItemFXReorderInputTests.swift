import AppKit
import SwiftUI
@testable import JarasApplication
private enum JarasLocalization { static func string(_ value: String) -> String { value } }
@MainActor private final class ItemRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let dragType = NSPasteboard.PasteboardType("com.jaras.fx-order")
    let list: FXChainTableView
    var settings = NativeFXSettings()
    var rows: [(effect: String, name: String)] { settings.clipEffectKeys.map { ($0, settings.kind(of: $0)) } }
    let targetIsCurrent = true
    init(_ list: FXChainTableView) {
        self.list = list
        settings.inserted = ["EQ", "Compressor", "Delay"]
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if column?.identifier.rawValue == "name" { return FXChainEffectNameView(labelWithString: rows[row].name) }
        return nil
    }
    func moveEffect(_ effect: String, to row: Int) -> Bool {
        let target = rows.indices.contains(row) ? rows[row].effect : nil
        return settings.reorderClipEffect(effect, before: target) != nil
    }
    // Use the production pasteboard and drop delegates in the AppKit fixture.
    // FX_CHAIN_DRAG_DELEGATES
}
final class ItemDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source: NSTableView) { draggingSource = source; super.init() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
@MainActor private func run() throws {
    _ = NSApplication.shared
    let table = FXChainTableView(frame: NSRect(x: 0, y: 0, width: 190, height: 300))
    for (name, width) in [("enabled", 30.0), ("name", 148.0)] {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); column.width = width
        table.addTableColumn(column)
    }
    table.headerView = nil
    precondition(table.canDragRows(with: IndexSet(integer: 0), at: NSPoint(x: 80, y: 10)))
    precondition(!table.canDragRows(with: IndexSet(integer: 0), at: NSPoint(x: 15, y: 10)), "Bypass presses must not drag plugins")
    let label = FXChainEffectNameView(labelWithString: "EQ")
    label.frame = NSRect(x: 32, y: 0, width: 148, height: 28)
    precondition(label.hitTest(NSPoint(x: 80, y: 10)) == nil, "Plugin labels must pass the first drag press to their table")
    let model = ItemRows(table)
    table.dataSource = model; table.delegate = model
    table.reloadData()
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let drag = ItemDragInfo(source: table)
    let item = model.tableView(table, pasteboardWriterForRow: 2)!
    precondition(drag.draggingPasteboard.writeObjects([item]))
    precondition(model.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .on) == .move)
    precondition(model.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above))
    precondition(model.rows.map(\.name) == ["Delay", "EQ", "Compressor"], "The same native drop used by tracks must change the item FX order")
    let foreign = ItemDragInfo(source: NSTableView())
    precondition(model.tableView(table, validateDrop: foreign, proposedRow: 1, proposedDropOperation: .on) == [])
    let project = UUID(), clip = UUID()
    let payload = ClipFXReorderPayload(project: project, clip: clip, effect: "EQ")
    let provider = payload.provider()
    precondition(provider.hasItemConformingToTypeIdentifier(ClipFXReorderPayload.type))
    var finished = false
    provider.loadDataRepresentation(forTypeIdentifier: ClipFXReorderPayload.type) { data, error in
        precondition(error == nil && data != nil)
        precondition(ClipFXReorderPayload.effect(from: data!, project: project, clip: clip) == "EQ")
        precondition(ClipFXReorderPayload.effect(from: data!, project: UUID(), clip: clip) == nil)
        precondition(ClipFXReorderPayload.effect(from: data!, project: project, clip: UUID()) == nil)
        DispatchQueue.main.async { finished = true }
    }
    let deadline = Date().addingTimeInterval(3)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(finished, "The native item FX drag must deliver a scoped payload")
    print("ITEM_FX_SHARED_TABLE_DROP_UPDATES_ITEM_ORDER_AND_NATIVE_SCOPED_PAYLOAD_OK")
}
try MainActor.assumeIsolated { try run() }
