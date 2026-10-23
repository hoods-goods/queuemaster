import SwiftUI
import AppKit
import CupsKit

// MARK: - Server settings

struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings: ServerSettings?
    @State private var loadError: String?

    struct Policy: Hashable { let value: String; let label: String }
    static let policies: [Policy] = [
        Policy(value: "stop-printer", label: "Pause the printer"),
        Policy(value: "retry-job", label: "Retry the job later"),
        Policy(value: "retry-current-job", label: "Retry the job right away"),
        Policy(value: "abort-job", label: "Cancel the job"),
    ]

    var body: some View {
        Form {
            if let s = settings {
                Section {
                    flagToggle("Share printers connected to this Mac", "share-printers", s.sharePrinters)
                    flagToggle("Allow printing from any network (not just the local subnet)", "remote-any", s.remoteAny)
                    flagToggle("Allow remote administration", "remote-admin", s.remoteAdmin)
                    flagToggle("Let users cancel any job (not just their own)", "user-cancel-any", s.userCancelAny)
                    flagToggle("Debug logging (very detailed error_log)", "debug-logging", s.debugLogging)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Each change runs cupsctl, which restarts the CUPS scheduler for a moment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("When a printer fails") {
                    Picker("Default error policy", selection: Binding(
                        get: { s.errorPolicy },
                        set: { v in change("Updating") { try await model.cups.setServerValue("ErrorPolicy", v) } })) {
                        ForEach(Self.policies, id: \.self) { Text($0.label).tag($0.value) }
                        if !Self.policies.contains(where: { $0.value == s.errorPolicy }) {
                            Text(s.errorPolicy).tag(s.errorPolicy)
                        }
                    }
                }
                Section("All values (cupsctl)") {
                    ForEach(s.values.keys.sorted(), id: \.self) { key in
                        let value = s.values[key] ?? ""
                        LabeledContent(key) {
                            Text(value.isEmpty ? "—" : value).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("About the old web interface") {
                    Text("macOS 27 removed the CUPS web interface (cupsctl WebInterface=yes no longer works). The scheduler and command-line tools are unchanged; QueueMaster drives those.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server Settings")
        .task { await load() }
    }

    private func flagToggle(_ title: String, _ flag: String, _ on: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { v in
            change("Updating server") { try await model.cups.setServerFlag(flag, v) }
        }))
    }

    private func change(_ label: String, _ op: @escaping () async throws -> Void) {
        Task {
            await model.perform(label, op)
            // cupsd restarts after cupsctl; give it a moment.
            try? await Task.sleep(for: .seconds(1))
            await load()
        }
    }

    private func load() async {
        do { settings = try await model.cups.serverSettings(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

// MARK: - Logs

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var file = "error_log"
    @State private var text = ""
    @State private var filter = ""
    @State private var error: String?
    @State private var elevated = false
    @State private var loading = false

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $file) {
                    ForEach(CupsClient.logFiles, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                TextField("Filter lines", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Read as Administrator") { elevated = true; Task { await load() } }
                    .help("For logs your account isn't allowed to read")
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(10)
            Divider()
            if let error {
                ContentUnavailableView("Couldn't read \(file)", systemImage: "lock", description: Text(error))
            } else {
                ScrollView {
                    Text(shown.isEmpty ? "(empty)" : shown)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .navigationTitle("Logs")
        .task(id: file) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            text = try await model.cups.readLog(file, elevated: elevated)
            error = nil
        } catch CupsError.cancelled {
            elevated = false
        } catch let e {
            error = e.localizedDescription
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = Set<UUID>()

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock",
                                       description: Text("Every change QueueMaster makes shows up here with the exact command it ran."))
            } else {
                List(model.activity) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? .green : .red)
                            Text(r.displayCommand)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(expanded.contains(r.id) ? nil : 1)
                            Spacer()
                            if r.elevated { Badge(text: "admin", color: .orange) }
                            Text(r.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(r.displayCommand, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy command")
                        }
                        if !r.output.isEmpty && (expanded.contains(r.id) || !r.ok) {
                            Text(r.output)
                                .font(.caption.monospaced())
                                .foregroundStyle(r.ok ? Color.secondary : Color.red)
                                .textSelection(.enabled)
                                .padding(.leading, 24)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Clear") { model.activity.removeAll() }.disabled(model.activity.isEmpty)
        }
    }
}

// MARK: - Console

struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var line = ""
    @State private var elevated = false
    @State private var transcript: [CommandResult] = []
    @State private var running = false
    @FocusState private var focused: Bool

    static let examples = [
        "lpstat -t",
        "lpoptions -p PRINTER -l",
        "lpadmin -p PRINTER -o PageSize=w288h432",
        "lpinfo -m --make-and-model zebra",
        "cupsctl",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if transcript.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Run CUPS commands directly. Only CUPS tools are allowed (lpadmin, lpstat, lpoptions, lpinfo, lp, cancel, cupsctl…). Start with sudo or tick “As administrator” to run with the password prompt.")
                                    .foregroundStyle(.secondary)
                                ForEach(Self.examples, id: \.self) { ex in
                                    Button(ex) { line = ex.replacingOccurrences(of: "PRINTER", with: model.selectedPrinterName ?? model.printers.first?.name ?? "PRINTER") }
                                        .buttonStyle(.link)
                                        .font(.callout.monospaced())
                                }
                            }
                        }
                        ForEach(transcript) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("$ " + r.displayCommand).font(.callout.monospaced().weight(.semibold))
                                if !r.output.isEmpty {
                                    Text(r.output).font(.callout.monospaced())
                                        .foregroundStyle(r.ok ? Color.primary : Color.red)
                                        .textSelection(.enabled)
                                }
                                if !r.ok { Text("exit \(r.status)").font(.caption).foregroundStyle(.red) }
                            }
                            .id(r.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .onChange(of: transcript.count) { _, _ in
                    if let last = transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("$").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("lpstat -t", text: $line)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($focused)
                    .onSubmit { Task { await run() } }
                Toggle("As administrator", isOn: $elevated).toggleStyle(.checkbox)
                if running { ProgressView().controlSize(.small) }
                Button("Run") { Task { await run() } }.disabled(line.trimmingCharacters(in: .whitespaces).isEmpty || running)
                Button("Clear") { transcript.removeAll() }
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Console")
        .onAppear { focused = true }
    }

    private func run() async {
        let cmd = line.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        running = true
        defer { running = false }
        do {
            let r = try await model.cups.console(cmd, elevated: elevated)
            transcript.append(r)
            line = ""
            await model.refresh()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
