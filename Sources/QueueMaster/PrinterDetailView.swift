import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CupsKit

enum PrinterTab: String, CaseIterable, Identifiable {
    case jobs = "Queue"
    case options = "Options"
    case rolls = "Rolls"
    case settings = "Settings"
    case attributes = "Attributes"
    var id: String { rawValue }
}

struct PrinterDetailView: View {
    @Environment(AppModel.self) private var model
    let printerName: String

    @State private var tab: PrinterTab = .jobs
    @State private var askPauseReason = false
    @State private var askRejectReason = false
    @State private var reason = ""
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var showTextPrint = false
    @State private var info: String?
    /// The driver offers more than one roll (DYMO Twin Turbo).
    @State private var hasRolls = false

    private var printer: Printer? { model.printer(named: printerName) }

    var body: some View {
        if let p = printer {
            VStack(spacing: 0) {
                header(p)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                Picker("", selection: $tab) {
                    ForEach(PrinterTab.allCases.filter { $0 != .rolls || hasRolls }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .padding(.bottom, 10)
                Divider()
                switch tab {
                case .jobs: JobsView(printerName: p.name)
                case .options: OptionsView(printerName: p.name)
                case .rolls: RollsView(printer: p)
                case .settings: PrinterSettingsView(printer: p)
                case .attributes: AttributesView(printer: p)
                }
            }
            .navigationTitle(p.displayName)
            .navigationSubtitle(p.name)
            .task(id: p.name) {
                let opts = try? await model.cups.options(for: p.name)
                hasRolls = !(opts?.rollSlots.isEmpty ?? true)
                if !hasRolls && tab == .rolls { tab = .jobs }
            }
            .alert("Pause \(p.displayName)", isPresented: $askPauseReason) {
                TextField("Reason (optional)", text: $reason)
                Button("Pause") { run("Pausing") { try await model.cups.pause(p.name, reason: reason) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Jobs stay in the queue until you resume. The reason shows next to the printer, e.g. \"Out of labels\".")
            }
            .alert("Stop accepting jobs", isPresented: $askRejectReason) {
                TextField("Reason (optional)", text: $reason)
                Button("Reject Jobs") { run("Updating") { try await model.cups.setAccepting(p.name, false, reason: reason) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New print jobs will be refused until you accept jobs again. Jobs already queued still print.")
            }
            .confirmationDialog("Delete \(p.displayName)?", isPresented: $confirmDelete) {
                Button("Delete Printer", role: .destructive) {
                    run("Deleting") { try await model.cups.delete(p.name) }
                }
            } message: {
                Text("This removes the queue \(p.name) and cancels its jobs. You can add it again later.")
            }
            .sheet(isPresented: $showRename) { RenamePrinterView(printer: p) }
            .sheet(isPresented: $showTextPrint) { TextPrintView(printer: p) }
            .alert("Sent to \(p.displayName)", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(info ?? "") }
        }
    }

    private func run(_ label: String, _ op: @escaping () async throws -> Void) {
        Task { await model.perform(label, op) }
    }

    @ViewBuilder
    private func header(_ p: Printer) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: p.symbolName)
                    .font(.system(size: 34, weight: .light))
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Circle().fill(p.statusColor).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.displayName).font(.title2.weight(.semibold))
                    if p.isDefault { Badge(text: "Default", color: .accentColor) }
                    if p.isShared { Badge(text: "Shared", color: .purple) }
                }
                Text([p.makeAndModel, p.location].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(p.statusText).foregroundStyle(p.statusColor)
                    if !p.stateMessage.isEmpty { Text("— \(p.stateMessage)").foregroundStyle(.secondary) }
                }
                .font(.callout)
                if !p.meaningfulReasons.isEmpty {
                    Text(p.meaningfulReasons.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(p.hasProblem ? .red : .secondary)
                }
            }
            Spacer()
            actions(p)
        }
    }

    @ViewBuilder
    private func actions(_ p: Printer) -> some View {
        HStack(spacing: 8) {
            if p.isPaused {
                Button { run("Resuming") { try await model.cups.resume(p.name) } } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { reason = ""; askPauseReason = true } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            Menu {
                Button("Print Test Page") {
                    Task {
                        do { info = try await model.cups.printTestPage(to: p.name) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
                Button("Print Text…") { showTextPrint = true }
                Button("Print File…") { printFile(p) }
            } label: {
                Label("Test", systemImage: "doc.text")
            }
            .fixedSize()
            Menu {
                if !p.isDefault {
                    Button("Make Default Printer") { run("Setting default") { try await model.cups.makeDefault(p.name) } }
                }
                if p.isAccepting {
                    Button("Stop Accepting Jobs…") { reason = ""; askRejectReason = true }
                } else {
                    Button("Accept Jobs") { run("Updating") { try await model.cups.setAccepting(p.name, true) } }
                }
                Button(p.isShared ? "Stop Sharing" : "Share on Network") {
                    run("Updating") { try await model.cups.setShared(p.name, !p.isShared) }
                }
                Divider()
                Button("Rename or Duplicate…") { showRename = true }
                Button("Copy Queue Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.name, forType: .string)
                }
                Divider()
                Button("Delete Printer…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .controlSize(.regular)
    }

    private func printFile(_ p: Printer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, .image, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { info = try await model.cups.printFile(url.path, to: p.name, title: url.lastPathComponent) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Print text

struct TextPrintView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let printer: Printer
    @State private var text = "QueueMaster test\nThe quick brown fox"
    @State private var copies = 1
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Print text to \(printer.displayName)").font(.headline)
            Text("Plain text is a quick way to test a label or receipt printer without a full page.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Stepper("Copies: \(copies)", value: $copies, in: 1...99)
            if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Print") {
                    Task {
                        do {
                            result = try await model.cups.printText(text, to: printer.name,
                                                                    options: copies > 1 ? ["copies": String(copies)] : [:])
                        } catch { result = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Rename / duplicate

struct RenamePrinterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let printer: Printer
    @State private var newName = ""
    @State private var removeOriginal = true
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename or duplicate \(printer.name)").font(.headline)
            Text("CUPS can't rename a queue in place, so QueueMaster creates a new queue with the same connection, driver and defaults, then removes the old one if you choose.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("New queue name", text: $newName)
                .textFieldStyle(.roundedBorder)
            let clean = CupsClient.sanitizeQueueName(newName)
            if !newName.isEmpty && clean != newName {
                Text("Will be created as \(clean)").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Remove \(printer.name) afterwards (rename)", isOn: $removeOriginal)
            Text("Apps that remember the old name (shipping software, label tools) will need to be pointed at the new one.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(removeOriginal ? "Rename" : "Duplicate") {
                    working = true
                    Task {
                        let ppd = await model.cups.ppdText(for: printer.name)?.text
                        let ok = await model.perform(removeOriginal ? "Renaming" : "Duplicating") {
                            try await model.cups.duplicate(printer, as: clean, ppdText: ppd, removeOriginal: removeOriginal)
                        }
                        working = false
                        if ok {
                            model.selection = .printer(clean)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clean.isEmpty || clean == printer.name || working
                          || model.printers.contains { $0.name.caseInsensitiveCompare(clean) == .orderedSame })
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { newName = printer.name + "_2" }
    }
}

// MARK: - Attributes

struct AttributesView: View {
    let printer: Printer
    @State private var filter = ""

    struct Row: Identifiable { let key: String; let value: String; var id: String { key } }

    var rows: [Row] {
        printer.attributes.keys.sorted()
            .map { Row(key: $0, value: printer.attributes[$0] ?? "") }
            .filter { filter.isEmpty || $0.key.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("From lpoptions -p \(printer.name)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            List(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 240, alignment: .leading)
                    Text(row.value.isEmpty ? "—" : row.value).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}
