import Foundation
import AppKit
import Security
import Observation
import CupsKit

/// Checks GitHub releases for a newer QueueMaster and installs its .pkg.
///
/// Trust comes from Apple code signing, not from GitHub: an update is only
/// installed if the .pkg is signed with a Developer ID Installer certificate
/// from the same team that signed this copy of the app, and Gatekeeper
/// accepts it (signed + notarized). Unsigned copies can't self-update.
@MainActor
@Observable
final class Updater {
    static let repo = "hoods-goods/queuemaster"

    struct Release: Equatable {
        var version: String
        var notes: String
        var pkgURL: URL
        var pkgName: String
        var pageURL: URL
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case verifying
        case installing
        case failed(String)
    }

    var phase: Phase = .idle
    /// Present the update sheet.
    var showSheet = false

    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updates.autoCheck") }
    }

    var lastCheck: Date? {
        didSet { UserDefaults.standard.set(lastCheck, forKey: "updates.lastCheck") }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The Apple team that signed this copy, or nil for unsigned/ad-hoc builds.
    let teamID: String? = Updater.ownTeamID()

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "updates.autoCheck") as? Bool ?? true
        lastCheck = UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date
    }

    // MARK: Checking

    /// Checks on launch at most once a day; only shows the sheet if there's an update.
    func checkInBackgroundIfDue() async {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 20 * 60 * 60 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        if userInitiated { showSheet = true }
        phase = .checking
        do {
            let release = try await Self.latestRelease()
            lastCheck = Date()
            if let release, Self.isNewer(release.version, than: currentVersion) {
                phase = .available(release)
                showSheet = true
            } else {
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    static func latestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("QueueMaster", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil } // no releases yet
        guard code == 200 else { throw CupsError.message("GitHub answered \(code) when checking for updates.") }

        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct GHRelease: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let r = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let pkg = r.assets.first(where: { $0.name.lowercased().hasSuffix(".pkg") }) else { return nil }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return Release(version: version, notes: r.body ?? "", pkgURL: pkg.browser_download_url,
                       pkgName: pkg.name, pageURL: r.html_url)
    }

    /// Numeric dotted-version comparison ("0.10.0" > "0.9.3").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    func install(_ release: Release) async {
        guard let teamID else {
            phase = .failed("This copy of QueueMaster isn't signed with a Developer ID, so it can't verify updates. Download the installer from the release page instead.")
            return
        }
        do {
            phase = .downloading
            let (tmp, resp) = try await URLSession.shared.download(from: release.pkgURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CupsError.message("Download failed.") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QueueMaster-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent(release.pkgName.replacingOccurrences(of: "/", with: "_"))
            try FileManager.default.moveItem(at: tmp, to: pkg)

            phase = .verifying
            try await Self.verify(pkg: pkg.path, teamID: teamID)

            phase = .installing
            // The admin script itself quits this copy and opens the new one once
            // the installer succeeds, so the relaunch doesn't depend on the
            // password helper reporting back (it sometimes never does, which
            // left the update sheet stuck on "Installing…").
            let app = "/Applications/QueueMaster.app"
            let pid = ProcessInfo.processInfo.processIdentifier
            let uid = getuid()
            let relaunchCmd = "sleep 2; kill -TERM \(pid) 2>/dev/null; sleep 2; kill -KILL \(pid) 2>/dev/null; /bin/launchctl asuser \(uid) /usr/bin/open \(Shell.quote(app))"
            let script = """
            /usr/sbin/installer -pkg \(Shell.quote(pkg.path)) -target / || exit 1
            /usr/bin/nohup /bin/bash -c \(Shell.quote(relaunchCmd)) </dev/null >/dev/null 2>&1 &
            exit 0
            """
            let r = await Shell.runElevated(["/bin/bash", "-c", script],
                                            prompt: "QueueMaster wants to install version \(release.version).")
            if r.status == -128 { phase = .available(release); return }
            guard r.ok else { throw CupsError.commandFailed(r) }
            try? FileManager.default.removeItem(at: dir)
            relaunch()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The .pkg must be signed by our team's Developer ID Installer
    /// certificate and accepted by Gatekeeper (which requires notarization).
    static func verify(pkg: String, teamID: String) async throws {
        let sig = await Shell.run(["/usr/sbin/pkgutil", "--check-signature", pkg])
        guard sig.ok, let pkgTeam = installerTeamID(fromPkgutil: sig.stdout) else {
            throw CupsError.message("The update isn't signed with a Developer ID Installer certificate, so it wasn't installed.")
        }
        guard pkgTeam == teamID else {
            throw CupsError.message("The update is signed by a different team (\(pkgTeam)), so it wasn't installed.")
        }
        let gk = await Shell.run(["/usr/sbin/spctl", "--assess", "--type", "install", "-vv", pkg])
        guard gk.ok else {
            throw CupsError.message("macOS Gatekeeper rejected the update (\(gk.output)), so it wasn't installed.")
        }
    }

    /// Pulls the team ID from `pkgutil --check-signature` output, e.g.
    /// "1. Developer ID Installer: Hoods Goods LLC (AB12CD34EF)".
    nonisolated static func installerTeamID(fromPkgutil text: String) -> String? {
        for line in text.components(separatedBy: "\n") where line.contains("Developer ID Installer:") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            let id = String(line[line.index(after: open)..<close])
            if id.count == 10, id.allSatisfy({ $0.isUppercase || $0.isNumber }) { return id }
        }
        return nil
    }

    nonisolated static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The admin script reopens the new version a couple of seconds after this
    /// copy quits (and quits it itself if this doesn't get the chance).
    private func relaunch() {
        NSApp.terminate(nil)
    }
}
