import SwiftUI
import AppKit
import CupsKit

@main
struct QueueMasterApp: App {
    @State private var model = AppModel()

    init() {
        // Launched from a SwiftPM build without a bundle, make it a normal app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("QueueMaster") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { model.startPolling() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Printer…") { model.showAddPrinter = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .sidebar) {
                Button("Activity") { model.selection = .activity }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Console") { model.selection = .console }
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }

        Settings {
            AppSettingsView()
                .environment(model)
        }
    }
}

struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Always ask for the administrator password for changes", isOn: $model.alwaysElevate)
            Text("Off: QueueMaster tries each change as you first and only asks for the password if CUPS refuses. On: every change goes straight through the password prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Refresh printer status every", selection: $model.refreshInterval) {
                Text("2 seconds").tag(2.0)
                Text("5 seconds").tag(5.0)
                Text("15 seconds").tag(15.0)
                Text("60 seconds").tag(60.0)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
