import Foundation

/// Support for printers with more than one roll (DYMO LabelWriter Twin Turbo,
/// Twin Turbo 450/550 and similar), where the PPD picks the roll with the
/// `InputSlot` option.
///
/// Apps like Chrome can only choose a printer, not a roll, so each roll gets
/// its own CUPS queue: same device, same driver, with `InputSlot` and
/// `PageSize` defaulted to that roll. Picking "DYMO Inventory" in Chrome then
/// prints on the right roll at the right size.
///
/// Each roll printer is also LOCKED to its roll: its copy of the driver's PPD
/// offers only that one InputSlot choice. Apps that send their own roll with
/// a job (DYMO Connect does: its last-used side then sticks for everything),
/// a user override in ~/.cups/lpoptions, or `lpadmin -o InputSlot=…` can't
/// change it, because CUPS ignores choices the PPD doesn't have. DYMO's
/// filter then always sends that roll's select command (ESC q 1 / ESC q 2).
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
    /// The queue's PPD offers only this roll, so nothing can switch it.
    public var locked: Bool = false
}

public extension PrinterOptions {
    /// The label rolls this printer can pick between (excluding automatic
    /// switching). Only sources that are actually rolls count: a Twin Turbo's
    /// "Left Roll" / "Right Roll", not an office printer's Tray 1 / Tray 2 /
    /// Manual Feed, which also use InputSlot.
    var rollSlots: [RollSlot] {
        guard let opt = all.first(where: { $0.key == "InputSlot" }) else { return [] }
        let slots = opt.choices
            .filter { Self.isRoll($0) }
            .map { RollSlot(keyword: $0.keyword, label: $0.label) }
        return slots.count >= 2 ? slots : []
    }

    static func isRoll(_ c: OptionChoice) -> Bool {
        let text = (c.keyword + " " + c.label).lowercased()
        if text.contains("auto") { return false }
        return text.contains("roll") || ["left", "right"].contains(c.keyword.lowercased())
    }

    var pageSizeOption: PrinterOption? { all.first { $0.key == "PageSize" } }

    /// The roll this queue is locked to, when its InputSlot has exactly one choice and that choice is a roll.
    var lockedRoll: String? {
        guard let opt = all.first(where: { $0.key == "InputSlot" }), opt.choices.count == 1,
              let only = opt.choices.first, Self.isRoll(only) else { return nil }
        return only.keyword
    }

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
                                    slot: opts?.lockedRoll ?? opts?.queueDefault("InputSlot"),
                                    pageSize: opts?.queueDefault("PageSize"),
                                    locked: opts?.lockedRoll != nil))
        }
        return result
    }

    public static func rollOptionArguments(_ queue: String, info: String, slot: String, pageSize: String?) -> [String] {
        var args = ["-p", queue, "-D", info, "-o", "InputSlot=\(slot)"]
        if let pageSize, !pageSize.isEmpty { args += ["-o", "PageSize=\(pageSize)"] }
        return args
    }

    /// Creates a queue for one roll of `base`, or updates it if it exists.
    /// When the base printer's PPD is readable, the queue gets a copy locked
    /// to `slot` (see `lockedPPD`), installed again on every save.
    public func configureRollQueue(base: Printer, baseOptions: PrinterOptions, queue: String, info: String,
                                   slot: String, pageSize: String?, exists: Bool) async throws {
        var lockedFile: String?
        if let ppd = baseOptions.ppdText {
            lockedFile = try Self.writePPD(Self.lockedPPD(ppd, slot: slot))
        }
        defer { if let lockedFile { try? FileManager.default.removeItem(atPath: lockedFile) } }

        if !exists {
            let driver: DriverChoice
            if let lockedFile { driver = .ppdFile(lockedFile) }
            else { driver = try await driverForCopy(of: base, ppdText: baseOptions.ppdText) }
            var n = NewPrinter(name: queue, deviceURI: base.deviceURI, driver: driver)
            n.info = info
            n.location = base.location
            try await add(n)
        } else if let lockedFile {
            // Replacing the PPD resets its defaults; they're set again just below.
            try await admin("lpadmin", ["-p", queue, "-P", lockedFile], timeout: 120)
        }
        try await admin("lpadmin", Self.rollOptionArguments(queue, info: info, slot: slot, pageSize: pageSize))
        // A per-user roll override would be ignored by a locked queue anyway; drop it so the Options tab is honest.
        _ = await read("lpoptions", ["-p", queue, "-r", "InputSlot"])
    }

    /// Writes PPD text to a temporary file in the encoding it declares.
    static func writePPD(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queuemaster-\(UUID().uuidString).ppd")
        let latin1 = text.contains("*LanguageEncoding: ISOLatin1") || text.contains("*LanguageEncoding: WindowsANSI")
        let data = latin1 ? text.data(using: .isoLatin1, allowLossyConversion: true) : Data(text.utf8)
        try data?.write(to: url)
        return url.path
    }

    /// A copy of a PPD whose InputSlot offers only `slot`: the other choices,
    /// their translations and any constraints that name them are removed, and
    /// the default is set to `slot`. Everything else is left byte for byte.
    public static func lockedPPD(_ text: String, slot: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var skippingQuoted = false
        var skipEnd = false

        /// "*InputSlot Right/Right Roll:" or "*de.InputSlot Right/…:" → "Right".
        func choiceKeyword(_ line: String) -> String? {
            guard line.hasPrefix("*") else { return nil }
            var rest = line.dropFirst()
            if let dot = rest.firstIndex(of: "."), let space = rest.firstIndex(of: " "), dot < space {
                rest = rest[rest.index(after: dot)...]   // translation prefix such as "de."
            }
            guard rest.hasPrefix("InputSlot ") else { return nil }
            let kw = rest.dropFirst("InputSlot ".count).prefix { $0 != "/" && $0 != ":" && $0 != " " }
            return kw.isEmpty ? nil : String(kw)
        }

        for line in lines {
            if skippingQuoted {
                if line.filter({ $0 == "\"" }).count % 2 == 1 { skippingQuoted = false; skipEnd = true }
                continue
            }
            if skipEnd {
                skipEnd = false
                if line.trimmingCharacters(in: .whitespaces) == "*End" { continue }   // closes the removed value
            }
            if line.hasPrefix("*DefaultInputSlot:") {
                out.append("*DefaultInputSlot: \(slot)")
                continue
            }
            if let kw = choiceKeyword(line), kw.caseInsensitiveCompare(slot) != .orderedSame {
                // Its value may be a quoted string that runs over several lines.
                if let colon = line.firstIndex(of: ":"),
                   line[line.index(after: colon)...].filter({ $0 == "\"" }).count % 2 == 1 {
                    skippingQuoted = true
                }
                continue
            }
            if line.hasPrefix("*UIConstraints:") || line.hasPrefix("*NonUIConstraints:") {
                let words = line.split(separator: " ", omittingEmptySubsequences: true)
                if let i = words.firstIndex(of: "*InputSlot"), i + 1 < words.count,
                   !words[i + 1].hasPrefix("*"), words[i + 1].caseInsensitiveCompare(slot) != .orderedSame {
                    continue
                }
            }
            out.append(line)
        }
        return out.joined(separator: newline)
    }

    /// How to give a new queue the same driver as `p`: its PPD if readable,
    /// otherwise the installed driver with the same make and model.
    func driverForCopy(of p: Printer, ppdText: String?) async throws -> DriverChoice {
        if let ppdText {
            return .ppdFile(try Self.writePPD(ppdText))
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
