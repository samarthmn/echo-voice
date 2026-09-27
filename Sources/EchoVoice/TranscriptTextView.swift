import SwiftUI
import AppKit
import EchoCore

/// One selectable text surface per passage, not one button per word.
struct TranscriptTextView: NSViewRepresentable {
    var segment: TranscriptSegment
    var time: Double?
    var highlights: [NSRange]
    var play: (Double) -> Void
    var highlight: (NSRange) -> Void
    var selectionChanged: (NSRange) -> Void
    func makeNSView(context: Context) -> PassageTextView {
        let view = PassageTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true; view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func updateNSView(_ view: PassageTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.playSelection = { range in play(anchor(range)) }
        view.highlightSelection = highlight
        let activeRanges = time.map { TranscriptTiming.activeWords(in: segment, at: $0).map(\.range) } ?? []
        let baseChanged = coordinator.lastText != segment.text || coordinator.lastWords != segment.words || coordinator.lastHighlights != highlights
        guard baseChanged || coordinator.lastActiveRanges != activeRanges else { return }
        coordinator.updating = true
        defer {
            coordinator.lastText = segment.text
            coordinator.lastWords = segment.words
            coordinator.lastHighlights = highlights
            coordinator.lastActiveRanges = activeRanges
            coordinator.updating = false
        }
        view.linkTextAttributes = [.foregroundColor: NSColor.labelColor, .cursor: NSCursor.pointingHand]
        if !baseChanged, let storage = view.textStorage {
            storage.beginEditing()
            for range in coordinator.lastActiveRanges {
                storage.removeAttribute(.backgroundColor, range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                for highlight in highlights where NSIntersectionRange(range, highlight).length > 0 {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.20), range: NSIntersectionRange(range, highlight))
                }
            }
            for range in activeRanges {
                storage.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.30), .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            storage.endEditing()
            return
        }
        let text = NSMutableAttributedString(string: segment.text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
        for range in highlights where range.location >= 0 && NSMaxRange(range) <= text.length { text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.20), range: range) }
        for word in segment.words ?? [] where word.valid(in: segment.text, start: segment.startTime, end: segment.endTime) {
            text.addAttribute(.link, value: NSNumber(value: word.start), range: word.range)
        }
        for range in activeRanges { text.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.30), .underlineStyle: NSUnderlineStyle.single.rawValue], range: range) }
        let selection = view.selectedRanges
        view.textStorage?.setAttributedString(text)
        view.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= text.length }
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(20, ceil(layout.usedRect(for: container).height)))
    }
    private func anchor(_ range: NSRange) -> Double { segment.words?.first { NSIntersectionRange($0.range, range.length == 0 ? NSRange(location: range.location, length: 1) : range).length > 0 }?.start ?? segment.startTime }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView; var updating = false
        var lastText: String?
        var lastWords: [TranscriptWord]?
        var lastHighlights: [NSRange] = []
        var lastActiveRanges: [NSRange] = []
        init(_ parent: TranscriptTextView) { self.parent = parent }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { guard let number = link as? NSNumber else { return true }; parent.play(number.doubleValue); return true }
        func textViewDidChangeSelection(_ notification: Notification) { if !updating, let view = notification.object as? NSTextView { parent.selectionChanged(view.selectedRange()) } }
    }
}
final class PassageTextView: NSTextView {
    var playSelection: ((NSRange) -> Void)?
    var highlightSelection: ((NSRange) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let play = NSMenuItem(title: "Play from here", action: #selector(playHere), keyEquivalent: ""); play.target = self
        let highlight = NSMenuItem(title: "Highlight / remove highlight", action: #selector(saveHighlight), keyEquivalent: ""); highlight.target = self; highlight.isEnabled = selectedRange().length > 0
        menu.insertItem(.separator(), at: 0); menu.insertItem(highlight, at: 0); menu.insertItem(play, at: 0)
        return menu
    }
    @objc private func playHere() { playSelection?(selectedRange()) }
    @objc private func saveHighlight() { highlightSelection?(selectedRange()) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.control) { playHere(); return }
        super.keyDown(with: event)
    }
}

/// Limit shortcuts and wheel observation to this workspace, excluding sheets and editors.
struct ReplayEventMonitor: NSViewRepresentable {
    var onScroll: () -> Void
    var onSpace: () -> Void
    func makeNSView(context: Context) -> ReplayEventView { let view = ReplayEventView(); view.install(); return view }
    func updateNSView(_ view: ReplayEventView, context: Context) { view.onScroll = onScroll; view.onSpace = onSpace }
    static func dismantleNSView(_ view: ReplayEventView, coordinator: ()) { view.removeMonitor() }
}
final class ReplayEventView: NSView {
    var onScroll: (() -> Void)?
    var onSpace: (() -> Void)?
    private var monitor: Any?
    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
            if event.type == .scrollWheel { self.onScroll?(); return event }
            let text = window.firstResponder as? NSTextView
            guard event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  text?.isEditable != true, !(window.firstResponder is NSControl) else { return event }
            self.onSpace?(); return nil
        }
    }
    func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
