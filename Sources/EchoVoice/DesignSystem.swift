import SwiftUI
import AppKit
import EchoCore

enum Theme {
    static let accent = Color.teal
    enum Space {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
    }
    enum Font {
        static let hero = SwiftUI.Font.system(size: 34, weight: .semibold, design: .rounded)
        static let pageTitle = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let sectionTitle = SwiftUI.Font.headline
    }
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let subtleFill = Color.primary.opacity(0.045)
    static let cardStroke = Color(nsColor: .separatorColor).opacity(0.6)
}

enum StatusTone: Equatable {
    case ready, progress, attention, problem, neutral
    var color: Color {
        switch self {
        case .ready: .green
        case .progress: Theme.accent
        case .attention: .orange
        case .problem: .red
        case .neutral: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .progress: "arrow.down.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .problem: "xmark.octagon.fill"
        case .neutral: "circle.dashed"
        }
    }
}

extension SetupReadiness.ItemState {
    var tone: StatusTone {
        switch self {
        case .ready: .ready
        case .inProgress, .checking: .progress
        case .actionNeeded: .attention
        case .problem: .problem
        case .off, .informational: .neutral
        }
    }
    var label: String {
        switch self {
        case .ready: "Ready"
        case .checking: "Checking"
        case .inProgress(let fraction): fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Starting"
        case .actionNeeded: "Action needed"
        case .problem: "Needs attention"
        case .off: "Off"
        case .informational: "Not yet asked"
        }
    }
}

extension SetupReadiness.Overall {
    var tone: StatusTone {
        switch self {
        case .ready: .ready
        case .checking, .downloading: .progress
        case .setupRequired, .permissionNeeded: .attention
        case .attention: .problem
        }
    }
    var title: String {
        switch self {
        case .checking: "Checking setup…"
        case .ready: "Ready to transcribe"
        case .setupRequired: "Transcription needs setup"
        case .permissionNeeded: "Microphone access needed"
        case .downloading(let fraction): fraction.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading…"
        case .attention: "Library needs attention"
        }
    }
}

/// In-app brand glyph. The application icon is reserved for the Dock and Finder.
struct BrandMark: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "waveform.badge.mic")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let text: String
    let tone: StatusTone
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tone.color.opacity(0.12), in: Capsule())
        .foregroundStyle(tone == .neutral ? Color.secondary : Color.primary)
        .accessibilityElement(children: .combine)
    }
}

struct SectionCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, subtitle: String? = nil, systemImage: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.trailing = trailing; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            if let systemImage { Label(title, systemImage: systemImage).font(Theme.Font.sectionTitle) }
                            else { Text(title).font(Theme.Font.sectionTitle) }
                        }
                        if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: Theme.Space.m)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l).strokeBorder(Theme.cardStroke))
    }
}

/// Inline notice for states the user should act on or know about.
struct Banner<Actions: View>: View {
    let message: String
    var systemImage: String?
    var tone: StatusTone = .attention
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: systemImage ?? tone.symbol).foregroundStyle(tone.color).font(.body)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            actions
        }
        .padding(Theme.Space.m)
        .background(tone.color.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).strokeBorder(tone.color.opacity(0.22)))
    }
}
extension Banner where Actions == EmptyView {
    init(message: String, systemImage: String? = nil, tone: StatusTone = .attention) {
        self.init(message: message, systemImage: systemImage, tone: tone) { EmptyView() }
    }
}

struct DownloadProgressRow: View {
    let download: ModelDownload
    var queued = false
    var onCancel: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(download.name).font(.callout.weight(.medium))
                Spacer()
                if queued { Text("Queued").font(.caption).foregroundStyle(.secondary) }
                else if let fraction = download.fraction { Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if let onCancel {
                    Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(queued ? "Remove from queue" : "Cancel download. Verified files are kept.")
                        .accessibilityLabel(queued ? "Remove \(download.name) from queue" : "Cancel \(download.name) download")
                }
            }
            if queued { ProgressView(value: 0).opacity(0.4) }
            else if let fraction = download.fraction { ProgressView(value: fraction) }
            else { ProgressView().progressViewStyle(.linear) }
            Text(queued ? "Starts after the current download." : detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(download.name) download")
        .accessibilityValue(queued ? "Queued" : download.fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Starting")
    }
    private var detail: String {
        let total = ByteCountFormatter.string(fromByteCount: download.tally.totalBytes, countStyle: .file)
        guard download.tally.completedBytes > 0 else { return download.message }
        return "\(download.message) \(ByteCountFormatter.string(fromByteCount: download.tally.completedBytes, countStyle: .file)) of \(total)"
    }
}

/// Active and queued downloads with cancel controls.
struct DownloadQueueView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.activeDownload != nil || !model.queuedDownloads.isEmpty || !model.stagedDownloads.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let active = model.activeDownload { DownloadProgressRow(download: active) { model.cancelDownload(active.id) } }
                ForEach(model.queuedDownloads) { item in DownloadProgressRow(download: item, queued: true) { model.removeQueuedDownload(item.id) } }
                ForEach(model.stagedDownloads) { item in
                    HStack {
                        Label(model.catalog?.model(item.id)?.displayName ?? item.id, systemImage: "checkmark.circle")
                        Spacer()
                        Button("Activate") { model.activateStagedDownloads() }.disabled(!model.modelChangesAllowed)
                    }
                    Text("Downloaded. Activation waits for recording and processing to finish.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StatusRow<Actions: View>: View {
    let item: SetupReadiness.Item
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: item.state.tone.symbol).foregroundStyle(item.state.tone.color).font(.title3).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(item.title).font(.callout.weight(.semibold))
                    if item.optional { Text("Optional").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            actions
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.state.label)
    }
}
extension StatusRow where Actions == EmptyView {
    init(item: SetupReadiness.Item) { self.init(item: item) { EmptyView() } }
}

enum SystemSettings {
    static func openMicrophonePrivacy() { open("Privacy_Microphone") }
    /// System Audio Recording lives inside the Screen & System Audio Recording pane.
    static func openAudioCapturePrivacy() { open("Privacy_ScreenCapture") }
    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) }
    }
}

/// A permission status with the only actions that make sense for its state.
struct PermissionRow: View {
    @EnvironmentObject private var model: AppModel
    let kind: SetupReadiness.Kind
    var body: some View {
        if let item = model.readiness.item(kind) {
            StatusRow(item: item) {
                if kind == .microphone {
                    switch model.microphonePermission {
                    case .notDetermined: Button("Allow Access") { Task { await model.requestMicrophoneAccess() } }
                    case .denied: Button("Open System Settings") { SystemSettings.openMicrophonePrivacy() }
                    case .granted: EmptyView()
                    }
                } else if kind == .meetingAudio, model.meetingAudioPermission == .denied {
                    Button("Open System Settings") { SystemSettings.openAudioCapturePrivacy() }
                }
            }
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: { actions }
    }
}
extension EmptyStateView where Actions == EmptyView {
    init(title: String, systemImage: String, message: String) { self.init(title: title, systemImage: systemImage, message: message) { EmptyView() } }
}

struct StepIndicator: View {
    let steps: [String]
    let current: Int
    var onSelect: ((Int) -> Void)? = nil
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                Button {
                    if index < current, let onSelect { onSelect(index) }
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(index == current ? Theme.accent : index < current ? Theme.accent.opacity(0.85) : Color.primary.opacity(0.08))
                                .frame(width: 22, height: 22)
                            if index < current {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(index == current ? .white : .secondary)
                            }
                        }
                        if index == current {
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(index > current)
                if index < steps.count - 1 {
                    Capsule()
                        .fill(index < current ? Theme.accent : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: 24)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps.count), \(steps[current])")
    }
}

struct LevelMeter: View {
    let name: String
    let level: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(name).font(.caption).foregroundStyle(.secondary)
                if level > 0.01 {
                    Circle().fill(meterColor).frame(width: 5, height: 5)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: max(2, geometry.size.width * CGFloat(min(1, sqrt(max(0, level)) * 2))))
                }
            }
            .frame(width: 120, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) level")
        .accessibilityValue(level > 0.005 ? "Audio detected" : "Quiet")
    }
    private var meterColor: Color {
        if level > 0.85 { return .orange }
        if level > 0.15 { return .green }
        return Theme.accent
    }
}

extension ModelRole {
    var title: String { switch self { case .speech: "Speech recognition"; case .notes: "Meeting notes"; case .speakers: "Speaker grouping" } }
    var shortTitle: String { switch self { case .speech: "Speech"; case .notes: "Notes"; case .speakers: "Speakers" } }
    var symbol: String { switch self { case .speech: "waveform"; case .notes: "note.text"; case .speakers: "person.2" } }
    var purpose: String {
        switch self {
        case .speech: "Turns recorded audio into text."
        case .notes: "Creates summaries, decisions, and action items."
        case .speakers: "Groups voices after recording. Labels do not verify identity."
        }
    }
}
