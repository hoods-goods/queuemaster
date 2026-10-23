import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CupsKit

/// Description, location, connection, sharing and driver for one queue.
struct PrinterSettingsView: View {
    @Environment(AppModel.self) private var model
    let printer: Printer

    @State private var info = ""
    @State private var location = ""
    @State private var uri = ""
    @State private var showDriverSheet = false

    private var edits: CupsClient.PrinterEdits {
        CupsClient.PrinterEdits(
            info: info != printer.info ? info : nil,
            location: location != printer.location ? location : nil,
            deviceURI: uri != printer.deviceURI ? uri : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    LabeledContent("Queue name") {
                        Text(printer.name).font(.body.monospaced()).textSelection(.enabled)
                    }
                    TextField("Description", text: $info, prompt: Text("Shown in print dialogs"))
                    TextField("Location", text: $location, prompt: Text("e.g. Shipping desk"))
                }
                Section {
                    TextField("Device URI", text: $uri)
                        .font(.body.monospaced())
                    LabeledContent("Connection", value: printer.connectionLabel)
                    URITemplateMenu(uri: $uri)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Point the queue at a new IP or port here, e.g. after a label printer gets a new address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Driver") {
                    LabeledContent("Current driver", value: printer.makeAndModel.isEmpty ? "Unknown / raw" : printer.makeAndModel)
                    Button("Change Driver…") { showDriverSheet = true }
                }
                Section("Sharing") {
                    Toggle("Share this printer on the network", isOn: Binding(
                        get: { printer.isShared },
                        set: { on in Task { await model.perform("Updating sharing") { try await model.cups.setShared(printer.name, on) } } }))
                    Text("Other Macs can only see shared printers when printer sharing is also on in Server Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if !edits.isEmpty {
                Divider()
                HStack {
                    Text(Shell.quote(["lpadmin"] + CupsClient.editArguments(printer.name, edits)))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Revert") { reset() }
                    Button("Save") {
                        let e = edits
                        Task { await model.perform("Saving") { try await model.cups.edit(printer.name, e) } }
                    }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.bar)
            }
        }
        .onAppear(perform: reset)
        .onChange(of: printer) { old, new in
            // Pick up saved values, but don't clobber fields being edited.
            if info == old.info { info = new.info }
            if location == old.location { location = new.location }
            if uri == old.deviceURI { uri = new.deviceURI }
        }
        .sheet(isPresented: $showDriverSheet) {
            ChangeDriverView(printer: printer)
        }
    }

    private func reset() {
        info = printer.info
        location = printer.location
        uri = printer.deviceURI
    }
}

struct URITemplateMenu: View {
    @Binding var uri: String
    @State private var host = ""

    static let templates: [(label: String, make: (String) -> String)] = [
        ("IPP (AirPrint, most network printers)", { "ipp://\($0)/ipp/print" }),
        ("IPPS (IPP over TLS)", { "ipps://\($0)/ipp/print" }),
        ("AppSocket / JetDirect, port 9100 (Zebra, receipt printers)", { "socket://\($0):9100" }),
        ("LPD", { "lpd://\($0)/queue" }),
        ("Windows / SMB share", { "smb://\($0)/printer" }),
    ]

    var body: some View {
        HStack {
            TextField("Host or IP", text: $host, prompt: Text("192.168.1.50"))
                .frame(maxWidth: 200)
            Menu("Build URI") {
                ForEach(Self.templates.indices, id: \.self) { i in
                    Button(Self.templates[i].label) {
                        uri = Self.templates[i].make(host.isEmpty ? "HOST" : host)
                    }
                }
            }
            .fixedSize()
        }
    }
}

// MARK: - Drivers

struct DriverPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var choice: CupsClient.DriverChoice?
    /// Text used to rank matching drivers first (a device's make and model).
    var hint: String = ""

    @State private var search = ""

    private func score(_ d: Driver) -> Int {
        let words = hint.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        let mm = d.makeAndModel.lowercased()
        return words.reduce(0) { $0 + (mm.contains($1) ? 1 : 0) }
    }

    private var list: [Driver] {
        var drivers = model.drivers
        if !search.isEmpty {
            drivers = drivers.filter { $0.makeAndModel.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
        }
        if !hint.isEmpty {
            drivers = drivers.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
        }
        return Array(drivers.prefix(400))
    }

    private var selectedModel: String? {
        if case .model(let m) = choice { return m }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { choice = .model("everywhere") } label: {
                    Label("Driverless (IPP Everywhere / AirPrint)", systemImage: selectedModel == "everywhere" ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            HStack {
                Button { choice = .raw } label: {
                    Label("Raw queue: send data unchanged (ZPL/EPL/ESC-POS from your app)", systemImage: choice == .raw ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    panel.message = "Choose a PPD file (.ppd or .ppd.gz)"
                    if panel.runModal() == .OK, let url = panel.url { choice = .ppdFile(url.path) }
                } label: {
                    if case .ppdFile(let path) = choice {
                        Label("PPD file: \((path as NSString).lastPathComponent)", systemImage: "largecircle.fill.circle")
                    } else {
                        Label("Choose a PPD file…", systemImage: "circle")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Divider()
            HStack {
                TextField("Search installed drivers", text: $search).textFieldStyle(.roundedBorder)
                if model.driversLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.loadDrivers(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload the driver list (lpinfo -m)")
            }
            List(list, selection: Binding(get: { selectedModel }, set: { if let m = $0 { choice = .model(m) } })) { d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.makeAndModel)
                    Text(d.name).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(minHeight: 200)
        }
        .task { await model.loadDrivers() }
    }
}

struct ChangeDriverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let printer: Printer
    @State private var choice: CupsClient.DriverChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change driver for \(printer.displayName)").font(.headline)
            Text("Current: \(printer.makeAndModel.isEmpty ? "unknown" : printer.makeAndModel). Changing the driver resets this queue's option defaults.")
                .font(.callout).foregroundStyle(.secondary)
            DriverPicker(choice: $choice, hint: printer.makeAndModel + " " + printer.info)
            HStack {
                if let choice, choice != .raw {
                    Text(Shell.quote(["lpadmin", "-p", printer.name] + choiceArgs(choice)))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Change Driver") {
                    guard let choice else { return }
                    Task {
                        if await model.perform("Changing driver", { try await model.cups.changeDriver(printer.name, to: choice) }) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || choice == .raw)
            }
            if choice == .raw {
                Text("To make an existing queue raw, delete it and add it again as a raw queue.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }

    private func choiceArgs(_ c: CupsClient.DriverChoice) -> [String] {
        switch c {
        case .model(let m): return ["-m", m]
        case .ppdFile(let p): return ["-P", p]
        case .raw: return []
        }
    }
}
