import SwiftUI
import AppKit
import MetricKit
import CoreSpotlight
import ServiceManagement

// MARK: - Version and release notes

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// The CHANGELOG.md section for one version, as markdown.
    static func notes(for version: String, in changelog: String? = nil) -> String? {
        let text = changelog ?? (Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        return Changelog.section(for: version, in: text)
    }

    private static let seenKey = "lastSeenVersion"
    /// True once per update, never on a first install.
    static func shouldShowWhatsNew() -> Bool {
        let seen = UserDefaults.standard.string(forKey: seenKey)
        guard let seen else { UserDefaults.standard.set(version, forKey: seenKey); return false }
        return seen != version && notes(for: version) != nil
    }
    static func markWhatsNewSeen() { UserDefaults.standard.set(version, forKey: seenKey) }
}

struct WhatsNewView: View {
    var done: () -> Void
    private var sections: [(String, [String])] {
        var out: [(String, [String])] = []
        for line in (AppInfo.notes(for: AppInfo.version) ?? "").components(separatedBy: "\n") {
            if line.hasPrefix("### ") { out.append((String(line.dropFirst(4)), [])) }
            else if line.hasPrefix("- "), !out.isEmpty { out[out.count - 1].1.append(String(line.dropFirst(2))) }
        }
        return out
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What's new in Minute").font(.title.weight(.semibold))
                Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.0) { title, items in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.headline)
                            ForEach(items, id: \.self) { i in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text((try? AttributedString(markdown: i)) ?? AttributedString(i)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Continue") { done() }.glassButton(prominent: true).keyboardShortcut(.defaultAction).controlSize(.large) }
        }
        .padding(28).frame(width: 560, height: 520)
    }
}

// MARK: - Knowing when Minute closed unexpectedly (stays on this Mac)

/// A flag file exists while Minute runs and is removed on any normal exit (quit, deploy, log out). If it is still there at launch, the last run ended badly.
/// Uncaught exceptions and macOS crash/hang reports (MetricKit) are written to ~/.mom/crashes for "Copy Diagnostics".
@MainActor
final class Stability: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = Stability()
    @Published var closedUnexpectedly = false
    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mom/crashes")
    nonisolated static let flag = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mom/running.flag")
    private var termSource: DispatchSourceSignal?

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Self.flag.path) { closedUnexpectedly = true; Self.note("previous run ended without a clean exit") }
        try? "\(AppInfo.version) \(AppInfo.build) pid \(getpid())\n".write(to: Self.flag, atomically: true, encoding: .utf8)
        NSSetUncaughtExceptionHandler { e in
            let text = "\(Date())\n\(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.joined(separator: "\n")
            try? text.write(to: Stability.dir.appendingPathComponent("exception-\(Int(Date().timeIntervalSince1970)).txt"), atomically: true, encoding: .utf8)
        }
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { Stability.cleanExit(); exit(0) }
        src.resume(); termSource = src
        MXMetricManager.shared.add(self)
    }

    nonisolated static func cleanExit() { try? FileManager.default.removeItem(at: flag) }
    nonisolated static func note(_ s: String) {
        let f = dir.appendingPathComponent("events.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) v\(AppInfo.version) \(s)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let kinds = [(p.crashDiagnostics?.count ?? 0, "crash"), (p.hangDiagnostics?.count ?? 0, "hang"), (p.cpuExceptionDiagnostics?.count ?? 0, "cpu"), (p.diskWriteExceptionDiagnostics?.count ?? 0, "disk")]
            guard kinds.contains(where: { $0.0 > 0 }) else { continue }
            try? p.jsonRepresentation().write(to: Self.dir.appendingPathComponent("macos-report-\(Int(Date().timeIntervalSince1970)).json"))
            Self.note("macOS report: " + kinds.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        }
    }
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}

    func dismiss() { closedUnexpectedly = false }
    func showFolder() { NSWorkspace.shared.activateFileViewerSelecting([Self.dir]) }
}

struct CrashBanner: View {
    @ObservedObject var s: Stability
    var body: some View {
        if s.closedUnexpectedly {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Minute closed unexpectedly last time. Any recording in progress can be recovered from the sidebar.").font(.callout)
                Spacer()
                Button("Show Details") { s.showFolder() }.buttonStyle(.borderless)
                Button("Dismiss") { s.dismiss() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(Color.orange.opacity(0.12))
        }
    }
}

// MARK: - minute:// links (Shortcuts, scripts)

enum Links {
    /// minute://start, minute://stop, minute://flag/action|decision|important, minute://open. Start and stop ask first, so a web page cannot begin a recording silently.
    @MainActor static func handle(_ url: URL, r: Recorder, showRecorder: @escaping () -> Void, showLibrary: @escaping () -> Void) {
        guard url.scheme == "minute" else { return }
        let host = url.host ?? ""
        switch host {
        case "start": if !r.isRecording && !r.isBusy { MinuteApp.confirmToggle(r, then: showRecorder) }
        case "stop": if r.isRecording { MinuteApp.confirmToggle(r, then: showRecorder) }
        case "flag":
            let kind = MarkKind(rawValue: url.pathComponents.dropFirst().first ?? "") ?? .important
            r.addMark(kind)
        default: showLibrary()
        }
    }
}

// MARK: - System integration: open at login, Spotlight

enum Login {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) { do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { Stability.note("login item: \(error.localizedDescription)") } }
}

enum SpotlightIndex {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "spotlight") }
        set { UserDefaults.standard.set(newValue, forKey: "spotlight") }
    }

    /// Meeting titles and topics become searchable from Spotlight. Stored by macOS on this Mac only; off by default because minutes can be confidential.
    static func update(_ meetings: [Meeting]) {
        let index = CSSearchableIndex.default()
        guard enabled else { index.deleteSearchableItems(withDomainIdentifiers: ["meetings"]) { _ in }; return }
        let items = meetings.filter { $0.data != nil }.map { m -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: .content)
            a.title = m.title; a.contentCreationDate = m.date
            a.contentDescription = (m.data?.topics ?? []).prefix(3).joined(separator: " ")
            a.keywords = (m.data?.telkomsel_names ?? []) + (m.data?.third_party_names ?? [])
            return CSSearchableItem(uniqueIdentifier: m.dir.path, domainIdentifier: "meetings", attributeSet: a)
        }
        index.deleteSearchableItems(withDomainIdentifiers: ["meetings"]) { _ in index.indexSearchableItems(items) { _ in } }
    }
}

extension Notification.Name {
    static let openMeeting = Notification.Name("minute.openMeeting")
    static let showWhatsNew = Notification.Name("minute.showWhatsNew")
}
