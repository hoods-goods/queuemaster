import Foundation

/// Parsers for the text the CUPS command-line tools print. Kept free of
/// side effects so they can be tested against captured output.
public enum Parsers {

    // MARK: - key=value option strings (lpoptions -p, ~/.cups/lpoptions)

    /// Parses `copies=1 printer-info='Shipping desk' printer-location` style
    /// strings. CUPS wraps values containing spaces in quotes but doesn't
    /// escape quotes inside them, so a closing quote only counts when what
    /// follows looks like the next option (or the end of the line).
    public static func optionTokens(_ line: String) -> [(key: String, value: String?)] {
        let s = Array(line)
        var i = 0
        var result: [(key: String, value: String?)] = []

        func isKeyChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." }

        /// True when position `j` starts something that looks like the next option.
        func looksLikeNextOption(at j: Int) -> Bool {
            var k = j
            while k < s.count, s[k] == " " { k += 1 }
            if k >= s.count { return true }
            let start = k
            while k < s.count, isKeyChar(s[k]) { k += 1 }
            if k == start { return false }
            if k < s.count, s[k] == "=" { return true }
            // A bare key (no value) like "printer-location": accept only if it
            // has a dash, which plain words in a description rarely do.
            let word = String(s[start..<k])
            return word.contains("-") && (k >= s.count || s[k] == " ")
        }

        while i < s.count {
            while i < s.count, s[i] == " " { i += 1 }
            if i >= s.count { break }
            var key = ""
            while i < s.count, s[i] != "=", s[i] != " " { key.append(s[i]); i += 1 }
            if i >= s.count || s[i] == " " { result.append((key: key, value: nil)); continue }
            i += 1 // skip '='
            var value = ""
            if i < s.count, s[i] == "'" || s[i] == "\"" {
                let q = s[i]; i += 1
                var closed = false
                while i < s.count {
                    let c = s[i]
                    if c == "\\", i + 1 < s.count { value.append(s[i + 1]); i += 2; continue }
                    if c == q, looksLikeNextOption(at: i + 1) { i += 1; closed = true; break }
                    value.append(c); i += 1
                }
                _ = closed
            } else {
                while i < s.count, s[i] != " " {
                    if s[i] == "\\", i + 1 < s.count { value.append(s[i + 1]); i += 2; continue }
                    value.append(s[i]); i += 1
                }
            }
            result.append((key: key, value: value))
        }
        return result
    }

    public static func optionDictionary(_ line: String) -> [String: String] {
        var d: [String: String] = [:]
        for (k, v) in optionTokens(line) { d[k] = v ?? "" }
        return d
    }

    /// Fills a Printer from `lpoptions -p NAME` output.
    public static func applyLpoptions(_ text: String, to p: inout Printer) {
        let attrs = optionDictionary(text.trimmingCharacters(in: .whitespacesAndNewlines))
        p.attributes = attrs
        p.info = attrs["printer-info"] ?? p.info
        p.location = attrs["printer-location"] ?? p.location
        p.makeAndModel = attrs["printer-make-and-model"] ?? p.makeAndModel
        p.deviceURI = attrs["device-uri"] ?? p.deviceURI
        if let st = attrs["printer-state"], let n = Int(st), let state = PrinterState(rawValue: n) { p.state = state }
        if let r = attrs["printer-state-reasons"] { p.stateReasons = r.split(separator: ",").map(String.init) }
        if let a = attrs["printer-is-accepting-jobs"] { p.isAccepting = a == "true" }
        if let sh = attrs["printer-is-shared"] { p.isShared = sh == "true" }
        if let t = attrs["printer-is-temporary"] { p.isTemporary = t == "true" }
    }

    /// Per-printer user options from the text of ~/.cups/lpoptions.
    public static func userOptionsFile(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Dest ") || line.hasPrefix("Default ") else { continue }
            let rest = line.drop(while: { $0 != " " }).dropFirst()
            let name = String(rest.prefix(while: { $0 != " " }))
            let opts = String(rest.dropFirst(name.count))
            if name.contains("/") { continue } // instances aren't managed here
            out[name] = optionDictionary(opts)
        }
        return out
    }

    // MARK: - lpstat

    /// `lpstat -e`: one destination per line.
    public static func destinations(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    /// `lpstat -d`.
    public static func defaultDestination(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: "default destination: ") {
                let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    public struct PrinterStatusLine: Sendable {
        public var message: String = ""
        public var nowPrinting: String?
        public var enabled = true
    }

    /// `lpstat -p`: the status line and indented message for each printer.
    public static func printerStatus(_ text: String) -> [String: PrinterStatusLine] {
        var out: [String: PrinterStatusLine] = [:]
        var current: String?
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("printer ") {
                let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }
                let name = String(parts[1])
                var st = PrinterStatusLine()
                st.enabled = !raw.contains(" disabled since ")
                if let r = raw.range(of: "now printing ") {
                    let job = raw[r.upperBound...].prefix(while: { $0 != " " })
                    st.nowPrinting = job.hasSuffix(".") ? String(job.dropLast()) : String(job)
                }
                out[name] = st
                current = name
            } else if raw.hasPrefix("\t") || raw.hasPrefix(" "), let name = current {
                let msg = raw.trimmingCharacters(in: .whitespaces)
                guard !msg.isEmpty else { continue }
                if msg.hasPrefix("Form mounted") || msg.hasPrefix("Content types") { current = nil; continue }
                var st = out[name]!
                st.message = st.message.isEmpty ? msg : st.message + "\n" + msg
                out[name] = st
            }
        }
        return out
    }

    /// `lpstat -a`: whether each printer accepts jobs, and the reject reason.
    public static func acceptance(_ text: String) -> [String: (accepting: Bool, reason: String)] {
        var out: [String: (Bool, String)] = [:]
        var current: String?
        for raw in text.components(separatedBy: "\n") {
            if raw.isEmpty { continue }
            if raw.hasPrefix("\t") || raw.hasPrefix(" ") {
                if let name = current, var v = out[name] {
                    let msg = raw.trimmingCharacters(in: .whitespaces)
                    v.1 = v.1.isEmpty ? msg : v.1 + "\n" + msg
                    out[name] = v
                }
                continue
            }
            let name = String(raw.prefix(while: { $0 != " " }))
            out[name] = (!raw.contains(" not accepting "), "")
            current = name
        }
        return out.mapValues { (accepting: $0.0, reason: $0.1) }
    }

    /// `lpstat -l -o` (optionally with -W): jobs with their alerts.
    public static func jobs(_ text: String) -> [PrintJob] {
        var jobs: [PrintJob] = []
        for raw in text.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if raw.hasPrefix("\t") || raw.hasPrefix(" ") {
                guard !jobs.isEmpty else { continue }
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("Alerts:") {
                    let alerts = line.dropFirst("Alerts:".count).split(separator: " ").map(String.init).filter { $0 != "none" }
                    jobs[jobs.count - 1].alerts = alerts
                    if alerts.contains(where: { $0.contains("hold") || $0 == "job-held" }) {
                        jobs[jobs.count - 1].state = .held
                    }
                }
                continue
            }
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let dash = parts[0].lastIndex(of: "-"),
                  let number = Int(parts[0][parts[0].index(after: dash)...]) else { continue }
            let printer = String(parts[0][..<dash])
            let size = Int(parts[2]) ?? 0
            let date = parts.count > 3 ? parts[3...].joined(separator: " ") : ""
            jobs.append(PrintJob(id: parts[0], number: number, printer: printer, user: parts[1], size: size, dateText: date))
        }
        return jobs
    }

    /// `lpq -P NAME`: job titles and which job is active, keyed by job number.
    public static func lpqTitles(_ text: String) -> [Int: (title: String, active: Bool)] {
        var out: [Int: (String, Bool)] = [:]
        var inTable = false
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("Rank") { inTable = true; continue }
            guard inTable else { continue }
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 5, let job = Int(parts[2]) else { continue }
            var end = parts.count
            if parts[end - 1] == "bytes" || parts[end - 1] == "byte" { end -= 2 }
            let title = end > 3 ? parts[3..<end].joined(separator: " ") : ""
            out[job] = (title, parts[0] == "active")
        }
        return out.mapValues { (title: $0.0, active: $0.1) }
    }

    // MARK: - lpinfo -l

    /// Parses the block format of `lpinfo -l -m` / `lpinfo -l -v`.
    static func lpinfoBlocks(_ text: String, header: String) -> [[String: String]] {
        var blocks: [[String: String]] = []
        for raw in text.components(separatedBy: "\n") {
            let isHeader = raw.hasPrefix(header + ":")
            let line = isHeader ? String(raw.dropFirst(header.count + 1)) : raw
            guard let eq = line.range(of: " = ") ?? line.range(of: " =") else { continue }
            let key = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            if isHeader { blocks.append([:]) }
            guard !blocks.isEmpty else { continue }
            blocks[blocks.count - 1][key] = value
        }
        return blocks
    }

    public static func drivers(_ text: String) -> [Driver] {
        lpinfoBlocks(text, header: "Model").compactMap { b in
            guard let name = b["name"], !name.isEmpty else { return nil }
            return Driver(name: name, makeAndModel: b["make-and-model"] ?? name,
                          language: b["natural_language"] ?? "", deviceID: b["device-id"] ?? b["device_id"] ?? "")
        }
    }

    public static func devices(_ text: String) -> [Device] {
        lpinfoBlocks(text, header: "Device").compactMap { b in
            guard let uri = b["uri"], !uri.isEmpty else { return nil }
            return Device(uri: uri, deviceClass: b["class"] ?? "", info: b["info"] ?? "",
                          makeAndModel: b["make-and-model"] ?? "", deviceID: b["device-id"] ?? "",
                          location: b["location"] ?? "")
        }
    }

    // MARK: - lpoptions -l

    /// `lpoptions -p NAME -l`: options with keyword-only choices, `*` marking
    /// the current value.
    public static func optionList(_ text: String) -> [PrinterOption] {
        var out: [PrinterOption] = []
        for raw in text.components(separatedBy: "\n") {
            guard let sep = raw.range(of: ": ", options: .backwards) else { continue }
            let head = raw[..<sep.lowerBound]
            let choicesText = raw[sep.upperBound...]
            let key: String, label: String
            if let slash = head.firstIndex(of: "/") {
                key = String(head[..<slash]); label = String(head[head.index(after: slash)...])
            } else { key = String(head); label = key }
            var opt = PrinterOption(key: key, label: label)
            for token in choicesText.split(separator: " ") {
                var kw = String(token)
                if kw.hasPrefix("*") { kw.removeFirst(); opt.current = kw }
                if kw.hasPrefix("Custom.") { opt.supportsCustom = true; continue }
                opt.choices.append(OptionChoice(keyword: kw, label: kw))
            }
            if Set(opt.choices.map(\.keyword)) == ["True", "False"] { opt.type = .boolean }
            out.append(opt)
        }
        return out
    }

    // MARK: - PPD

    /// Options to leave out of the editor: duplicates of PageSize or
    /// internal settings no one edits by hand.
    static let hiddenPPDOptions: Set<String> = ["PageRegion"]

    /// Parses UI options and groups from a PPD file.
    public static func ppd(_ text: String) -> [OptionGroup] {
        var groups: [OptionGroup] = []
        var groupIndex: [String: Int] = [:]
        var groupStack: [(name: String, label: String)] = []
        var option: PrinterOption?
        var inQuote = false

        func group(named name: String, label: String) -> Int {
            if let i = groupIndex[name] { return i }
            groups.append(OptionGroup(name: name, label: label, options: []))
            groupIndex[name] = groups.count - 1
            return groups.count - 1
        }
        func splitNameLabel<S: StringProtocol>(_ s: S) -> (String, String) {
            if let slash = s.firstIndex(of: "/") {
                return (String(s[..<slash]).trimmingCharacters(in: .whitespaces),
                        String(s[s.index(after: slash)...]).trimmingCharacters(in: .whitespaces))
            }
            let n = String(s).trimmingCharacters(in: .whitespaces)
            return (n, n)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
            // Skip the body of multi-line quoted values.
            if inQuote {
                if line.filter({ $0 == "\"" }).count % 2 == 1 { inQuote = false }
                continue
            }
            guard line.hasPrefix("*"), !line.hasPrefix("*%") else { continue }
            // Only quotes in the value (after the first colon) open a
            // multi-line string; labels like 2.25x4.00" contain stray quotes.
            if let colon = line.firstIndex(of: ":"),
               line[line.index(after: colon)...].filter({ $0 == "\"" }).count % 2 == 1 { inQuote = true }

            if line.hasPrefix("*OpenGroup:") {
                let (n, l) = splitNameLabel(line.dropFirst("*OpenGroup:".count))
                groupStack.append((n, l))
                continue
            }
            if line.hasPrefix("*CloseGroup") { _ = groupStack.popLast(); continue }

            if line.hasPrefix("*OpenUI ") || line.hasPrefix("*JCLOpenUI ") {
                let afterTag = line.drop(while: { $0 != " " }).dropFirst()
                guard afterTag.hasPrefix("*"), let colon = afterTag.lastIndex(of: ":") else { continue }
                let (key, label) = splitNameLabel(afterTag.dropFirst()[..<colon])
                var opt = PrinterOption(key: key, label: label)
                opt.type = OptionType(rawValue: afterTag[afterTag.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? .pickOne
                let g = groupStack.last ?? (name: "General", label: "General")
                opt.group = g.name
                option = opt
                continue
            }
            if line.hasPrefix("*CloseUI") || line.hasPrefix("*JCLCloseUI") {
                if let opt = option, !hiddenPPDOptions.contains(opt.key) {
                    let g = groupStack.last ?? (name: "General", label: "General")
                    let gi = group(named: opt.group, label: opt.group == g.name ? g.label : opt.group)
                    groups[gi].options.append(opt)
                }
                option = nil
                continue
            }
            guard var opt = option else { continue }

            if line.hasPrefix("*Default\(opt.key):") {
                opt.queueDefault = line.dropFirst("*Default\(opt.key):".count).trimmingCharacters(in: .whitespaces)
                option = opt
                continue
            }
            // Choice line: *Key choice/Label: "..."
            let prefix = "*\(opt.key) "
            if line.hasPrefix(prefix) {
                let rest = line.dropFirst(prefix.count)
                guard let colon = rest.firstIndex(of: ":") else { continue }
                let (kw, label) = splitNameLabel(rest[..<colon])
                if kw == "Custom" { opt.supportsCustom = true }
                else if !opt.choices.contains(where: { $0.keyword == kw }) {
                    opt.choices.append(OptionChoice(keyword: kw, label: label))
                }
                option = opt
                continue
            }
            if line.hasPrefix("*CustomPageSize") && opt.key == "PageSize" {
                opt.supportsCustom = true; option = opt
            }
        }
        // Default values sometimes appear outside the OpenUI block.
        for raw in text.components(separatedBy: .newlines) where raw.hasPrefix("*Default") {
            let body = raw.dropFirst("*Default".count)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[..<colon])
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            for gi in groups.indices {
                if let oi = groups[gi].options.firstIndex(where: { $0.key == key }), groups[gi].options[oi].queueDefault == nil {
                    groups[gi].options[oi].queueDefault = value
                }
            }
        }
        // Custom page sizes are declared outside the PageSize block.
        if text.contains("*CustomPageSize True") {
            for gi in groups.indices {
                for oi in groups[gi].options.indices where groups[gi].options[oi].key == "PageSize" {
                    groups[gi].options[oi].supportsCustom = true
                }
            }
        }
        return groups.filter { !$0.options.isEmpty }
    }

    /// Decodes PPD bytes using the encoding the file declares.
    public static func decodePPD(_ data: Data) -> String {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.contains("*LanguageEncoding: ISOLatin1") || head.contains("*LanguageEncoding: WindowsANSI") {
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - cupsctl

    public static func cupsctl(_ text: String) -> ServerSettings {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return ServerSettings(values: values)
    }
}
