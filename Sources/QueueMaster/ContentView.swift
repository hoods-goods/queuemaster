import SwiftUI
import CupsKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                switch model.selection {
                case .printer(let name):
                    if model.printer(named: name) != nil {
                        PrinterDetailView(printerName: name)
                            .id(name)
                    } else {
                        ContentUnavailableView("Printer not found", systemImage: "printer")
                    }
                case .server: ServerSettingsView()
                case .logs: LogsView()
                case .activity: ActivityView()
                case .console: ConsoleView()
                case nil:
                    ContentUnavailableView {
                        Label("No printer selected", systemImage: "printer")
                    } description: {
                        Text(model.printers.isEmpty ? "No printers are set up on this Mac yet." : "Pick a printer on the left.")
                    } actions: {
                        Button("Add Printer…") { model.showAddPrinter = true }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let busy = model.busyMessage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $model.showAddPrinter) {
            AddPrinterView()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("Show Activity") { model.errorMessage = nil; model.selection = .activity }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Printers") {
                ForEach(model.printers) { p in
                    PrinterRow(printer: p)
                        .tag(SidebarItem.printer(p.name))
                }
                if model.printers.isEmpty {
                    Text(model.loadError ?? "No printers")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            Section("CUPS") {
                Label("Server Settings", systemImage: "server.rack").tag(SidebarItem.server)
                Label("Logs", systemImage: "doc.text.magnifyingglass").tag(SidebarItem.logs)
                Label("Activity", systemImage: "clock.arrow.circlepath").tag(SidebarItem.activity)
                Label("Console", systemImage: "terminal").tag(SidebarItem.console)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh printer status")
                Button { model.showAddPrinter = true } label: {
                    Label("Add Printer", systemImage: "plus")
                }
                .help("Add a printer")
            }
        }
    }
}

struct PrinterRow: View {
    let printer: Printer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: printer.symbolName)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(printer.displayName).lineLimit(1)
                    if printer.isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .help("Default printer")
                    }
                }
                Text(printer.stateMessage.isEmpty ? printer.statusText : printer.stateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(printer.statusColor)
                .frame(width: 8, height: 8)
                .help(printer.statusText)
        }
        .padding(.vertical, 2)
    }
}
