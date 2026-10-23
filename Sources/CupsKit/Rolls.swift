import Foundation

/// Support for printers with more than one roll (DYMO LabelWriter Twin Turbo,
/// Twin Turbo 450/550 and similar), where the PPD picks the roll with the
/// `InputSlot` option.
///
/// Apps like Chrome can only choose a printer, not a roll, so each roll gets
/// its own CUPS queue: same device, same driver, with `InputSlot` and
/// `PageSize` defaulted to that roll. Picking "DYMO Inventory" in Chrome then
/// prints on the right roll at the right size.
public struct RollSlot: Identifiable, Hashable, Sendable {
    public var id: String { keyword }
    /// The `InputSlot` value, e.g. "Left".
    public var keyword: String
    /// The PPD's label for it, e.g. "Left Roll".
    public var label: String
}

/// A queue that prints to one roll of a multi-roll printer.
public struct RollQueue: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var info: String
    public var slot: String?
    public var pageSize: String?
}

public extension PrinterOptions {
    /// The rolls this printer can pick between (excluding automatic switching).
    var rollSlots: [RollSlot] {
        guard let opt = all.first(where: { $0.key == "InputSlot" }) else { return [] }
        let skip: Set<String> = ["auto", "autoselect", "default", "automatic"]
        let slots = opt.choices
            .filter { !skip.contains($0.keyword.lowercased()) }
            .map { RollSlot(keyword: $0.keyword, label: $0.label) }
        return slots.count >= 2 ? slots : []
    }

    var pageSizeOption: PrinterOption? { all.first { $0.key == "PageSize" } }

    func queueDefault(_ key: String) -> String? {
        all.first { $0.key == key }.flatMap { $0.queueDefault ?? $0.current }
    }
}

extension CupsClient {

    /// Other queues that print to the same device as `printer`.
    public static func siblings(of printer: Printer, in printers: [Printer]) -> [Printer] {
        guard !printer.deviceURI.isEmpty else { return [] }
        return printers.filter { $0.name != printer.name && sameDevice($0.deviceURI, printer.deviceURI) }
    }

    /// Device URIs match, ignoring trivial differences (trailing slash, case of the scheme).
    static func sameDevice(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("/") { t.removeLast() }
            if let colon = t.firstIndex(of: ":") { t = t[..<colon].lowercased() + t[colon...] }
            return t
        }
        return norm(a) == norm(b)
    }

    /// Reads which roll and label size each sibling queue defaults to.
    public func rollQueues(for printer: Printer, in printers: [Printer]) async -> [RollQueue] {
        var result: [RollQueue] = []
        for p in Self.siblings(of: printer, in: printers) {
            let opts = try? await options(for: p.name)
            result.append(RollQueue(name: p.name, info: p.info,
                                    slot: opts?.queueDefault("InputSlot"),
                                    pageSize: opts?.queueDefault("PageSize")))
        }
        return result
    }

    public static func rollOptionArguments(_ queue: String, info: String, slot: String, pageSize: String?) -> [String] {
        var args = ["-p", queue, "-D", info, "-o", "InputSlot=\(slot)"]
        if let pageSize, !pageSize.isEmpty { args += ["-o", "PageSize=\(pageSize)"] }
        return args
    }

    /// Creates a queue for one roll of `base`, or updates it if it exists.
    public func configureRollQueue(base: Printer, baseOptions: PrinterOptions, queue: String, info: String,
                                   slot: String, pageSize: String?, exists: Bool) async throws {
        if !exists {
            let driver = try await driverForCopy(of: base, ppdText: baseOptions.ppdText)
            var n = NewPrinter(name: queue, deviceURI: base.deviceURI, driver: driver)
            n.info = info
            n.location = base.location
            try await add(n)
        }
        try await admin("lpadmin", Self.rollOptionArguments(queue, info: info, slot: slot, pageSize: pageSize))
    }

    /// How to give a new queue the same driver as `p`: its PPD if readable,
    /// otherwise the installed driver with the same make and model.
    func driverForCopy(of p: Printer, ppdText: String?) async throws -> DriverChoice {
        if let ppdText {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("queuemaster-\(UUID().uuidString).ppd")
            let latin1 = ppdText.contains("*LanguageEncoding: ISOLatin1") || ppdText.contains("*LanguageEncoding: WindowsANSI")
            let data = latin1 ? ppdText.data(using: .isoLatin1, allowLossyConversion: true) : Data(ppdText.utf8)
            try data?.write(to: url)
            return .ppdFile(url.path)
        }
        if !p.makeAndModel.isEmpty,
           let match = try await drivers().first(where: { $0.makeAndModel.caseInsensitiveCompare(p.makeAndModel) == .orderedSame }) {
            return .model(match.name)
        }
        if ["ipp", "ipps", "dnssd"].contains(p.scheme) { return .model("everywhere") }
        throw CupsError.message("QueueMaster couldn't read this printer's driver to copy it. Make sure the DYMO driver is installed, or add the roll printer with Add Printer.")
    }

    /// A tidy default queue name for a roll, e.g. "DYMO_Inventory".
    public static func suggestedRollQueueName(base: Printer, labelName: String, slot: RollSlot) -> String {
        let brand = base.makeAndModel.split(separator: " ").first.map(String.init) ?? base.name
        let what = labelName.isEmpty ? slot.keyword : labelName
        return sanitizeQueueName("\(brand) \(what)")
    }
}
