import SwiftUI
import AppKit

struct UpdateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var updater: Updater { model.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("You have version \(updater.currentVersion).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            switch updater.phase {
            case .available(let r):
                if !r.notes.isEmpty {
                    ScrollView {
                        Text(r.notes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                if updater.teamID == nil {
                    Text("This copy isn't signed with a Developer ID, so it can't install updates itself. Download the installer from the release page.")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .failed(let msg):
                Text(msg).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case .checking, .downloading, .verifying, .installing:
                ProgressView().controlSize(.small)
            default:
                EmptyView()
            }

            HStack {
                if case .available(let r) = updater.phase {
                    Button("Release Page") { NSWorkspace.shared.open(r.pageURL) }
                }
                Spacer()
                Button(isBusy ? "Hide" : "Close") { updater.showSheet = false; dismiss() }
                if case .available(let r) = updater.phase, updater.teamID != nil {
                    Button("Install and Relaunch") { Task { await updater.install(r) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                if case .failed = updater.phase {
                    Button("Try Again") { Task { await updater.check(userInitiated: true) } }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "QueueMaster is up to date"
        case .available(let r): return "QueueMaster \(r.version) is available"
        case .downloading: return "Downloading…"
        case .verifying: return "Checking the installer's signature…"
        case .installing: return "Installing…"
        case .failed: return "Couldn't update"
        }
    }
}
