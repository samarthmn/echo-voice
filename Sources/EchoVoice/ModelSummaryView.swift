import SwiftUI
import EchoCore

struct ModelSummaryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    let title: String
    let configuration: ProcessingConfiguration?
    var usedRoles: Set<ModelRole> = []
    var actualNotes: ModelSelection?
    var actualSpeakers: ModelSelection?
    var historical = false

    private func selection(_ role: ModelRole) -> ModelSelection? {
        switch role {
        case .speech: return configuration?.speech
        case .notes: return usedRoles.contains(.notes) ? actualNotes : configuration?.notes
        case .speakers: return usedRoles.contains(.speakers) ? actualSpeakers : configuration?.speakers
        }
    }
    private func name(_ role: ModelRole) -> String {
        guard let selection = selection(role) else { return configuration == nil || usedRoles.contains(role) ? "Not recorded" : "Off" }
        return (selection.provider == .ollama ? "Ollama · " : "") + (selection.provider == .native ? model.catalog?.model(selection.id)?.displayName ?? selection.id : selection.id)
    }
    private func readiness(_ role: ModelRole) -> (String, StatusTone)? {
        guard let selected = selection(role) else { return nil }
        if historical && usedRoles.contains(role) { return ("Used", .neutral) }
        if selected.provider == .ollama {
            if model.ollamaModels.contains(where: { $0.name == selected.id && $0.digest == selected.revision }) { return ("Ready", .ready) }
            return model.ollamaChecked ? ("Unavailable", .attention) : ("Not checked", .neutral)
        }
        if model.download(for: selected.id) != nil { return ("Downloading", .progress) }
        return model.isModelReady(selected.id) ? ("Ready", .ready) : ("Setup needed", .attention)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: Theme.Space.s) {
                ForEach(ModelRole.allCases, id: \.self) { role in
                    Button {
                        model.settingsPage = .models; model.settingsModelRole = role; openSettings()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(role.shortTitle, systemImage: role.symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(name(role)).font(.callout.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if let (text, tone) = readiness(role) {
                                StatusBadge(text: historical && !usedRoles.contains(role) ? "Selected · " + text : text, tone: tone)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading).padding(Theme.Space.m)
                            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).strokeBorder(Theme.cardStroke))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Open " + role.shortTitle.lowercased() + " model settings")
                        .accessibilityLabel("\(role.title): \(name(role))\(readiness(role).map { ", " + $0.0 } ?? "")")
                }
            }
            if historical {
                DisclosureGroup("Model details") {
                    ForEach(ModelRole.allCases, id: \.self) { role in
                        if let selected = selection(role) { Text("\(role.shortTitle): \(selected.provider.rawValue) · \(selected.id) · \(selected.revision)").font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
