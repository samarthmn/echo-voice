import AppKit
import SwiftUI
import EchoCore

/// AppKit asks for only visible rows; the list model loads their 200-row payload pages on demand.
/// Row heights come from each hosted row's rendered height at the real column width;
/// NSTableView's automatic heights do not give SwiftUI that width when measuring.
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
        table.usesAutomaticRowHeights = false
        table.rowHeight = Coordinator.estimatedRowHeight
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
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.table = table
        return scroll
    }

    /// Fill the offered space; never report the document (full transcript) height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        func resolved(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return max(0, value)
        }
        return CGSize(width: resolved(proposal.width, fallback: 400), height: resolved(proposal.height, fallback: 300))
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
            coordinator.positions = Dictionary(uniqueKeysWithValues: coordinator.visibleIDs.enumerated().map { ($0.element, $0.offset) })
            coordinator.rowCount = list.count
            coordinator.loadedRevision = list.updateRevision
            _ = list.consumeChangedRows()
            if coordinator.sessionRevision != list.sessionRevision { coordinator.resetHeights() }
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
        static let estimatedRowHeight: CGFloat = 96
        var parent: TranscriptTableView
        weak var table: NSTableView?
        var visibleIndices: [Int] = []
        var visibleIDs: [String] = []
        var positions: [String: Int] = [:]
        private var heights: [String: CGFloat] = [:]
        private var pendingHeightRows = IndexSet()
        var rowCount = -1
        var loadedRevision = -1
        var sessionRevision = -1
        var highlightsOnly = false
        var highlightedIDs: Set<String> = []
        var lastRevealID: String?
        var lastManualRevealRevision = -1

        init(_ parent: TranscriptTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { visibleIndices.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0 && row < visibleIDs.count else { return Self.estimatedRowHeight }
            return heights[visibleIDs[row]] ?? Self.estimatedRowHeight
        }

        func resetHeights() {
            heights.removeAll()
            pendingHeightRows.removeAll()
        }

        /// Called from SwiftUI layout; table updates are deferred out of that pass and coalesced.
        func reportHeight(_ height: CGFloat, for id: String) {
            let height = ceil(height)
            guard height > 0, abs((heights[id] ?? -1) - height) > 0.5 else { return }
            heights[id] = height
            guard let position = positions[id] else { return }
            let scheduled = !pendingHeightRows.isEmpty
            pendingHeightRows.insert(position)
            guard !scheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                let rows = self.pendingHeightRows.filteredIndexSet { $0 < table.numberOfRows }
                self.pendingHeightRows.removeAll()
                guard !rows.isEmpty else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: rows)
                }
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < visibleIndices.count else { return nil }
            let source = visibleIndices[row]
            let id = visibleIDs[row]
            let content: AnyView
            if let segment = parent.list.segment(at: source) {
                content = AnyView(TranscriptRow(playbackModel: parent.playbackModel, segment: segment)
                    .environmentObject(parent.model).padding(.horizontal, 16))
            } else {
                content = AnyView(Text("Loading transcript…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).padding(.horizontal, 16))
                Task { await parent.list.loadPage(containing: source) }
            }
            let root = AnyView(content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { [weak self] proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                        self?.reportHeight(height, for: id)
                    }
                })
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
            let identifier = NSUserInterfaceItemIdentifier("passage-host")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<AnyView> {
                reused.rootView = root
                return reused
            }
            let view = NSHostingView(rootView: root)
            view.identifier = identifier
            view.sizingOptions = []
            view.clipsToBounds = true
            return view
        }
    }
}
