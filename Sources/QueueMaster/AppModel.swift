import SwiftUI
import Observation
import CupsKit

enum SidebarItem: Hashable {
    case printer(String)
    case server
    case logs
    case activity
    case console
}

@MainActor
@Observable
final class AppModel {
    let cups = CupsClient()

    var printers: [Printer] = []
    var selection: SidebarItem?
    var loadError: String?
    var lastRefresh: Date?

    /// Every change QueueMaster made (and any command that failed), newest first.
    var activity: [CommandResult] = []

    /// Shown as an alert.
    var errorMessage: String?
    /// Non-nil while a change is running.
    var busyMessage: String?

    var showAddPrinter = false

    /// Drivers from `lpinfo -m`, cached: listing them takes a few seconds.
    var drivers: [Driver] = []
    var driversLoading = false

    var alwaysElevate: Bool {
        didSet {
            UserDefaults.standard.set(alwaysElevate, forKey: "alwaysElevate")
            cups.alwaysElevate = alwaysElevate
        }
    }

    var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        alwaysElevate = UserDefaults.standard.bool(forKey: "alwaysElevate")
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = interval > 0 ? interval : 5
        cups.alwaysElevate = alwaysElevate
        cups.onCommand = { [weak self] result in
            Task { @MainActor in self?.record(result) }
        }
    }

    func record(_ r: CommandResult) {
        activity.insert(r, at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
    }

    func printer(named name: String) -> Printer? {
        printers.first { $0.name == name }
    }

    var selectedPrinterName: String? {
        if case .printer(let n) = selection { return n }
        return nil
    }

    // MARK: Refresh

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.refreshInterval ?? 5
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func refresh() async {
        do {
            let list = try await cups.printers()
            if list != printers { printers = list }
            loadError = nil
            lastRefresh = Date()
            if selection == nil, let first = list.first(where: \.isDefault) ?? list.first {
                selection = .printer(first.name)
            }
            if let name = selectedPrinterName, !list.contains(where: { $0.name == name }) {
                selection = list.first.map { .printer($0.name) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadDrivers(force: Bool = false) async {
        guard force || (drivers.isEmpty && !driversLoading) else { return }
        driversLoading = true
        defer { driversLoading = false }
        do {
            drivers = try await cups.drivers()
                .sorted { $0.makeAndModel.localizedStandardCompare($1.makeAndModel) == .orderedAscending }
        } catch {
            errorMessage = "Couldn't list drivers: \(error.localizedDescription)"
        }
    }

    // MARK: Changes

    /// Runs a change with a busy indicator, reports errors, then refreshes.
    @discardableResult
    func perform(_ label: String, _ operation: @escaping () async throws -> Void) async -> Bool {
        busyMessage = label
        defer { busyMessage = nil }
        do {
            try await operation()
            await refresh()
            return true
        } catch CupsError.cancelled {
            return false
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
            return false
        }
    }
}

extension Printer {
    var statusColor: Color {
        if hasProblem { return .red }
        if isPaused { return .orange }
        if !isAccepting { return .yellow }
        if state == .processing { return .blue }
        return .green
    }

    var statusText: String {
        var parts: [String] = [state.label]
        if !isAccepting { parts.append("rejecting jobs") }
        return parts.joined(separator: ", ")
    }

    var symbolName: String {
        let m = (makeAndModel + " " + info + " " + name).lowercased()
        if ["label", "dymo", "zebra", "rollo", "zpl", "epl", "brother ql"].contains(where: { m.contains($0) }) { return "tag" }
        if ["receipt", "thermal", "tm-", "star ", "pos"].contains(where: { m.contains($0) }) { return "scroll" }
        return "printer"
    }
}
