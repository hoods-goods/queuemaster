import SwiftUI
import CupsKit

struct AddPrinterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [Device] = []
    @State private var scanning = false
    @State private var scanError: String?
    @State private var selectedDevice: Device.ID?

    @State private var uri = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var info = ""
    @State private var location = ""
    @State private var shared = false
    @State private var makeDefault = false
    @State private var driver: CupsClient.DriverChoice?
    @State private var hint = ""
    @State private var adding = false

    private var queueName: String { CupsClient.sanitizeQueueName(name) }

    private var newPrinter: CupsClient.NewPrinter? {
        guard !queueName.isEmpty, !uri.isEmpty, let driver else { return nil }
        var n = CupsClient.NewPrinter(name: queueName, deviceURI: uri, driver: driver)
        n.info = info
        n.location = location
        n.shared = shared
        n.makeDefault = makeDefault
        return n
    }

    private var nameTaken: Bool {
        model.printers.contains { $0.name.caseInsensitiveCompare(queueName) == .orderedSame }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Printer").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)

            HSplitView {
                connectionColumn
                    .frame(minWidth: 320, idealWidth: 360)
                    .padding(16)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Driver").font(.headline)
                    DriverPicker(choice: $driver, hint: hint)
                }
                .frame(minWidth: 360)
                .padding(16)
            }

            Divider()
            HStack(spacing: 12) {
                if let n = newPrinter {
                    Text(Shell.quote(["lpadmin"] + CupsClient.addArguments(n)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Text(missingText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if adding { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                Button("Add Printer") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(newPrinter == nil || nameTaken || adding)
            }
            .padding(14)
        }
        .frame(width: 900, height: 640)
        .task { await scan() }
    }

    private var missingText: String {
        if uri.isEmpty { return "Pick a discovered device or enter a device URI." }
        if queueName.isEmpty { return "Give the queue a name." }
        if driver == nil { return "Choose a driver." }
        return ""
    }

    private var connectionColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button("Scan Again") { Task { await scan() } }.disabled(scanning)
            }
            List(devices, selection: $selectedDevice) { d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.info.isEmpty ? d.uri : d.info)
                    Text(d.uri).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(minHeight: 140)
            .overlay {
                if devices.isEmpty && !scanning {
                    Text(scanError ?? "No devices found. Enter a URI below for network printers.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .onChange(of: selectedDevice) { _, id in
                guard let d = devices.first(where: { $0.id == id }) else { return }
                use(d)
            }

            Form {
                TextField("Device URI", text: $uri, prompt: Text("socket://192.168.1.50:9100"))
                    .font(.body.monospaced())
                URITemplateMenu(uri: $uri)
                TextField("Queue name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }),
                          prompt: Text("DYMO_4XL"))
                if !name.isEmpty && queueName != name {
                    Text("Will be created as \(queueName)").font(.caption).foregroundStyle(.secondary)
                }
                if nameTaken {
                    Text("A printer named \(queueName) already exists.").font(.caption).foregroundStyle(.red)
                }
                TextField("Description", text: $info, prompt: Text("DYMO LabelWriter 4XL"))
                TextField("Location", text: $location, prompt: Text("Shipping desk"))
                Toggle("Share on the network", isOn: $shared)
                Toggle("Make default printer", isOn: $makeDefault)
            }
            .formStyle(.grouped)
        }
    }

    private func use(_ d: Device) {
        uri = d.uri
        let title = d.makeAndModel.isEmpty || d.makeAndModel == "Unknown" ? d.info : d.makeAndModel
        if !nameEdited { name = CupsClient.sanitizeQueueName(title) }
        if info.isEmpty || !nameEdited { info = title }
        hint = [d.makeAndModel, d.info, d.deviceID].joined(separator: " ")
        if driver == nil, ["ipp", "ipps", "dnssd"].contains(where: { d.uri.hasPrefix($0 + ":") }) {
            driver = .model("everywhere")
        }
    }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        do {
            devices = try await model.cups.discoverDevices()
            scanError = nil
        } catch CupsError.cancelled {
            scanError = "Scanning for devices needs administrator access. Click Scan Again to retry, or enter a URI below."
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func add() async {
        guard let n = newPrinter else { return }
        adding = true
        defer { adding = false }
        if await model.perform("Adding \(n.name)", { try await model.cups.add(n) }) {
            model.selection = .printer(n.name)
            dismiss()
        }
    }
}
