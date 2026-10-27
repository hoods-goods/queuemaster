import SwiftUI
import CupsKit

/// Per-roll setup for multi-roll label printers (DYMO Twin Turbo).
/// Each roll can get its own printer so Chrome and other apps can pick
/// "DYMO Inventory" or "DYMO Notes" by name.
struct RollsView: View {
    @Environment(AppModel.self) private var model
    let printer: Printer

    @State private var options: PrinterOptions?
    @State private var queues: [RollQueue] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if loading && options == nil {
                ProgressView("Reading rolls…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let options, !options.rollSlots.isEmpty {
                Form {
                    Section {
                        Text("Tell QueueMaster what's loaded on each side. Each roll can have its own printer, set to that side and label size, so Chrome and other apps just pick the printer by name.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let mine = queues.first(where: { $0.isSelf }),
                           let slot = options.rollSlots.first(where: { mine.mentions($0) }) {
                            Label("This is the \(slot.label.lowercased()) printer and it isn't locked yet. Click Save on its card below to lock it.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    ForEach(options.rollSlots) { slot in
                        RollCard(base: printer, options: options, slot: slot,
                                 existing: CupsClient.matchRollQueue(slot, allSlots: options.rollSlots, in: queues),
                                 onSaved: { Task { await load() } })
                    }
                    if !otherSiblings(options).isEmpty {
                        Section("Other printers on this device") {
                            ForEach(otherSiblings(options)) { q in
                                LabeledContent(q.info.isEmpty ? q.name : q.info) {
                                    Text("\(q.name) · roll: \(q.slot ?? "?")").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Printing from Chrome") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. In Chrome's print dialog, open Destination → See more… and pick the roll printer (e.g. \(sampleName(options))).")
                            Text("2. Under More settings, set Margins to None and Scale to Default (or Fit to printable area) so the page fits the label.")
                            Text("3. Chrome reuses the last printer you picked, so switching between rolls is a single change in the Destination list.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else if let locked = options?.lockedRoll {
                ContentUnavailableView("Locked to the \(locked.lowercased()) roll", systemImage: "lock.fill",
                                       description: Text("This printer always prints on the \(locked.lowercased()) roll, whatever other apps ask for. Manage the rolls from the main Twin Turbo printer."))
            } else {
                ContentUnavailableView("Single-roll printer", systemImage: "tag",
                                       description: Text(loadError ?? "This printer's driver doesn't offer a choice of rolls."))
            }
        }
        .task(id: printer.name) { await load() }
    }

    private func otherSiblings(_ options: PrinterOptions) -> [RollQueue] {
        let matched = Set(options.rollSlots.compactMap { CupsClient.matchRollQueue($0, allSlots: options.rollSlots, in: queues)?.name })
        return queues.filter { !$0.isSelf && !matched.contains($0.name) }
    }

    private func sampleName(_ options: PrinterOptions) -> String {
        options.rollSlots.lazy.compactMap { CupsClient.matchRollQueue($0, allSlots: options.rollSlots, in: queues)?.info }.first
            ?? "DYMO Inventory"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            options = try await model.cups.options(for: printer.name)
            queues = await model.cups.rollQueues(for: printer, in: model.printers)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct RollCard: View {
    @Environment(AppModel.self) private var model
    let base: Printer
    let options: PrinterOptions
    let slot: RollSlot
    let existing: RollQueue?
    let onSaved: () -> Void

    @State private var labelName = ""
    @State private var pageSize = ""
    @State private var queueName = ""
    @State private var info = ""
    @State private var nameEdited = false
    @State private var infoEdited = false
    @State private var message: String?

    private var storeKey: String { "roll.\(base.deviceURI).\(slot.keyword).label" }

    private var cleanName: String { CupsClient.sanitizeQueueName(queueName) }

    private var nameClash: Bool {
        existing == nil && model.printers.contains { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }
    }

    var body: some View {
        Section {
            TextField("What's loaded", text: $labelName, prompt: Text("Inventory labels"))
                .onChange(of: labelName) { _, new in
                    UserDefaults.standard.set(new, forKey: storeKey)
                    if existing == nil && !nameEdited {
                        queueName = CupsClient.suggestedRollQueueName(base: base, labelName: new, slot: slot)
                    }
                    if !infoEdited { info = defaultInfo(new) }
                }
            if let ps = options.pageSizeOption {
                Picker("Label size", selection: $pageSize) {
                    Text("Driver default").tag("")
                    ForEach(ps.choices) { c in
                        Text(c.label == c.keyword ? c.keyword : "\(c.label)  (\(c.keyword))").tag(c.keyword)
                    }
                    if !pageSize.isEmpty && !ps.choices.contains(where: { $0.keyword == pageSize }) {
                        Text(pageSize).tag(pageSize)
                    }
                }
            }
            TextField("Name in print dialogs", text: Binding(get: { info }, set: { info = $0; infoEdited = true }),
                      prompt: Text("DYMO Inventory (Left)"))
            if let existing {
                LabeledContent("Printer") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(existing.name).font(.body.monospaced())
                    }
                }
                if existing.locked {
                    Label("Locked to the \(slot.label.lowercased()): other apps, including DYMO Connect, can't switch it.",
                          systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Not locked: an app that picks a roll itself (DYMO Connect does) can switch this printer to the other side. Click Save to lock it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                TextField("Queue name", text: Binding(get: { queueName }, set: { queueName = $0; nameEdited = true }))
                    .font(.body.monospaced())
                if nameClash {
                    Text("A printer named \(cleanName) already exists.").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let existing {
                    Button("Print Test") { test(existing.name) }
                    if model.printer(named: existing.name)?.isDefault == false {
                        Button("Make Default") {
                            Task { await model.perform("Setting default") { try await model.cups.makeDefault(existing.name) } }
                        }
                    }
                }
                Button(existing == nil ? "Create Printer" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanName.isEmpty || nameClash || info.isEmpty)
            }
        } header: {
            HStack {
                Image(systemName: slot.keyword.lowercased().contains("left") ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                Text(slot.label)
            }
        } footer: {
            Text(Shell.quote(["lpadmin"] + CupsClient.rollOptionArguments(existing?.name ?? cleanName, info: info,
                                                                          slot: slot.keyword, pageSize: pageSize.isEmpty ? nil : pageSize)))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .onAppear(perform: prefill)
        .onChange(of: existing) { _, _ in prefill() }
    }

    private func defaultInfo(_ label: String) -> String {
        let brand = base.makeAndModel.split(separator: " ").first.map(String.init) ?? "Printer"
        return "\(brand) \(label.isEmpty ? slot.label : label) (\(slot.label))"
    }

    private func prefill() {
        labelName = UserDefaults.standard.string(forKey: storeKey) ?? ""
        if let existing {
            queueName = existing.name
            info = existing.info
            pageSize = existing.pageSize ?? ""
            infoEdited = true
            if labelName.isEmpty { labelName = existing.info }
        } else {
            queueName = CupsClient.suggestedRollQueueName(base: base, labelName: labelName, slot: slot)
            info = defaultInfo(labelName)
            pageSize = options.queueDefault("PageSize") ?? ""
        }
    }

    private func save() async {
        let name = existing?.name ?? cleanName
        let ok = await model.perform(existing == nil ? "Creating \(name)" : "Saving \(name)") {
            try await model.cups.configureRollQueue(base: base, baseOptions: options, queue: name, info: info,
                                                    slot: slot.keyword, pageSize: pageSize.isEmpty ? nil : pageSize,
                                                    exists: existing != nil)
        }
        if ok {
            message = existing == nil ? "Created \(name)." : "Saved."
            onSaved()
        }
    }

    private func test(_ queue: String) {
        Task {
            do {
                let text = "\(labelName.isEmpty ? slot.label : labelName)\n\(slot.label) · \(queue)\n"
                _ = try await model.cups.printText(text, to: queue)
                message = "Test sent to \(queue)."
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
