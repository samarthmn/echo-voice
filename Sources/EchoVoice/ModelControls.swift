import SwiftUI
import EchoCore

extension ModelDescriptor {
    var summary: String {
        switch id {
        case "parakeet": "English. Smaller download; some word timing is approximate."
        case "asr": "Uses vocabulary spelling hints. Larger download."
        case "notes": "Compact notes model with the lowest memory use."
        case "gemma": "Mid-size notes model."
        case "gptoss": "Largest notes model. Needs the most memory."
        default: gated ? "Requires accepted access conditions and a Hugging Face token." : ""
        }
    }
}

/// Selectable cards for every native model in a role, with live readiness.
struct ModelOptionCards: View {
    @EnvironmentObject private var model: AppModel
    let role: ModelRole
    @Binding var selection: String
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(model.catalog?.models(for: role) ?? []) { entry in
                Button { selection = entry.id } label: { card(entry) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == entry.id ? .isSelected : [])
            }
        }
    }
    private func card(_ entry: ModelDescriptor) -> some View {
        let selected = selection == entry.id
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.accent : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Space.s) {
                    Text(entry.displayName).font(.callout.weight(.semibold))
                    if model.defaultModel(role) == entry.id && model.isModelReady(entry.id) { StatusBadge(text: "Default", tone: .progress) }
                }
                if !entry.summary.isEmpty { Text(entry.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("\(ByteCountFormatter.string(fromByteCount: model.catalog?.downloadBytes(includingDependenciesOf: entry.id) ?? entry.download_bytes, countStyle: .file)) download · about \(ByteCountFormatter.string(fromByteCount: entry.estimated_memory_bytes, countStyle: .memory)) memory")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: Theme.Space.s)
            stateBadge(entry)
        }
        .padding(Theme.Space.m)
        .contentShape(Rectangle())
        .background(selected ? Theme.accent.opacity(0.08) : Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.cardStroke))
    }
    @ViewBuilder private func stateBadge(_ entry: ModelDescriptor) -> some View {
        if let download = model.download(for: entry.id) {
            StatusBadge(text: model.activeDownload?.id == entry.id ? download.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Starting" : "Queued", tone: .progress)
        } else if model.isModelReady(entry.id) {
            StatusBadge(text: "Ready", tone: .ready)
        } else if model.health == nil {
            StatusBadge(text: model.setupBusy ? "Runtime installing…" : "Runtime needed", tone: model.setupBusy ? .progress : .attention)
        } else {
            StatusBadge(text: "Not downloaded", tone: .neutral)
        }
    }
}

/// Download, default and maintenance actions for one native model.
struct ModelActions: View {
    @EnvironmentObject private var model: AppModel
    let entry: ModelDescriptor
    var alwaysMakeDefault = false
    var showsMaintenance = false
    var onRemove: (() -> Void)?
    @State private var token = ""
    @State private var acceptedTerms = false
    @State private var rememberToken = false

    private var ready: Bool { model.isModelReady(entry.id) }
    private var isDefault: Bool {
        guard model.defaultModel(entry.role) == entry.id else { return false }
        return entry.role != .notes || model.defaultNotesSelection()?.provider == .native
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let download = model.download(for: entry.id) {
                DownloadProgressRow(download: download, queued: model.activeDownload?.id != entry.id) { model.cancelDownload(entry.id) }
            } else if model.stagedDownloads.contains(where: { $0.id == entry.id }) {
                Label("Downloaded · waiting to activate", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Activate") { model.activateStagedDownloads() }.disabled(!model.modelChangesAllowed)
            } else {
                if entry.gated && !ready { gatedFields }
                if model.health == nil && !ready {
                    if model.setupBusy && model.activeDownload == nil {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Setting up local runtime (\(model.setupProgress))… Downloads unlock automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label(model.runtimeChecked ? "The local speech runtime must be installed before downloading models." : "Checking the local runtime…", systemImage: "desktopcomputer")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    if !ready {
                        if model.health == nil {
                            if model.setupBusy && model.activeDownload == nil {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Waiting for Runtime…")
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                                .foregroundStyle(.secondary)
                            } else {
                                Button("Install Runtime First") { model.installRuntime() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!model.modelChangesAllowed)
                            }
                        } else {
                            Button("Download") { startDownload() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.libraryPhase != .ready || (entry.gated && (!acceptedTerms || token.isEmpty)))
                        }
                    } else if !isDefault {
                        Button("Use as Default") { model.setDefaultModel(entry.id, role: entry.role) }.buttonStyle(.borderedProminent)
                    } else {
                        Label("Default for new meetings", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    }
                    Spacer()
                    if showsMaintenance && ready {
                        Button("Verify / Repair") { model.enqueueDownload(entry.id) }.disabled(model.health == nil)
                        if let onRemove { Button("Remove…", role: .destructive, action: onRemove).disabled(!model.modelChangesAllowed) }
                    }
                }
                if model.setupBusy && model.activeDownload == nil && !ready && model.health != nil {
                    Text("Downloads start when the current setup task finishes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var gatedFields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let terms = URL(string: "https://huggingface.co/" + entry.repo) { Link("Review model access conditions", destination: terms).font(.callout) }
            Toggle("I have accepted the required access conditions", isOn: $acceptedTerms)
            HStack {
                SecureField("Hugging Face read token", text: $token).textFieldStyle(.roundedBorder)
                Button("Use Saved Token") { Task { let saved = await Task.detached { KeychainToken.read() }.value; if let saved { token = saved; rememberToken = true } } }
            }
            Toggle("Remember token in Keychain", isOn: $rememberToken)
        }
        .padding(Theme.Space.m)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
    }

    private func startDownload() {
        if rememberToken && !token.isEmpty {
            let credential = token
            Task {
                let saved = await Task.detached { KeychainToken.save(credential) }.value
                if !saved { model.error = "The token could not be saved to the Keychain. The download continues with the token you entered." }
            }
        }
        // Replace only a default that cannot run yet; a role the user turned off stays off.
        let current = model.defaultModel(entry.role)
        let replaceDefault = !current.isEmpty && !model.isModelReady(current) && (entry.role != .notes || model.defaultNotesSelection()?.provider == .native)
        model.enqueueDownload(entry.id, token: token.isEmpty ? nil : token, makeDefault: alwaysMakeDefault || replaceDefault)
        token = ""
    }
}
