import SwiftUI
import MirrorCore

/// The "What's Included" pane. A List, so a set with hundreds of rules only builds the rows on screen.
struct IncludedPane: View {
    @Binding var draft: BackupSet
    let presets: [Preset]
    let presetBinding: (String) -> Binding<Bool>
    let requestPreview: (Double) -> Void
    let excludeItems: () -> Void

    @State private var query = ""
    @FocusState private var focusedRule: UUID?
    /// A rule just added: scrolled to and focused once its row exists.
    @State private var pendingFocus: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Toggle(isOn: .constant(true)) { Text("macOS (.DS_Store, .Trash)") }
                        .disabled(true)
                    ForEach(presets) { preset in
                        Toggle(preset.name, isOn: presetBinding(preset.id))
                    }
                } header: {
                    Text("Stacks")
                } footer: {
                    Text("Build folders and caches for these stacks are skipped. When unsure, Mirror backs a file up.")
                }

                Section {
                    Toggle("Back up secrets", isOn: $draft.backupSecrets)
                    Toggle("Back up Git history", isOn: $draft.backupGit)
                } header: {
                    Text("Secrets and Git")
                } footer: {
                    Text("Secrets are .env files and private keys. Git history adds the .git folders, which can be large.")
                }

                Section {
                    // Ids, not filtered indices: each row binds to its real rule, and stored order is kept.
                    ForEach(RuleFilter.visibleIDs(draft.rules, query: query, keep: focusedRule.map { [$0] } ?? []), id: \.self) { id in
                        row(id)
                    }
                } header: {
                    rulesHeader
                } footer: {
                    Text("Your rules come before stacks. With Secrets or Git history off, those files stay out whatever your rules say. Press Return after typing a pattern to preview the effect. A folder's pattern ends in /**.")
                }
            }
            .onChange(of: pendingFocus) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    proxy.scrollTo(id, anchor: .center)
                    try? await Task.sleep(for: .milliseconds(120))
                    focusedRule = id
                    pendingFocus = nil
                }
            }
        }
    }

    /// Add Rule and Exclude stay above the rows; the header floats while the rows scroll.
    private var rulesHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Rules")
                Text(RuleFilter.countText(total: draft.rules.count,
                                          shown: RuleFilter.visibleIDs(draft.rules, query: query, keep: focusedRule.map { [$0] } ?? []).count))
                    .foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                Button("Exclude File or Folder…") { excludeItems() }
                    .accessibilityHint("Pick items in this set to leave out of the backup")
                Button("Add Rule") {
                    let rule = UserRule(pattern: "", action: .exclude)
                    draft.rules.append(rule)
                    pendingFocus = rule.id
                }
                .accessibilityHint("Adds an empty rule at the end and moves to it")
            }
            if RuleFilter.offersFilter(ruleCount: draft.rules.count) {
                TextField("Filter", text: $query, prompt: Text("Filter rules"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .accessibilityLabel("Filter rules")
                    .accessibilityHint("Shows only rules whose pattern contains this text. The order doesn't change.")
            }
        }
    }

    @ViewBuilder private func row(_ id: UUID) -> some View {
        let rule = ruleBinding(id)
        HStack {
            Picker("Action", selection: rule.action) {
                Text("Include").tag(UserRule.Action.include)
                Text("Exclude").tag(UserRule.Action.exclude)
            }
            .labelsHidden().frame(width: 100)
            .onChange(of: rule.wrappedValue.action) { if !rule.wrappedValue.pattern.isEmpty { requestPreview(0.8) } }
            TextField("Pattern", text: rule.pattern, prompt: Text("For example *.log or /Drafts/**"))
                .labelsHidden()
                .focused($focusedRule, equals: id)
                .onSubmit { requestPreview(0) }
            Button(role: .destructive) { draft.rules.removeAll { $0.id == id }; requestPreview(0.8) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete rule \(rule.wrappedValue.pattern)")
        }
        .id(id)
    }

    /// Looks the rule up by id at each read and write, so a removed or reordered rule can't redirect an edit.
    private func ruleBinding(_ id: UUID) -> Binding<UserRule> {
        Binding(get: { draft.rules.first { $0.id == id } ?? UserRule(id: id, pattern: "", action: .exclude) },
                set: { new in if let i = draft.rules.firstIndex(where: { $0.id == id }) { draft.rules[i] = new } })
    }
}
