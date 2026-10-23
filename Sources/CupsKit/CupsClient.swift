import Foundation

/// Talks to the local CUPS server through its command-line tools.
///
/// Reads run as the current user. Changes are first tried as the current
/// user too (admins can usually manage CUPS directly); if CUPS refuses, the
/// command is re-run through the macOS administrator prompt. Per-user
/// settings (`lpoptions`) are never elevated, since running them as root
/// would change root's settings instead of yours.
public final class CupsClient: @unchecked Sendable {

    /// Skip the unprivileged attempt and go straight to the admin prompt.
    public var alwaysElevate = false
    /// Called (on a background thread) with every command that ran.
    public var onCommand: (@Sendable (CommandResult) -> Void)?

    public init() {}

    // MARK: - Tools

    public static func tool(_ name: String) -> String {
        for dir in ["/usr/sbin", "/usr/bin", "/usr/local/sbin", "/usr/local/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/sbin/" + name
    }

    /// The CUPS tools the console accepts.
    public static let consoleTools: Set<String> = [
        "lpadmin", "lpstat", "lpoptions", "lpinfo", "lp", "lpr", "lpq", "lprm", "cancel", "lpmove",
        "cupsctl", "cupsenable", "cupsdisable", "cupsaccept", "cupsreject", "cupstestppd", "ipptool", "lpc",
    ]

    // MARK: - Running

    /// Runs a read-only command. Routine reads aren't logged (the app polls
    /// every few seconds); failures and `log: true` calls are.
    @discardableResult
    func read(_ name: String, _ args: [String], timeout: TimeInterval = 30, log: Bool = false) async -> CommandResult {
        let r = await Shell.run([Self.tool(name)] + args, timeout: timeout)
        if log || !r.ok { onCommand?(r) }
        return r
    }

    func readOrThrow(_ name: String, _ args: [String], timeout: TimeInterval = 30) async throws -> String {
        let r = await read(name, args, timeout: timeout)
        guard r.ok else { throw CupsError.commandFailed(r) }
        return r.stdout
    }

    static func looksLikePermissionProblem(_ r: CommandResult) -> Bool {
        let text = r.output.lowercased()
        return ["forbidden", "unauthorized", "not authorized", "permission denied", "authentication",
                "password for", "operation not permitted", "not allowed", "must be root", "insufficient privileges"]
            .contains { text.contains($0) }
    }

    /// Runs a change, elevating when CUPS refuses for permission reasons.
    @discardableResult
    public func admin(_ name: String, _ args: [String], timeout: TimeInterval = 60) async throws -> CommandResult {
        let command = [Self.tool(name)] + args
        if !alwaysElevate {
            let r = await Shell.run(command, timeout: timeout)
            onCommand?(r)
            if r.ok { return r }
            guard Self.looksLikePermissionProblem(r) else { throw CupsError.commandFailed(r) }
        }
        let r = await Shell.runElevated(command, timeout: max(timeout, 300))
        onCommand?(r)
        if r.status == -128 { throw CupsError.cancelled }
        guard r.ok else { throw CupsError.commandFailed(r) }
        return r
    }

    /// Runs anything the user typed into the console (CUPS tools only).
    public func console(_ line: String, elevated: Bool) async throws -> CommandResult {
        var args = Shell.split(line)
        guard let first = args.first else { throw CupsError.message("Type a command first.") }
        if first == "sudo" { args.removeFirst() }
        guard let toolName = args.first.map({ ($0 as NSString).lastPathComponent }),
              Self.consoleTools.contains(toolName) else {
            throw CupsError.message("The console only runs CUPS tools: \(Self.consoleTools.sorted().joined(separator: ", ")).")
        }
        let command = [Self.tool(toolName)] + args.dropFirst()
        let r: CommandResult
        if elevated || first == "sudo" { r = await Shell.runElevated(command) }
        else { r = await Shell.run(command, timeout: 60) }
        onCommand?(r)
        if r.status == -128 { throw CupsError.cancelled }
        return r
    }

    // MARK: - Printers

    public func printers() async throws -> [Printer] {
        let list = await read("lpstat", ["-e"])
        // "No destinations added" comes back as an error on some versions.
        if !list.ok && list.output.localizedCaseInsensitiveContains("no destinations") { return [] }
        guard list.ok else { throw CupsError.commandFailed(list) }
        let names = Parsers.destinations(list.stdout).filter { !$0.contains("/") }
        if names.isEmpty { return [] }

        async let statusText = read("lpstat", ["-p"])
        async let acceptText = read("lpstat", ["-a"])
        async let defaultText = read("lpstat", ["-d"])
        let status = Parsers.printerStatus(await statusText.stdout)
        let accept = Parsers.acceptance(await acceptText.stdout)
        let def = Parsers.defaultDestination(await defaultText.stdout)

        var result: [Printer] = []
        await withTaskGroup(of: Printer.self) { group in
            for name in names {
                group.addTask {
                    var p = Printer(name: name)
                    let r = await Shell.run([Self.tool("lpoptions"), "-p", name], timeout: 15)
                    if r.ok { Parsers.applyLpoptions(r.stdout, to: &p) }
                    return p
                }
            }
            for await p in group { result.append(p) }
        }
        for i in result.indices {
            let name = result[i].name
            if let st = status[name] {
                result[i].stateMessage = st.message
                if !st.enabled { result[i].state = .stopped }
                else if st.nowPrinting != nil { result[i].state = .processing }
            }
            if let a = accept[name] {
                result[i].isAccepting = a.accepting
                if !a.accepting, !a.reason.isEmpty, result[i].stateMessage.isEmpty { result[i].stateMessage = a.reason }
            }
            result[i].isDefault = (name == def)
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func pause(_ printer: String, reason: String) async throws {
        var args = [printer]
        if !reason.isEmpty { args = ["-r", reason, printer] }
        try await admin("cupsdisable", args)
    }

    public func resume(_ printer: String) async throws {
        try await admin("cupsenable", [printer])
    }

    public func setAccepting(_ printer: String, _ accepting: Bool, reason: String = "") async throws {
        if accepting { try await admin("cupsaccept", [printer]) }
        else { try await admin("cupsreject", reason.isEmpty ? [printer] : ["-r", reason, printer]) }
    }

    /// Makes the printer the default both for CUPS and for your account.
    public func makeDefault(_ printer: String) async throws {
        try await admin("lpadmin", ["-d", printer])
        let r = await read("lpoptions", ["-d", printer], log: true)
        if !r.ok { throw CupsError.commandFailed(r) }
    }

    public func setShared(_ printer: String, _ shared: Bool) async throws {
        try await admin("lpadmin", ["-p", printer, "-o", "printer-is-shared=\(shared)"])
    }

    public struct PrinterEdits: Sendable {
        public var info: String?
        public var location: String?
        public var deviceURI: String?
        public init(info: String? = nil, location: String? = nil, deviceURI: String? = nil) {
            self.info = info; self.location = location; self.deviceURI = deviceURI
        }
        public var isEmpty: Bool { info == nil && location == nil && deviceURI == nil }
    }

    public static func editArguments(_ printer: String, _ e: PrinterEdits) -> [String] {
        var args = ["-p", printer]
        if let v = e.info { args += ["-D", v] }
        if let v = e.location { args += ["-L", v] }
        if let v = e.deviceURI { args += ["-v", v] }
        return args
    }

    public func edit(_ printer: String, _ e: PrinterEdits) async throws {
        guard !e.isEmpty else { return }
        try await admin("lpadmin", Self.editArguments(printer, e))
    }

    public enum DriverChoice: Hashable, Sendable {
        case model(String)        // lpadmin -m
        case ppdFile(String)      // lpadmin -P
        case raw                  // no driver: data goes to the printer untouched

        var arguments: [String] {
            switch self {
            case .model(let m): return ["-m", m]
            case .ppdFile(let p): return ["-P", p]
            case .raw: return []
            }
        }
    }

    public func changeDriver(_ printer: String, to driver: DriverChoice) async throws {
        let args = ["-p", printer] + driver.arguments
        guard args.count > 2 else { throw CupsError.message("Pick a driver or PPD file.") }
        try await admin("lpadmin", args, timeout: 120)
    }

    public struct NewPrinter: Sendable {
        public var name: String
        public var deviceURI: String
        public var driver: DriverChoice
        public var info = ""
        public var location = ""
        public var shared = false
        public var makeDefault = false
        public init(name: String, deviceURI: String, driver: DriverChoice) {
            self.name = name; self.deviceURI = deviceURI; self.driver = driver
        }
    }

    /// Queue names may only contain printable characters other than space,
    /// tab, "/", "\", "'", '"', "?" and "#".
    public static func sanitizeQueueName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: " \t/\\'\"?#@,")
        let scalars = s.unicodeScalars.map { bad.contains($0) || $0.value < 32 ? "_" : Character($0) }
        var name = String(scalars)
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        return String(name.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(127))
    }

    public static func addArguments(_ n: NewPrinter) -> [String] {
        var args = ["-p", n.name, "-E", "-v", n.deviceURI] + n.driver.arguments
        if !n.info.isEmpty { args += ["-D", n.info] }
        if !n.location.isEmpty { args += ["-L", n.location] }
        args += ["-o", "printer-is-shared=\(n.shared)"]
        return args
    }

    public func add(_ n: NewPrinter) async throws {
        try await admin("lpadmin", Self.addArguments(n), timeout: 180)
        if n.makeDefault { try await makeDefault(n.name) }
    }

    public func delete(_ printer: String) async throws {
        try await admin("lpadmin", ["-x", printer])
    }

    /// CUPS can't rename a queue, so this creates a copy under the new name
    /// (same connection, driver, description and defaults) and removes the old one.
    public func duplicate(_ p: Printer, as newName: String, ppdText: String?, removeOriginal: Bool) async throws {
        let driver = try await driverForCopy(of: p, ppdText: ppdText)
        var n = NewPrinter(name: newName, deviceURI: p.deviceURI, driver: driver)
        n.info = p.info == p.name ? newName : p.info
        n.location = p.location
        n.shared = p.isShared
        try await add(n)
        if removeOriginal {
            if p.isDefault { try await makeDefault(newName) }
            try await delete(p.name)
        }
    }

    // MARK: - Options

    public func ppdText(for printer: String) async -> (text: String, source: String)? {
        for path in ["/private/etc/cups/ppd/\(printer).ppd", "/etc/cups/ppd/\(printer).ppd"] {
            if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
                return (Parsers.decodePPD(data), "PPD file")
            }
        }
        // cupsd serves each queue's PPD over HTTP (not part of the old web UI).
        let encoded = printer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? printer
        if let url = URL(string: "http://localhost:631/printers/\(encoded).ppd") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                let text = Parsers.decodePPD(data)
                if text.hasPrefix("*PPD-Adobe") { return (text, "PPD (via CUPS)") }
            }
        }
        return nil
    }

    func userOptions(for printer: String) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".cups/lpoptions").path
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return Parsers.userOptionsFile(String(decoding: data, as: UTF8.self))[printer] ?? [:]
    }

    public func options(for printer: String) async throws -> PrinterOptions {
        let listText = try await readOrThrow("lpoptions", ["-p", printer, "-l"])
        let effective = Parsers.optionList(listText)
        let user = userOptions(for: printer)

        var groups: [OptionGroup]
        var source = "lpoptions"
        var ppd: String?
        if let found = await ppdText(for: printer) {
            groups = Parsers.ppd(found.text)
            source = found.source
            ppd = found.text
        } else {
            var opts = effective
            for i in opts.indices { opts[i].queueDefault = nil }
            groups = [OptionGroup(name: "Options", label: "Options", options: opts)]
        }

        let currentByKey = Dictionary(effective.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for gi in groups.indices {
            for oi in groups[gi].options.indices {
                let key = groups[gi].options[oi].key
                if let eff = currentByKey[key] {
                    groups[gi].options[oi].current = eff.current
                    groups[gi].options[oi].supportsCustom = groups[gi].options[oi].supportsCustom || eff.supportsCustom
                }
                if let u = user[key] { groups[gi].options[oi].userValue = u }
                if groups[gi].options[oi].current == nil {
                    groups[gi].options[oi].current = groups[gi].options[oi].userValue ?? groups[gi].options[oi].queueDefault
                }
            }
        }
        // Common groups first, installable options last.
        groups.sort { a, b in
            func rank(_ g: OptionGroup) -> Int {
                if g.name == "General" { return 0 }
                if g.name.localizedCaseInsensitiveContains("install") { return 2 }
                return 1
            }
            return rank(a) < rank(b)
        }
        return PrinterOptions(groups: groups, source: source, ppdText: ppd)
    }

    public static func setOptionArguments(_ printer: String, _ values: [String: String]) -> [String] {
        var args = ["-p", printer]
        for (k, v) in values.sorted(by: { $0.key < $1.key }) { args += ["-o", "\(k)=\(v)"] }
        return args
    }

    /// Changes the queue defaults (the PPD) for everyone on this Mac.
    public func setQueueDefaults(_ printer: String, _ values: [String: String]) async throws {
        guard !values.isEmpty else { return }
        try await admin("lpadmin", Self.setOptionArguments(printer, values))
    }

    /// Changes only your account's defaults (~/.cups/lpoptions).
    public func setUserDefaults(_ printer: String, _ values: [String: String]) async throws {
        guard !values.isEmpty else { return }
        let r = await read("lpoptions", Self.setOptionArguments(printer, values), log: true)
        if !r.ok { throw CupsError.commandFailed(r) }
    }

    public func clearUserDefault(_ printer: String, key: String) async throws {
        let r = await read("lpoptions", ["-p", printer, "-r", key], log: true)
        if !r.ok { throw CupsError.commandFailed(r) }
    }

    // MARK: - Jobs

    public func jobs(for printer: String, completed: Bool = false) async throws -> [PrintJob] {
        let which = completed ? "completed" : "not-completed"
        let r = await read("lpstat", ["-W", which, "-l", "-o", printer])
        if !r.ok && r.stdout.isEmpty {
            if r.output.isEmpty { return [] }
            throw CupsError.commandFailed(r)
        }
        var jobs = Parsers.jobs(r.stdout).filter { $0.printer == printer }
        if completed {
            for i in jobs.indices { jobs[i].state = .completed }
            return Array(jobs.reversed())
        }
        let q = await read("lpq", ["-P", printer])
        let titles = Parsers.lpqTitles(q.stdout)
        for i in jobs.indices {
            if let t = titles[jobs[i].number] {
                jobs[i].title = t.title
                if t.active && jobs[i].state != .held { jobs[i].state = .printing }
            }
        }
        return jobs
    }

    public func cancel(_ jobID: String) async throws { try await admin("cancel", [jobID]) }
    public func cancelAll(_ printer: String) async throws { try await admin("cancel", ["-a", printer]) }
    public func hold(_ jobID: String) async throws { try await admin("lp", ["-i", jobID, "-H", "hold"]) }
    public func release(_ jobID: String) async throws { try await admin("lp", ["-i", jobID, "-H", "resume"]) }
    public func reprint(_ jobID: String) async throws { try await admin("lp", ["-i", jobID, "-H", "restart"]) }
    public func move(_ jobID: String, to printer: String) async throws { try await admin("lpmove", [jobID, printer]) }

    // MARK: - Printing

    public static let testPageCandidates = [
        "/usr/share/cups/data/testprint",
        "/usr/share/cups/data/default-testpage.pdf",
    ]

    public func printFile(_ file: String, to printer: String, title: String, copies: Int = 1,
                      options: [String: String] = [:]) async throws -> String {
        var args = ["-d", printer, "-t", title]
        if copies > 1 { args += ["-n", String(copies)] }
        for (k, v) in options.sorted(by: { $0.key < $1.key }) { args += ["-o", "\(k)=\(v)"] }
        args.append(file)
        let r = await read("lp", args, log: true)
        guard r.ok else { throw CupsError.commandFailed(r) }
        return r.output
    }

    public func printTestPage(to printer: String) async throws -> String {
        if let path = Self.testPageCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return try await printFile(path, to: printer, title: "QueueMaster test page")
        }
        return try await printText("QueueMaster test page\n\(printer)\n\(Date().formatted())\n", to: printer)
    }

    public func printText(_ text: String, to printer: String, options: [String: String] = [:]) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queuemaster-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await printFile(url.path, to: printer, title: "QueueMaster text test", options: options)
    }

    // MARK: - Adding printers

    public func discoverDevices(timeout: Int = 5) async throws -> [Device] {
        let r = try await admin("lpinfo", ["-l", "-v", "--timeout", String(timeout)], timeout: TimeInterval(timeout + 30))
        return Parsers.devices(r.stdout).filter(\.isConcrete)
    }

    public func drivers() async throws -> [Driver] {
        let r = await read("lpinfo", ["-l", "-m"], timeout: 90)
        if !r.ok, Self.looksLikePermissionProblem(r) {
            let e = try await admin("lpinfo", ["-l", "-m"], timeout: 90)
            return Parsers.drivers(e.stdout)
        }
        guard r.ok else { throw CupsError.commandFailed(r) }
        return Parsers.drivers(r.stdout)
    }

    // MARK: - Server

    public func serverSettings() async throws -> ServerSettings {
        Parsers.cupsctl(try await readOrThrow("cupsctl", []))
    }

    public func setServerFlag(_ flag: String, _ on: Bool) async throws {
        try await admin("cupsctl", [(on ? "--" : "--no-") + flag])
    }

    public func setServerValue(_ key: String, _ value: String) async throws {
        try await admin("cupsctl", ["\(key)=\(value)"])
    }

    public static let logFiles = ["error_log", "access_log", "page_log"]

    public func readLog(_ name: String, lines: Int = 400, elevated: Bool = false) async throws -> String {
        let path = "/private/var/log/cups/\(name)"
        let altPath = "/var/log/cups/\(name)"
        let file = FileManager.default.fileExists(atPath: path) ? path : altPath
        let args = ["/usr/bin/tail", "-n", String(lines), file]
        let r: CommandResult
        if elevated { r = await Shell.runElevated(args) } else { r = await Shell.run(args) }
        onCommand?(r)
        if r.status == -128 { throw CupsError.cancelled }
        guard r.ok else { throw CupsError.commandFailed(r) }
        return r.stdout
    }
}
