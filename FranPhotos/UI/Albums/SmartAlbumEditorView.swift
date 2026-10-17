import SwiftUI

/// Smart album editor: name + match mode + condition rows.
struct SmartAlbumEditorView: View {
    var onSave: (String, SmartRuleSet) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rules = SmartRuleSet()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Smart Album").font(.headline)
            TextField(String(localized: "Album Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Match")
                Picker("", selection: $rules.match) {
                    ForEach(SmartRuleSet.Match.allCases, id: \.self) { match in
                        Text(match.localizedName).tag(match)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                Text("of the following conditions:").foregroundStyle(.secondary)
            }

            ForEach($rules.conditions) { $condition in
                ConditionRow(condition: $condition) {
                    rules.conditions.removeAll { $0.id == condition.id }
                }
            }

            Button {
                rules.conditions.append(.init(
                    field: .mediaType, op: .isEqual, value: "photo"))
            } label: {
                Label(String(localized: "Add Condition"), systemImage: "plus")
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Create")) {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    Task {
                        await onSave(trimmed.isEmpty ? String(localized: "Smart Album") : trimmed,
                                     rules)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(rules.conditions.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct ConditionRow: View {
    @Binding var condition: SmartRuleSet.Condition
    var onDelete: () -> Void

    var body: some View {
        HStack {
            Picker("", selection: $condition.field) {
                ForEach(SmartRuleSet.Condition.Field.allCases, id: \.self) { field in
                    Text(field.localizedName).tag(field)
                }
            }
            .frame(width: 150)
            .onChange(of: condition.field) { _, field in
                condition.op = SmartRuleSet.Condition.ops(for: field).first ?? .isEqual
                condition.value = SmartRuleSet.Condition.valueOptions(for: field)?.first ?? ""
            }
            Picker("", selection: $condition.op) {
                ForEach(SmartRuleSet.Condition.ops(for: condition.field), id: \.self) { op in
                    Text(op.localizedName).tag(op)
                }
            }
            .frame(width: 110)
            if let options = SmartRuleSet.Condition.valueOptions(for: condition.field) {
                Picker("", selection: $condition.value) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 110)
            } else if condition.field != .hasLocation {
                TextField(String(localized: "Value"), text: $condition.value)
                    .textFieldStyle(.roundedBorder)
            }
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
    }
}
