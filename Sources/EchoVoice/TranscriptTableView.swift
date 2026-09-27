import AppKit
import SwiftUI
import EchoCore

/// AppKit asks for only visible rows; the list model loads their 200-row payload pages on demand.
struct TranscriptTableView: NSViewRepresentable {
    @ObservedObject var list: TranscriptListModel
    @ObservedObject var model: AppModel
    @ObservedObject var playbackModel: PlaybackModel
    var highlightsOnly: Bool
    var highlightedIDs: Set<String>
    var activePassageID: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = true
        table.rowHeight = 96
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("passage"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        if let column = table.tableColumns.first, abs(column.width - scroll.contentSize.width) > 1 {
            column.width = scroll.contentSize.width
        }
        let filterChanged = coordinator.highlightsOnly != highlightsOnly || coordinator.highlightedIDs != highlightedIDs
        let fullReload = coordinator.rowCount != list.count || coordinator.sessionRevision != list.sessionRevision || filterChanged
        if fullReload {
            let oldTop = table.rows(in: table.visibleRect).location
            let anchor = oldTop >= 0 && oldTop < coordinator.visibleIDs.count
                ? coordinator.visibleIDs[oldTop] : nil
            let pixelOffset = oldTop >= 0 && oldTop < table.numberOfRows
                ? max(0, scroll.contentView.bounds.minY - table.rect(ofRow: oldTop).minY) : 0
            coordinator.highlightsOnly = highlightsOnly
            coordinator.highlightedIDs = highlightedIDs
            coordinator.visibleIndices = highlightsOnly
                ? list.rows.indices.filter { highlightedIDs.contains(list.rows[$0].id) }
                : Array(list.rows.indices)
            coordinator.visibleIDs = coordinator.visibleIndices.map { list.rows[$0].id }
            coordinator.rowCount = list.count
            coordinator.loadedRevision = list.updateRevision
            _ = list.consumeChangedRows()
            coordinator.sessionRevision = list.sessionRevision
            if list.count == 0 { coordinator.lastRevealID = nil }
            table.reloadData()
            if let anchor, let source = list.index(of: anchor), let position = coordinator.visibleIndices.firstIndex(of: source) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: position).minY + pixelOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else if coordinator.loadedRevision != list.updateRevision {
            coordinator.loadedRevision = list.updateRevision
            let changed = list.consumeChangedRows()
            let viewport = table.rows(in: table.visibleRect)
            let visible = IndexSet(coordinator.visibleIndices.enumerated().compactMap { position, source in
                viewport.location != NSNotFound && position >= viewport.location &&
                    position < NSMaxRange(viewport) && changed.contains(source) ? position : nil
            })
            if !visible.isEmpty { table.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integer: 0)) }
        }
        let manualReveal = list.revealRequestRevision != coordinator.lastManualRevealRevision ? list.requestedRevealID : nil
        if manualReveal != nil { coordinator.lastManualRevealRevision = list.revealRequestRevision }
        let revealID = manualReveal ?? (model.followPlayback ? activePassageID : nil)
        if let revealID, (manualReveal != nil || revealID != coordinator.lastRevealID),
           let source = list.index(of: revealID), let position = coordinator.visibleIndices.firstIndex(of: source) {
            coordinator.lastRevealID = revealID
            table.scrollRowToVisible(position)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TranscriptTableView
        weak var table: NSTableView?
        var visibleIndices: [Int] = []
        var visibleIDs: [String] = []
        var rowCount = -1
        var loadedRevision = -1
        var sessionRevision = -1
        var highlightsOnly = false
        var highlightedIDs: Set<String> = []
        var lastRevealID: String?
        var lastManualRevealRevision = -1

        init(_ parent: TranscriptTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { visibleIndices.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < visibleIndices.count else { return nil }
            let source = visibleIndices[row]
            let root: AnyView
            if let segment = parent.list.segment(at: source) {
                root = AnyView(TranscriptRow(playbackModel: parent.playbackModel, segment: segment)
                    .environmentObject(parent.model).padding(.horizontal, 16))
            } else {
                root = AnyView(Text("Loading transcript…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).padding(.horizontal, 16))
                Task { await parent.list.loadPage(containing: source) }
            }
            let identifier = NSUserInterfaceItemIdentifier("passage-host")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<AnyView> {
                reused.rootView = root
                return reused
            }
            let view = NSHostingView(rootView: root)
            view.identifier = identifier
            return view
        }
    }
}
