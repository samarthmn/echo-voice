import SwiftUI
import EchoCore

/// Every setup item with the next action for its state.
struct SetupChecklistView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var showsDownloads = true
    var body: some View {
        let readiness = model.readiness
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(readiness.items) { item in
                switch item.kind {
                case .microphone, .meetingAudio: PermissionRow(kind: item.kind)
                default: StatusRow(item: item) { action(for: item) }
                }
                if item.kind != readiness.items.last?.kind { Divider() }
            }
            if showsDownloads, model.activeDownload != nil || !model.queuedDownloads.isEmpty || !model.stagedDownloads.isEmpty {
                Divider()
                DownloadQueueView()
            }
        }
    }

    @ViewBuilder private func action(for item: SetupReadiness.Item) -> some View {
        switch (item.kind, item.state) {
        case (.runtime, .actionNeeded):
            Button("Install") { model.installRuntime() }.disabled(!model.modelChangesAllowed)
        case (.runtime, .problem):
            Button("Check Again") { Task { await model.refreshHealth() } }
        case (.speech, .actionNeeded):
            Button("Download") { model.enqueueDownload(model.defaultModel(.speech), makeDefault: true) }
                .disabled(model.health == nil || model.libraryPhase != .ready)
        case (.notes, .actionNeeded), (.speakers, .actionNeeded):
            Button("Settings…") { openModels(item.kind == .notes ? .notes : .speakers) }
        case (.speech, .inProgress), (.notes, .inProgress), (.speakers, .inProgress):
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func openModels(_ role: ModelRole) {
        model.settingsPage = .models; model.settingsModelRole = role; openSettings()
    }
}

/// Compact overall status; opens the checklist.
struct SetupStatusPill: View {
    @EnvironmentObject private var model: AppModel
    @State private var showDetails = false
    var body: some View {
        let overall = model.readiness.overall
        Button { showDetails.toggle() } label: {
            HStack(spacing: Theme.Space.s) {
                ZStack {
                    Circle().fill(overall.tone.color.opacity(0.2)).frame(width: 16, height: 16)
                    Circle().fill(overall.tone.color).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.newMeetingBlockedReason == nil ? "Ready to record" : overall.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(subtitle(overall)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Setup and permission status")
        .accessibilityLabel("Setup status: \(overall.title)")
        .accessibilityHint("Shows setup steps and permissions")
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack {
                    Text("Setup & permissions").font(.headline)
                    Spacer()
                    StatusBadge(text: overall.title, tone: overall.tone)
                }
                SetupChecklistView()
                Divider()
                HStack {
                    Label("Everything runs on this Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Setup Guide") { showDetails = false; model.presentSetupGuide() }
                        .disabled(!model.canPresentSetupGuide)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 440)
        }
    }

    private func subtitle(_ overall: SetupReadiness.Overall) -> String {
        switch overall {
        case .ready: "Local only · models ready"
        case .checking: "Local only"
        case .setupRequired: "Transcription needs setup"
        case .permissionNeeded: model.microphonePermission == .denied ? "Denied in System Settings" : "Not yet allowed"
        case .downloading: model.activeDownload?.name ?? "Model download"
        case .attention: "Open for details"
        }
    }
}
