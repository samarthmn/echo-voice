import SwiftUI
import UniformTypeIdentifiers
import EchoCore

struct VocabularySettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("fuzzyVocabulary") private var fuzzyVocabulary = false
    @State private var entries: [VocabularyEntry] = []
    @State private var query = ""
    @State private var editingID: String?
    @State private var spelling = ""
    @State private var aliases = ""
    @State private var important = false
    @State private var imported: [VocabularyEntry]?
    @State private var importError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Whisper receives a bounded spelling hint. Both recognizers replace your explicit ‘heard as’ aliases after recognition. Existing transcripts and your edits stay unchanged.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SectionCard("Similar-spelling corrections", systemImage: "wand.and.stars") {
                Toggle("Parakeet: try conservative similar-spelling corrections", isOn: $fuzzyVocabulary)
                Text("Optional and off by default. Explicit aliases are more predictable; short words, numbers, links, and ambiguous matches are left alone.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SectionCard("Your vocabulary", systemImage: "character.book.closed", trailing: AnyView(StatusBadge(text: "\(entries.filter(\.enabled).count) enabled", tone: .neutral))) {
                HStack {
                    TextField("Search vocabulary", text: $query).textFieldStyle(.roundedBorder)
                    Button("Import CSV…") { importCSV() }
                    Button("Export CSV…") { exportCSV() }.disabled(entries.isEmpty)
                }
                let visible = entries.filter { query.isEmpty || $0.spelling.localizedCaseInsensitiveContains(query) || $0.aliases.joined(separator: " ").localizedCaseInsensitiveContains(query) }
                if entries.isEmpty {
                    Text("No words yet. Add names, product terms, or acronyms your meetings use.").font(.callout).foregroundStyle(.secondary).padding(.vertical, Theme.Space.s)
                } else if visible.isEmpty {
                    Text("No entries match “\(query)”.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(visible) { entry in
                    HStack {
                        Toggle("Use " + entry.spelling, isOn: Binding(get: { entries.first { $0.id == entry.id }?.enabled ?? false }, set: { value in update(entry.id) { $0.enabled = value } })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Use " + entry.spelling)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(entry.spelling).font(.callout.weight(.medium)); if entry.important { StatusBadge(text: "Priority", tone: .progress) } }
                            if !entry.aliases.isEmpty { Text("Heard as: " + entry.aliases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Edit") { editingID = entry.id; spelling = entry.spelling; aliases = entry.aliases.joined(separator: "\n"); important = entry.important }
                        Button { entries.removeAll { $0.id == entry.id }; save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove " + entry.spelling)
                    }.padding(.vertical, 2)
                    if entry.id != visible.last?.id { Divider() }
                }
            }
            SectionCard(editingID == nil ? "Add a word or phrase" : "Edit vocabulary", systemImage: editingID == nil ? "plus.circle" : "pencil") {
                TextField("Preferred spelling", text: $spelling).textFieldStyle(.roundedBorder)
                TextField("Heard as aliases (one per line)", text: $aliases, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                Toggle("Prioritize in Whisper’s vocabulary hint", isOn: $important)
                HStack {
                    Spacer()
                    if editingID != nil { Button("Cancel") { editingID = nil; spelling = ""; aliases = ""; important = false } }
                    Button(editingID == nil ? "Add" : "Save") {
                        let entry = VocabularyEntry(id: editingID ?? UUID().uuidString, spelling: spelling, aliases: aliases.split(separator: "\n").map(String.init), important: important)
                        var proposed = entries.filter { $0.id != entry.id }; proposed.append(entry)
                        do { entries = try VocabularyEntry.validated(proposed); save(); editingID = nil; spelling = ""; aliases = ""; important = false } catch { model.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.onAppear { entries = (try? model.store?.vocabulary()) ?? [] }
        .sheet(isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import vocabulary").font(.title2)
                Text("\(imported?.count ?? 0) entries will be added. Existing vocabulary is preserved.")
                if let importError { Text(importError).foregroundStyle(.orange) }
                HStack { Button("Cancel") { imported = nil }; Spacer(); Button("Import") { if let imported { entries += imported; save() }; imported = nil }.disabled(importError != nil) }
            }.padding(24).frame(width: 440)
        }
    }
    private func update(_ id: String, change: (inout VocabularyEntry) -> Void) { guard let index = entries.firstIndex(where: { $0.id == id }) else { return }; change(&entries[index]); save() }
    private func save() { do { try model.store?.saveVocabulary(entries) } catch { model.error = error.localizedDescription; entries = (try? model.store?.vocabulary()) ?? [] } }
    private func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let incoming = try VocabularyCSV.parse(String(contentsOf: url, encoding: .utf8)); imported = incoming; importError = nil; do { _ = try VocabularyEntry.validated(entries + incoming) } catch { importError = "Resolve conflicting spellings or aliases in the CSV, then import again. " + error.localizedDescription } } catch { model.error = error.localizedDescription }
    }
    private func exportCSV() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Echo Voice vocabulary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try VocabularyCSV.export(entries).write(to: url, atomically: true, encoding: .utf8) } catch { model.error = error.localizedDescription }
    }
}
