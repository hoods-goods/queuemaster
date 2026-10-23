import SwiftUI
import CupsKit

enum OptionScope: String, CaseIterable, Identifiable {
    case queue = "Queue defaults (everyone)"
    case user = "My defaults only"
    var id: String { rawValue }
}

struct OptionsView: View {
    @Environment(AppModel.self) private var model
    let printerName: String

    @State private var options: PrinterOptions?
    @State private var loadError: String?
    @State private var loading = false
    @State private var scope: OptionScope = .queue
    @State private var edits: [String: String] = [:]
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Change", selection: $scope) {
                    ForEach(OptionScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                .disabled(!edits.isEmpty)
                .help(edits.isEmpty ? "" : "Save or revert your changes first")
                TextField("Search options", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if let src = options?.source {
                    Text("From \(src)").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload options")
            }
            .padding(10)

            Text(scope == .queue
                 ? "Queue defaults are stored in the printer's PPD and apply to every app and user on this Mac (lpadmin -o)."
                 : "Your defaults are saved for your Mac account only (~/.cups/lpoptions) and win over the queue defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()

            if loading && options == nil {
                ProgressView("Reading printer options…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let options {
                Form {
                    ForEach(filtered(options.groups)) { group in
                        Section(group.label) {
                            ForEach(group.options) { opt in
                                OptionRow(option: opt,
                                          value: binding(for: opt),
                                          edited: edits[opt.key] != nil,
                                          scope: scope,
                                          clearUser: { clearUser(opt) })
                            }
                        }
                    }
                    if filtered(options.groups).isEmpty {
                        Text(search.isEmpty ? "This printer has no adjustable options." : "No options match \"\(search)\".")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Couldn't read options", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError ?? ""))
            }

            if !edits.isEmpty {
                Divider()
                saveBar
            }
        }
        .task(id: printerName) { await load() }
    }

    private var saveBar: some View {
        let args = CupsClient.setOptionArguments(printerName, edits)
        let tool = scope == .queue ? "lpadmin" : "lpoptions"
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(edits.count) unsaved change\(edits.count == 1 ? "" : "s")").font(.callout.weight(.medium))
                Text(Shell.quote([tool] + args))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Revert") { edits = [:] }
            Button("Save") { Task { await save() } }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.bar)
    }

    private func filtered(_ groups: [OptionGroup]) -> [OptionGroup] {
        guard !search.isEmpty else { return groups }
        return groups.compactMap { g in
            let opts = g.options.filter {
                $0.label.localizedCaseInsensitiveContains(search) || $0.key.localizedCaseInsensitiveContains(search)
            }
            return opts.isEmpty ? nil : OptionGroup(name: g.name, label: g.label, options: opts)
        }
    }

    private func baseValue(_ o: PrinterOption) -> String? {
        scope == .queue ? (o.queueDefault ?? o.current) : o.current
    }

    private func binding(for o: PrinterOption) -> Binding<String> {
        Binding(
            get: { edits[o.key] ?? baseValue(o) ?? "" },
            set: { new in
                if new == baseValue(o) { edits[o.key] = nil } else { edits[o.key] = new }
            })
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            options = try await model.cups.options(for: printerName)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        let values = edits
        let ok = await model.perform("Saving options") {
            if scope == .queue { try await model.cups.setQueueDefaults(printerName, values) }
            else { try await model.cups.setUserDefaults(printerName, values) }
        }
        if ok {
            edits = [:]
            await load()
        }
    }

    private func clearUser(_ o: PrinterOption) {
        Task {
            await model.perform("Clearing override") { try await model.cups.clearUserDefault(printerName, key: o.key) }
            edits[o.key] = nil
            await load()
        }
    }
}

struct OptionRow: View {
    let option: PrinterOption
    @Binding var value: String
    let edited: Bool
    let scope: OptionScope
    let clearUser: () -> Void

    private static let customTag = "__custom__"

    private var pickerSelection: Binding<String> {
        Binding(
            get: { value.hasPrefix("Custom.") ? Self.customTag : value },
            set: { new in
                if new == Self.customTag {
                    if !value.hasPrefix("Custom.") { value = "Custom.4x6in" }
                } else { value = new }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if option.type == .boolean {
                    Toggle(isOn: Binding(get: { value == "True" }, set: { value = $0 ? "True" : "False" })) { title }
                } else {
                    Picker(selection: pickerSelection) {
                        ForEach(option.choices) { c in Text(c.label).tag(c.keyword) }
                        if !value.isEmpty, !value.hasPrefix("Custom."), !option.choices.contains(where: { $0.keyword == value }) {
                            Text(value).tag(value)
                        }
                        if option.supportsCustom {
                            Divider()
                            Text("Custom size…").tag(Self.customTag)
                        }
                    } label: { title }
                }
            }
            if value.hasPrefix("Custom.") {
                CustomSizeEditor(value: $value)
            }
            notes
        }
        .padding(.vertical, 2)
    }

    private var title: some View {
        HStack(spacing: 6) {
            if edited { Circle().fill(.tint).frame(width: 6, height: 6).help("Changed, not saved yet") }
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                Text(option.key).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let user = option.userValue {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                if scope == .queue {
                    Text("Your account overrides this with \(option.label(for: user)).")
                } else {
                    Text("Set for your account. Queue default: \(option.label(for: option.queueDefault)).")
                }
                Button("Use queue default", action: clearUser).buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Edits a CUPS custom size value such as "Custom.4x6in".
struct CustomSizeEditor: View {
    @Binding var value: String
    static let units = ["in", "mm", "cm", "pt"]

    private var parts: (w: String, h: String, unit: String) {
        var size = String(value.dropFirst("Custom.".count))
        var unit = "pt"
        for u in Self.units where size.hasSuffix(u) {
            unit = u
            size.removeLast(u.count)
            break
        }
        let wh = size.split(separator: "x", maxSplits: 1).map(String.init)
        return (wh.first ?? "", wh.count > 1 ? wh[1] : "", unit)
    }

    private func update(w: String? = nil, h: String? = nil, unit: String? = nil) {
        let p = parts
        value = "Custom.\(w ?? p.w)x\(h ?? p.h)\(unit ?? p.unit)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Width").foregroundStyle(.secondary)
            TextField("W", text: Binding(get: { parts.w }, set: { update(w: $0) }))
                .frame(width: 60)
            Text("Height").foregroundStyle(.secondary)
            TextField("H", text: Binding(get: { parts.h }, set: { update(h: $0) }))
                .frame(width: 60)
            Picker("", selection: Binding(get: { parts.unit }, set: { update(unit: $0) })) {
                ForEach(Self.units, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
    }
}
