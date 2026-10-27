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
/// Each roll printer also has the job default `InputSlot-default=<roll>`, so
/// cupsd adds `InputSlot=<roll>` to every job that doesn't name a roll. This
/// matters on macOS: jobs from the system print path (Chrome, Preview, …)
/// carry `AP_D_InputSlot=` ("automatic paper feed"), which makes libcups
/// UNMARK InputSlot. DYMO's filter then finds no roll ("unable to get
/// InputSlot choice"), sends ESC q 0 (automatic), and the Twin Turbo uses
/// whichever roll it used last.
///
/// Roll printers keep the driver's full PPD (both rolls). An app that names a
/// roll still gets it: DYMO Connect sends all of a Twin Turbo's jobs through
/// ONE of its CUPS queues (whichever it claimed) with the side picked in DYMO
/// Connect, so a queue locked to one roll (0.2.5–0.2.7, see `lockedPPD`)
/// made DYMO Connect print everything on that side. Saving a roll printer
/// now restores the full PPD.
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
    /// The printer whose Rolls tab is open.
    public var isSelf: Bool = false
    /// Its PPD offers only one roll (`slot`): a 0.2.5–0.2.7 lock, which makes DYMO Connect print on that side only.
    public var pinned: Bool = false

    /// The name or description says which roll it is, e.g. "DYMO Inventory (Left Roll)".
    public func mentions(_ slot: RollSlot) -> Bool {
        let text = (name + " " + info).lowercased()
        return text.contains(slot.label.lowercased()) || text.contains("(\(slot.keyword.lowercased()))")
    }
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

    /// The roll printer for `slot` among the queues on one device. A queue
    /// locked to the slot wins; otherwise one whose name or description names
    /// the slot ("… (Left Roll)") and not another one. The queue's current
    /// default roll isn't trusted on its own: apps such as DYMO Connect change it.
    public static func matchRollQueue(_ slot: RollSlot, allSlots: [RollSlot], in queues: [RollQueue]) -> RollQueue? {
        func on(_ q: RollQueue) -> Bool { q.slot?.caseInsensitiveCompare(slot.keyword) == .orderedSame }
        if let q = queues.first(where: { $0.locked && on($0) && (!$0.isSelf || $0.mentions(slot)) }) { return q }
        if let q = queues.first(where: { $0.pinned && on($0) }) { return q }
        let others = allSlots.filter { $0.keyword != slot.keyword }
        return queues.first { q in !q.pinned && q.mentions(slot) && !others.contains(where: { q.mentions($0) }) }
    }

    /// Reads which roll and label size each queue on the same device (this printer included) defaults to.
    public func rollQueues(for printer: Printer, in printers: [Printer]) async -> [RollQueue] {
        var result: [RollQueue] = []
        for p in [printer] + Self.siblings(of: printer, in: printers) {
            let opts = try? await options(for: p.name)
            result.append(RollQueue(name: p.name, info: p.info,
                                    slot: opts?.lockedRoll ?? p.attributes["InputSlot"].flatMap { $0.isEmpty ? nil : $0 }
                                        ?? opts?.queueDefault("InputSlot"),
                                    pageSize: opts?.queueDefault("PageSize"),
                                    // "locked" = jobs that name no roll get this one (the job default is set).
                                    locked: !(p.attributes["InputSlot"] ?? "").isEmpty
                                        && (opts?.lockedRoll == nil || p.attributes["InputSlot"] == opts?.lockedRoll),
                                    isSelf: p.name == printer.name,
                                    pinned: opts?.lockedRoll != nil))
        }
        return result
    }

    public static func rollOptionArguments(_ queue: String, info: String, slot: String, pageSize: String?) -> [String] {
        var args = ["-p", queue, "-D", info, "-o", "InputSlot=\(slot)"]
        if let pageSize, !pageSize.isEmpty { args += ["-o", "PageSize=\(pageSize)"] }
        // Added by cupsd to every job that doesn't name a roll (see the note at the top).
        args += ["-o", "InputSlot-default=\(slot)"]
        return args
    }

    /// Creates a queue for one roll of `base`, or updates it if it exists.
    /// When the base printer's PPD is readable, the queue gets a copy locked
    /// to `slot` (see `lockedPPD`), installed again on every save.
    /// `restorePPD`: the queue was locked to one roll by 0.2.5–0.2.7, so it gets
    /// the base printer's full PPD back.
    public func configureRollQueue(base: Printer, baseOptions: PrinterOptions, queue: String, info: String,
                                   slot: String, pageSize: String?, exists: Bool, restorePPD: Bool = false) async throws {
        var fullFile: String?
        if let ppd = baseOptions.ppdText, !exists || restorePPD {
            fullFile = try Self.writePPD(ppd)
        }
        defer { if let fullFile { try? FileManager.default.removeItem(atPath: fullFile) } }

        if !exists {
            let driver: DriverChoice
            if let fullFile { driver = .ppdFile(fullFile) }
            else { driver = try await driverForCopy(of: base, ppdText: nil) }
            var n = NewPrinter(name: queue, deviceURI: base.deviceURI, driver: driver)
            n.info = info
            n.location = base.location
            try await add(n)
        } else if restorePPD {
            // Replacing the PPD resets its defaults; they're set again just below.
            if let fullFile { try await admin("lpadmin", ["-p", queue, "-P", fullFile], timeout: 120) }
            else { try await changeDriver(queue, to: try await driverForCopy(of: base, ppdText: nil)) }
        }
        try await admin("lpadmin", Self.rollOptionArguments(queue, info: info, slot: slot, pageSize: pageSize))
        // A per-user roll override in ~/.cups/lpoptions would beat the job default for this account.
        _ = await read("lpoptions", ["-p", queue, "-r", "InputSlot"])
    }

    /// Undoes a 0.2.5–0.2.7 single-roll lock on `printer` (a roll printer) by
    /// reinstalling its installed driver, then sets its roll and job default.
    public func unlockRollQueue(_ printer: Printer, slot: String, pageSize: String?) async throws {
        try await changeDriver(printer.name, to: try await driverForCopy(of: printer, ppdText: nil))
        try await admin("lpadmin", Self.rollOptionArguments(printer.name, info: printer.info, slot: slot, pageSize: pageSize))
        _ = await read("lpoptions", ["-p", printer.name, "-r", "InputSlot"])
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
