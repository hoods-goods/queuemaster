import Foundation

/// The outcome of one command QueueMaster ran.
public struct CommandResult: Identifiable, Sendable {
    public let id = UUID()
    public let command: [String]
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let elevated: Bool
    public let date: Date
    public let duration: TimeInterval

    public var ok: Bool { status == 0 }

    /// stdout and stderr together, trimmed.
    public var output: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The command as you would type it in Terminal.
    public var displayCommand: String {
        var args = command
        if let first = args.first { args[0] = (first as NSString).lastPathComponent }
        return (elevated ? "sudo " : "") + Shell.quote(args)
    }
}

public enum CupsError: LocalizedError, Sendable {
    case commandFailed(CommandResult)
    case cancelled
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let r):
            let msg = r.output
            return msg.isEmpty ? "\(r.displayCommand) exited with status \(r.status)." : msg
        case .cancelled:
            return "Administrator authorization was cancelled."
        case .message(let m):
            return m
        }
    }
}

public enum Shell {
    // MARK: Quoting

    private static let safe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")

    /// POSIX-shell quoting for one argument.
    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func quote(_ args: [String]) -> String {
        args.map { quote($0) }.joined(separator: " ")
    }

    /// Splits a command line typed by the user into arguments, honouring
    /// single quotes, double quotes and backslash escapes.
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var inWord = false
        var quote: Character? = nil
        var escape = false
        for ch in line {
            if escape { cur.append(ch); escape = false; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                else if ch == "\\" && q == "\"" { escape = true }
                else { cur.append(ch) }
                continue
            }
            switch ch {
            case "\\": escape = true; inWord = true
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t", "\n":
                if inWord { args.append(cur); cur = ""; inWord = false }
            default: cur.append(ch); inWord = true
            }
        }
        if inWord { args.append(cur) }
        return args
    }

    // MARK: Running

    /// Runs a command and waits for it, with a timeout. stdin is /dev/null,
    /// so a tool that wants to prompt for a password fails instead of hanging.
    public static func run(_ args: [String], timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(args, timeout: timeout))
            }
        }
    }

    /// Runs a command as root through the standard macOS administrator
    /// password prompt (AppleScript's "with administrator privileges").
    /// macOS remembers the authorization for a few minutes, so a burst of
    /// changes only asks once.
    public static func runElevated(_ args: [String], timeout: TimeInterval = 300,
                                   prompt: String = "QueueMaster wants to change your printer settings.") async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runElevatedSync(args, timeout: timeout, prompt: prompt))
            }
        }
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func runElevatedSync(_ args: [String], timeout: TimeInterval, prompt: String) -> CommandResult {
        let shellCommand = quote(args) + " 2>&1"
        let script = "do shell script \(appleScriptString(shellCommand)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let r = runSync(["/usr/bin/osascript", "-e", script], timeout: timeout)

        // osascript reports failures as "0:123: execution error: <text> (<code>)".
        var err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var status = r.status
        if !r.ok {
            if err.contains("(-128)") {
                return CommandResult(command: args, status: -128, stdout: "", stderr: CupsError.cancelled.errorDescription!,
                                     elevated: true, date: r.date, duration: r.duration)
            }
            if let range = err.range(of: "execution error: ") { err = String(err[range.upperBound...]) }
            if let m = err.range(of: #" \((-?\d+)\)$"#, options: .regularExpression) {
                let code = err[m].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                status = Int32(code) ?? status
                err.removeSubrange(m)
            }
        }
        // do shell script turns newlines into carriage returns.
        let out = r.stdout.replacingOccurrences(of: "\r", with: "\n")
        err = err.replacingOccurrences(of: "\r", with: "\n")
        return CommandResult(command: args, status: status, stdout: out, stderr: r.ok ? "" : err,
                             elevated: true, date: r.date, duration: r.duration)
    }

    static func runSync(_ args: [String], timeout: TimeInterval) -> CommandResult {
        let start = Date()
        guard let exe = args.first else {
            return CommandResult(command: args, status: 127, stdout: "", stderr: "No command.",
                                 elevated: false, date: start, duration: 0)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        // English messages so the parsers can rely on them; UTF-8 for names.
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch {
            return CommandResult(command: args, status: 127, stdout: "", stderr: error.localizedDescription,
                                 elevated: false, date: start, duration: 0)
        }

        // Read both pipes concurrently so a chatty command can't fill one
        // pipe and deadlock while we wait on the other.
        let lock = NSLock()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock(); group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock(); group.leave()
        }
        var timedOut = false
        let killer = DispatchWorkItem {
            if p.isRunning { timedOut = true; p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()

        var stderr = String(decoding: errData, as: UTF8.self)
        if timedOut { stderr += (stderr.isEmpty ? "" : "\n") + "Timed out after \(Int(timeout)) seconds." }
        return CommandResult(command: args, status: timedOut ? 124 : p.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self), stderr: stderr,
                             elevated: false, date: start, duration: Date().timeIntervalSince(start))
    }
}
