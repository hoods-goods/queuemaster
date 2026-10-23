import SwiftUI
import CupsKit

struct JobsView: View {
    @Environment(AppModel.self) private var model
    let printerName: String

    @State private var showCompleted = false
    @State private var jobs: [PrintJob] = []
    @State private var selection = Set<PrintJob.ID>()
    @State private var loadError: String?
    @State private var confirmCancelAll = false

    private var selectedJobs: [PrintJob] { jobs.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $showCompleted) {
                    Text("Waiting").tag(false)
                    Text("Completed").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                if !showCompleted {
                    Button("Hold") { act("Holding") { id in try await model.cups.hold(id) } }
                        .disabled(selectedJobs.isEmpty)
                    Button("Release") { act("Releasing") { id in try await model.cups.release(id) } }
                        .disabled(!selectedJobs.contains { $0.state == .held })
                    moveMenu
                    Button("Cancel Job", role: .destructive) { act("Cancelling") { id in try await model.cups.cancel(id) } }
                        .disabled(selectedJobs.isEmpty)
                    Button("Cancel All…") { confirmCancelAll = true }
                        .disabled(jobs.isEmpty)
                } else {
                    Button("Print Again") { act("Reprinting") { id in try await model.cups.reprint(id) } }
                        .disabled(selectedJobs.isEmpty)
                        .help("Reprints a completed job if CUPS still has its file (job history must be kept).")
                }
            }
            .padding(10)

            if jobs.isEmpty {
                ContentUnavailableView(showCompleted ? "No completed jobs" : "Queue is empty",
                                       systemImage: showCompleted ? "checkmark.circle" : "tray",
                                       description: Text(loadError ?? (showCompleted ? "CUPS only keeps recent job history." : "Nothing waiting to print.")))
            } else {
                Table(jobs, selection: $selection) {
                    TableColumn("Job") { j in Text("\(j.number)").monospacedDigit() }
                        .width(50)
                    TableColumn("Title") { j in Text(j.title.isEmpty ? "—" : j.title).lineLimit(1) }
                    TableColumn("Status") { j in
                        HStack(spacing: 5) {
                            Circle().fill(color(j.state)).frame(width: 7, height: 7)
                            Text(j.state.label)
                        }
                        .help(j.alerts.joined(separator: ", "))
                    }
                    .width(90)
                    TableColumn("User", value: \.user).width(90)
                    TableColumn("Size") { j in Text(ByteCountFormatter.string(fromByteCount: Int64(j.size), countStyle: .file)) }
                        .width(70)
                    TableColumn("Submitted", value: \.dateText)
                }
                .contextMenu(forSelectionType: PrintJob.ID.self) { ids in
                    if !ids.isEmpty && !showCompleted {
                        Button("Hold") { act("Holding", ids: ids) { id in try await model.cups.hold(id) } }
                        Button("Release") { act("Releasing", ids: ids) { id in try await model.cups.release(id) } }
                        Button("Cancel", role: .destructive) { act("Cancelling", ids: ids) { id in try await model.cups.cancel(id) } }
                    } else if !ids.isEmpty {
                        Button("Print Again") { act("Reprinting", ids: ids) { id in try await model.cups.reprint(id) } }
                    }
                }
            }
        }
        .confirmationDialog("Cancel every job on \(printerName)?", isPresented: $confirmCancelAll) {
            Button("Cancel All Jobs", role: .destructive) {
                Task {
                    await model.perform("Cancelling jobs") { try await model.cups.cancelAll(printerName) }
                    await load()
                }
            }
        }
        .task(id: showCompleted) {
            selection = []
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(max(2, model.refreshInterval)))
            }
        }
    }

    private var moveMenu: some View {
        Menu("Move To") {
            ForEach(model.printers.filter { $0.name != printerName }) { p in
                Button(p.displayName) {
                    act("Moving") { id in try await model.cups.move(id, to: p.name) }
                }
            }
        }
        .fixedSize()
        .disabled(selectedJobs.isEmpty || model.printers.count < 2)
    }

    private func color(_ s: JobState) -> Color {
        switch s {
        case .printing: return .blue
        case .held: return .orange
        case .pending: return .secondary
        case .completed: return .green
        }
    }

    private func load() async {
        do {
            let list = try await model.cups.jobs(for: printerName, completed: showCompleted)
            if list != jobs { jobs = list }
            selection = selection.filter { id in list.contains { $0.id == id } }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func act(_ label: String, ids: Set<PrintJob.ID>? = nil, _ op: @escaping (String) async throws -> Void) {
        let targets = Array(ids ?? selection)
        Task {
            await model.perform(label) {
                for id in targets { try await op(id) }
            }
            await load()
        }
    }
}
