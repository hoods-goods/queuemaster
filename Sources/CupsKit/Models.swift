import Foundation

public enum PrinterState: Int, Sendable {
    case idle = 3, processing = 4, stopped = 5

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .processing: return "Printing"
        case .stopped: return "Paused"
        }
    }
}

public struct Printer: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var info: String = ""
    public var location: String = ""
    public var makeAndModel: String = ""
    public var deviceURI: String = ""
    public var state: PrinterState = .idle
    public var stateReasons: [String] = []
    /// Free-text message CUPS shows under the printer (e.g. a pause reason).
    public var stateMessage: String = ""
    public var isAccepting: Bool = true
    public var isShared: Bool = false
    public var isDefault: Bool = false
    public var isTemporary: Bool = false
    /// Every attribute `lpoptions -p` reported, for the raw view.
    public var attributes: [String: String] = [:]

    public init(name: String) { self.name = name }

    public var displayName: String { info.isEmpty ? name : info }
    public var isPaused: Bool { state == .stopped }

    /// Reasons worth showing (CUPS uses "none" for "nothing to report").
    public var meaningfulReasons: [String] {
        stateReasons.filter { $0 != "none" && !$0.isEmpty && $0 != "paused" }
    }

    public var hasProblem: Bool {
        meaningfulReasons.contains { $0.hasSuffix("-error") || $0.hasSuffix("-warning") || $0.contains("offline") }
    }

    public var scheme: String {
        deviceURI.components(separatedBy: ":").first?.lowercased() ?? ""
    }

    public var connectionLabel: String {
        switch scheme {
        case "usb": return "USB"
        case "ipp", "ipps": return "IPP"
        case "dnssd", "mdns": return "Bonjour"
        case "socket": return "AppSocket/JetDirect"
        case "lpd": return "LPD"
        case "smb": return "Windows (SMB)"
        case "": return "Unknown"
        default: return scheme.uppercased()
        }
    }
}

public enum JobState: String, Sendable {
    case pending, held, printing, completed
    public var label: String {
        switch self {
        case .pending: return "Waiting"
        case .held: return "Held"
        case .printing: return "Printing"
        case .completed: return "Done"
        }
    }
}

public struct PrintJob: Identifiable, Hashable, Sendable {
    /// Full CUPS id such as "DYMO_4XL-42".
    public var id: String
    public var number: Int
    public var printer: String
    public var user: String
    public var size: Int
    public var dateText: String
    public var title: String = ""
    public var state: JobState = .pending
    public var alerts: [String] = []

    public init(id: String, number: Int, printer: String, user: String, size: Int, dateText: String) {
        self.id = id; self.number = number; self.printer = printer
        self.user = user; self.size = size; self.dateText = dateText
    }
}

public enum OptionType: String, Sendable { case pickOne = "PickOne", pickMany = "PickMany", boolean = "Boolean" }

public struct OptionChoice: Hashable, Sendable, Identifiable {
    public var id: String { keyword }
    public var keyword: String
    public var label: String
    public init(keyword: String, label: String) { self.keyword = keyword; self.label = label.isEmpty ? keyword : label }
}

/// One printer option, normally from the printer's PPD.
public struct PrinterOption: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var type: OptionType = .pickOne
    public var group: String = "General"
    public var choices: [OptionChoice] = []
    /// The queue default stored in the PPD (what everyone gets).
    public var queueDefault: String?
    /// What your Mac account actually prints with (queue default plus your own override).
    public var current: String?
    /// Your account's own override from ~/.cups/lpoptions, if any.
    public var userValue: String?
    /// The PPD allows custom values ("Custom.WIDTHxHEIGHT" for page sizes).
    public var supportsCustom = false

    public init(key: String, label: String) { self.key = key; self.label = label.isEmpty ? key : label }

    public func label(for keyword: String?) -> String {
        guard let keyword else { return "—" }
        if let c = choices.first(where: { $0.keyword == keyword }) { return c.label }
        if keyword.hasPrefix("Custom.") { return "Custom " + keyword.dropFirst(7) }
        return keyword
    }
}

public struct OptionGroup: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var label: String
    public var options: [PrinterOption]

    public init(name: String, label: String, options: [PrinterOption]) {
        self.name = name; self.label = label; self.options = options
    }
}

public struct PrinterOptions: Sendable {
    public var groups: [OptionGroup]
    /// Where the option list came from: "PPD file", "PPD (via CUPS)" or "lpoptions".
    public var source: String
    /// The PPD text when we could read it (used to duplicate/rename a queue).
    public var ppdText: String?

    public var all: [PrinterOption] { groups.flatMap(\.options) }
}

public struct Device: Identifiable, Hashable, Sendable {
    public var id: String { uri }
    public var uri: String
    public var deviceClass: String
    public var info: String
    public var makeAndModel: String
    public var deviceID: String
    public var location: String

    /// lpinfo also lists bare schemes ("socket", "lpd") as templates; those
    /// aren't real devices.
    public var isConcrete: Bool { uri.contains(":") }
}

public struct Driver: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// The value passed to `lpadmin -m`.
    public var name: String
    public var makeAndModel: String
    public var language: String
    public var deviceID: String

    public static let everywhere = Driver(name: "everywhere", makeAndModel: "IPP Everywhere / AirPrint (driverless)",
                                          language: "", deviceID: "")
}

public struct ServerSettings: Sendable {
    public var values: [String: String]
    public func flag(_ key: String) -> Bool { values[key] == "1" || values[key]?.lowercased() == "yes" }
    public var sharePrinters: Bool { flag("_share_printers") }
    public var debugLogging: Bool { flag("_debug_logging") }
    public var remoteAdmin: Bool { flag("_remote_admin") }
    public var remoteAny: Bool { flag("_remote_any") }
    public var userCancelAny: Bool { flag("_user_cancel_any") }
    public var errorPolicy: String { values["ErrorPolicy"] ?? "stop-printer" }
}
