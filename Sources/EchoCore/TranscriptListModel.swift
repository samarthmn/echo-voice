import Combine
import Foundation

/// Main-actor projection of a lightweight transcript timeline and three decoded pages.
@MainActor
public final class TranscriptListModel: ObservableObject {
    @Published public private(set) var rows: [TranscriptRowIdentity] = []
    @Published public private(set) var updateRevision = 0
    @Published public private(set) var sessionRevision = 0
    @Published public private(set) var requestedRevealID: String?
    @Published public private(set) var revealRequestRevision = 0
    @Published public private(set) var error: String?

    private let source: any TranscriptPageSource
    private let pageSize = 200
    private var meetingID: String?
    private var versionID: String?
    private var generation = 0
    private var loadGeneration = 0
    private var timelineRevision = 0
    private var consecutivePageMismatches = 0
    private var rowIndex: [String: Int] = [:]
    private var maximumEnds: [Double] = []
    private var pages: [Int: [TranscriptSegment]] = [:]
    private var pageRevisions: [Int: Int] = [:]
    private var recentlyUsedPages: [Int] = []
    private var loadingPages: Set<Int> = []
    private var changedRows = IndexSet()

    public convenience init(store: MeetingStore) { self.init(source: store) }
    public init(source: any TranscriptPageSource) { self.source = source }

    public var cachedSegmentCount: Int { pages.values.reduce(0) { $0 + $1.count } }
    public var count: Int { rows.count }

    public func reset() {
        generation += 1
        loadGeneration += 1
        sessionRevision += 1
        meetingID = nil
        versionID = nil
        timelineRevision = 0
        consecutivePageMismatches = 0
        rows = []
        requestedRevealID = nil
        rowIndex = [:]
        maximumEnds = []
        pages.removeAll()
        pageRevisions.removeAll()
        recentlyUsedPages.removeAll()
        loadingPages.removeAll()
        changedRows.removeAll()
        error = nil
    }

    public func load(meetingID: String, versionID: String) async {
        let sameTarget = self.meetingID == meetingID && self.versionID == versionID
        if sameTarget {
            loadGeneration += 1
        } else {
            reset()
        }
        let request = loadGeneration
        self.meetingID = meetingID
        self.versionID = versionID
        do {
            let timeline = try await Task.detached(priority: .userInitiated) { [source] in
                try source.transcriptTimeline(meetingID: meetingID, versionID: versionID)
            }.value
            guard loadGeneration == request else { return }
            if sameTarget && timeline.rows == rows {
                if timeline.transcriptRevision == timelineRevision {
                    if pages.isEmpty && !rows.isEmpty { await loadPage(containing: 0) }
                    return
                }
                generation += 1
                timelineRevision = timeline.transcriptRevision
                loadingPages.removeAll()
                for pageNumber in recentlyUsedPages {
                    guard loadGeneration == request else { return }
                    await loadPage(containing: pageNumber * pageSize)
                }
                guard loadGeneration == request else { return }
                if pages.isEmpty && !rows.isEmpty { await loadPage(containing: 0) }
                guard loadGeneration == request else { return }
                error = nil
                return
            }
            generation += 1
            pages.removeAll()
            pageRevisions.removeAll()
            recentlyUsedPages.removeAll()
            loadingPages.removeAll()
            changedRows.removeAll()
            sessionRevision += 1
            timelineRevision = timeline.transcriptRevision
            rows = timeline.rows
            rowIndex = Dictionary(uniqueKeysWithValues: timeline.rows.enumerated().map { ($0.element.id, $0.offset) })
            var maximum = -Double.infinity
            maximumEnds = timeline.rows.map { maximum = max(maximum, $0.endTime); return maximum }
            if !timeline.rows.isEmpty { await loadPage(containing: 0) }
        } catch {
            guard loadGeneration == request else { return }
            self.error = error.localizedDescription
        }
    }

    public func segment(at index: Int) -> TranscriptSegment? {
        guard index >= 0 && index < rows.count else { return nil }
        let offset = index % pageSize
        guard let page = pages[index / pageSize], offset < page.count,
              page[offset].id == rows[index].id else { return nil }
        return page[offset]
    }

    public func loadPage(containing index: Int) async {
        guard index >= 0 && index < rows.count, let meetingID, let versionID else { return }
        let pageNumber = index / pageSize
        if pages[pageNumber] != nil && pageRevisions[pageNumber] == timelineRevision {
            touch(pageNumber); return
        }
        guard loadingPages.insert(pageNumber).inserted else { return }
        let request = generation
        let firstIndex = pageNumber * pageSize
        let anchor = firstIndex == 0 ? nil : rows[firstIndex - 1].id
        let expectedRevision = timelineRevision
        do {
            let page = try await Task.detached(priority: .userInitiated) { [source] in
                try source.transcriptPage(.init(meetingID: meetingID, versionID: versionID,
                                               anchor: anchor, direction: .forward, limit: 200,
                                               expectedRevision: expectedRevision))
            }.value
            guard generation == request else { return }
            loadingPages.remove(pageNumber)
            let expectedRows = Array(rows[firstIndex..<min(firstIndex + pageSize, rows.count)])
            guard page.transcriptRevision == expectedRevision,
                  page.rows.map(\.id) == expectedRows.map(\.id) else {
                await refreshAfterPageMismatch(meetingID: meetingID, versionID: versionID)
                return
            }
            consecutivePageMismatches = 0
            let previous = pages[pageNumber]
            pages[pageNumber] = page.rows
            pageRevisions[pageNumber] = expectedRevision
            for offset in page.rows.indices where previous.flatMap({ offset < $0.count ? $0[offset] : nil }) != page.rows[offset] {
                changedRows.insert(firstIndex + offset)
            }
            touch(pageNumber)
            while recentlyUsedPages.count > 3 {
                let evicted = recentlyUsedPages.removeFirst()
                pages.removeValue(forKey: evicted)
                pageRevisions.removeValue(forKey: evicted)
                let start = evicted * pageSize
                changedRows.insert(integersIn: start..<min(start + pageSize, rows.count))
            }
            if !changedRows.isEmpty { updateRevision += 1 }
        } catch {
            guard generation == request else { return }
            loadingPages.remove(pageNumber)
            if let coreError = error as? EchoCoreError, coreError == .staleTranscriptRevision {
                await refreshAfterPageMismatch(meetingID: meetingID, versionID: versionID)
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func refreshAfterPageMismatch(meetingID: String, versionID: String) async {
        for pageNumber in pages.keys {
            let start = pageNumber * pageSize
            changedRows.insert(integersIn: start..<min(start + pageSize, rows.count))
        }
        pages.removeAll()
        pageRevisions.removeAll()
        recentlyUsedPages.removeAll()
        updateRevision += 1
        guard consecutivePageMismatches < 1 else {
            error = "Transcript changed while loading. Try again."
            return
        }
        consecutivePageMismatches += 1
        await load(meetingID: meetingID, versionID: versionID)
    }

    @discardableResult
    public func reveal(segmentID: String) async -> Int? {
        for _ in 0..<2 {
            guard let index = rowIndex[segmentID] else { return nil }
            let request = generation
            await loadPage(containing: index)
            if generation != request { continue }
            guard rowIndex[segmentID] == index,
                  segment(at: index)?.id == segmentID else { return nil }
            requestedRevealID = segmentID
            revealRequestRevision += 1
            return index
        }
        return nil
    }

    public func index(of segmentID: String) -> Int? { rowIndex[segmentID] }

    public func consumeChangedRows() -> IndexSet {
        let result = changedRows
        changedRows.removeAll()
        return result
    }

    public func activeSegmentID(at time: Double, track: AudioTrack? = nil) -> String? {
        guard time.isFinite, !rows.isEmpty else { return nil }
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].startTime <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0 && maximumEnds[index] > time {
            let row = rows[index]
            if row.endTime > time && (track == nil || row.track == track) { return row.id }
            index -= 1
        }
        return nil
    }

    private func touch(_ page: Int) {
        recentlyUsedPages.removeAll { $0 == page }
        recentlyUsedPages.append(page)
    }
}
