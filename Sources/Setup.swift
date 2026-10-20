import SwiftUI
import AppKit
import AVFoundation
import UserNotifications

// MARK: - Where meetings are stored

enum Storage {
    static let key = "rootPath"
    static let defaultRoot = home.appendingPathComponent("Documents/MoM")

    static var root: URL {
        get { (UserDefaults.standard.string(forKey: key)).map { URL(fileURLWithPath: $0) } ?? defaultRoot }
        set { UserDefaults.standard.set(newValue.path, forKey: key); writeConfig(["root": newValue.path]) }
    }

    static var setupDone: Bool {
        get { UserDefaults.standard.bool(forKey: "setupDone") }
        set { UserDefaults.standard.set(newValue, forKey: "setupDone") }
    }

    static var deleteAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "deleteAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "deleteAudio"); writeConfig(["delete_audio": newValue]) }
    }

    /// The pipeline reads the same settings from ~/.mom/config.json.
    static func writeConfig(_ patch: [String: Any]) {
        let url = home.appendingPathComponent(".mom/config.json")
        var cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        for (k, v) in patch { cfg[k] = v }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }

    struct Place: Identifiable, Hashable {
        var id: String { url.path }
        let name: String, detail: String, symbol: String, url: URL, cloud: Bool
    }

    /// This Mac, plus any cloud folder already set up on it (iCloud Drive, OneDrive, Google Drive, Dropbox...).
    static func places() -> [Place] {
        var out = [Place(name: "This Mac", detail: "Documents › MoM", symbol: "laptopcomputer", url: defaultRoot, cloud: false)]
        let fm = FileManager.default
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) {
            out.append(Place(name: "iCloud Drive", detail: "iCloud Drive › Minute", symbol: "icloud", url: icloud.appendingPathComponent("Minute"), cloud: true))
        }
        let cs = home.appendingPathComponent("Library/CloudStorage")
        let entries = ((try? fm.contentsOfDirectory(at: cs, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.contains("(") && !$0.lastPathComponent.contains("Temp") && !$0.lastPathComponent.contains("SharedLibraries") }   // real providers only, not stray files or dated backups
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for d in entries {
            let n = d.lastPathComponent
            let nice = { (t: String) in t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression) }
            let pretty = n.hasPrefix("OneDrive-") ? "OneDrive · " + nice(String(n.dropFirst(9)))
                : n.hasPrefix("OneDrive") ? "OneDrive"
                : n.hasPrefix("GoogleDrive") ? "Google Drive" : n.hasPrefix("Dropbox") ? "Dropbox" : n
            let inside = n.hasPrefix("GoogleDrive") ? d.appendingPathComponent("My Drive/Minute") : d.appendingPathComponent("Minute")
            out.append(Place(name: pretty, detail: "Syncs to the cloud", symbol: "cloud", url: inside, cloud: true))
        }
        return out
    }

    /// Create the folder and prove we can write there (this is what triggers macOS's one-time folder access prompt).
    static func verifyWritable(_ url: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let t = url.appendingPathComponent(".minute-write-test")
            try "ok".write(to: t, atomically: true, encoding: .utf8)
            try fm.removeItem(at: t)
            return nil
        } catch {
            return "Minute can't write to this folder (\(error.localizedDescription)). If macOS asked for access, choose Allow; otherwise enable Minute under System Settings → Privacy & Security → Files and Folders (or Full Disk Access)."
        }
    }

    static func meetingFolders(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let rx = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}_\d{4}"#)
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
            $0.hasDirectoryPath && rx.firstMatch(in: $0.lastPathComponent, range: NSRange($0.lastPathComponent.startIndex..., in: $0.lastPathComponent)) != nil
        }
    }
}

/// Moves the whole library, not only new meetings, so documents never end up scattered across two places.
@MainActor
final class StorageMover: ObservableObject {
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var error: String?

    func change(to newRoot: URL, from old: URL = Storage.root, commit: Bool = true, completion: @escaping (Bool) -> Void) {
        let a = old.standardizedFileURL.path, b = newRoot.standardizedFileURL.path
        error = nil
        if a == b { completion(true); return }
        if b.hasPrefix(a + "/") || a.hasPrefix(b + "/") { error = "Choose a folder that is not inside the current one."; completion(false); return }
        if let e = Storage.verifyWritable(newRoot) { error = e; completion(false); return }
        busy = true; progress = 0; status = "Preparing…"
        Task {
            let folders = Storage.meetingFolders(in: old)
            var failed: [String] = []
            for (i, f) in folders.enumerated() {
                status = "Moving \(i + 1) of \(folders.count)…"
                let name = f.lastPathComponent
                let result: String? = await Task.detached {
                    let fm = FileManager.default
                    var dest = newRoot.appendingPathComponent(name)
                    var n = 2
                    while fm.fileExists(atPath: dest.path) { dest = newRoot.appendingPathComponent("\(name)-\(n)"); n += 1 }
                    do { try fm.moveItem(at: f, to: dest); return nil } catch { return "\(name): \(error.localizedDescription)" }
                }.value
                if let r = result { failed.append(r) }
                progress = Double(i + 1) / Double(max(1, folders.count))
            }
            if failed.isEmpty {
                if commit { Storage.root = newRoot }
                // tidy the old location if nothing is left in it
                let rest = ((try? FileManager.default.contentsOfDirectory(atPath: old.path)) ?? []).filter { $0 != ".DS_Store" }
                if rest.isEmpty && commit { try? FileManager.default.removeItem(at: old) }
                status = folders.isEmpty ? "Location set." : "Moved \(folders.count) meeting\(folders.count == 1 ? "" : "s")."
            } else {
                // keep the old location as the source of truth so nothing is split
                error = "Some meetings could not be moved, so the location was not changed:\n" + failed.joined(separator: "\n")
            }
            busy = false
            completion(failed.isEmpty)
        }
    }
}

// MARK: - Shared location picker

struct LocationPicker: View {
    @Binding var selection: URL
    @State private var places = Storage.places()
    var body: some View {
        VStack(spacing: 8) {
            ForEach(places) { p in
                Button { selection = p.url } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.symbol).font(.title3).frame(width: 28).foregroundStyle(p.cloud ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.body.weight(.medium))
                            Text(p.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection.standardizedFileURL.path == p.url.standardizedFileURL.path { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                    .padding(12).contentShape(Rectangle())
                    .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: selection.standardizedFileURL.path == p.url.standardizedFileURL.path ? Color.accentColor.opacity(0.25) : nil, interactive: true)
                }.buttonStyle(.plain)
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                panel.prompt = "Choose"; panel.message = "Choose where Minute saves meetings and minutes."
                if panel.runModal() == .OK, let u = panel.url { selection = u.lastPathComponent == "MoM" || u.lastPathComponent == "Minute" ? u : u.appendingPathComponent("Minute") }
            } label: {
                HStack { Image(systemName: "folder.badge.plus").frame(width: 28); Text("Choose another folder…"); Spacer() }
                    .padding(12).contentShape(Rectangle())
                    .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
            }.buttonStyle(.plain)
            if !places.contains(where: { $0.url.standardizedFileURL.path == selection.standardizedFileURL.path }) {
                Label(selection.path.replacingOccurrences(of: home.path, with: "~"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { places = Storage.places() }
    }
}

// MARK: - First-run setup

struct SetupView: View {
    @ObservedObject var r: Recorder
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mover = StorageMover()
    @State private var step = Int(ProcessInfo.processInfo.environment["MINUTE_SETUPSTEP"] ?? "") ?? 0
    @State private var choice = Storage.root
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var sysOK = false
    @State private var deleteAudio = Storage.deleteAudio
    @State private var pendingMove = 0
    @State private var allReady = false
    @State private var folderOK = false
    @State private var notifOK = false
    @State private var pdfOK = false
    @State private var pdfBusy = false
    @State private var allowing = false
    @State private var permError: String?
    private let wordInstalled = FileManager.default.fileExists(atPath: "/Applications/Microsoft Word.app")

    var cloudChosen: Bool { Storage.places().first { $0.url.standardizedFileURL.path == choice.standardizedFileURL.path }?.cloud ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) { ForEach(0..<6) { i in Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4) } }
                .padding(.horizontal, 40).padding(.top, 26).animation(.spring(duration: 0.4), value: step)
            ZStack {
                Group {
                    switch step {
                    case 0: WelcomePage { step = 1 }
                    case 1: readyStep
                    case 2: location
                    case 3: templateStep
                    case 4: permissions
                    default: TourPages(finish: { Storage.setupDone = true; dismiss() }, back: { step = 4 })
                    }
                }
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .animation(.spring(duration: 0.5, bounce: 0.1), value: step)
            .clipped()
        }
        .frame(width: 620, height: 720)
        .background(.background)
    }

    var location: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical)
            Text("Welcome to Minute").font(.largeTitle.weight(.semibold))
            Text("Where should your meetings and minutes be saved?").foregroundStyle(.secondary)
            ScrollView { LocationPicker(selection: $choice).padding(.vertical, 4) }
            if cloudChosen {
                Label("This folder syncs to the cloud. Recordings are saved there too; use the option below to keep only the transcript and minutes.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Delete recordings after the minutes are exported", isOn: $deleteAudio).font(.callout)
            if let e = mover.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if mover.busy { ProgressView(value: mover.progress).frame(width: 120); Text(mover.status).font(.caption).foregroundStyle(.secondary) }
                Button("Back") { step = 1 }.glassButton().controlSize(.large)
                Spacer()
                Button("Continue") {
                    Storage.deleteAudio = deleteAudio
                    mover.change(to: choice) { ok in if ok { step = 3 } }
                }.glassButton(prominent: true).controlSize(.large).disabled(mover.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(40)
    }

    var templateStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "doc.richtext").font(.system(size: 44)).foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical)
            Text("Your minutes template").font(.largeTitle.weight(.semibold))
            Text("Bring your own Word template and Minute learns where everything goes, or start from a clean one and add your logo.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TemplatePicker(showSkip: true) { step = 4 }
            Spacer(minLength: 0)
            HStack { Button("Back") { step = 2 }.glassButton().controlSize(.large); Spacer() }
        }.padding(40)
    }

    var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical)
            Text("Get Minute ready").font(.largeTitle.weight(.semibold))
            Text("Minute works on this Mac, so it needs a speech model and a writing model. They download once.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView { ReadyStep { ok in allReady = ok }.padding(.vertical, 2) }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = 0 }.glassButton().controlSize(.large)
                Spacer()
                Button(allReady ? "Continue" : "Continue Anyway") { step = 2 }.glassButton(prominent: allReady).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.padding(40)
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical)
            Text("Allow access once").font(.largeTitle.weight(.semibold))
            Text("macOS asks for each of these one time. Choose Allow, and Minute never interrupts you with them again. Nothing is sent anywhere.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            permissionRow(title: "Microphone", detail: "Your voice, and the room in onsite meetings.", symbol: "mic.fill", done: micOK, action: "Allow") { Task { await allowMic() } }
            permissionRow(title: "Meeting audio", detail: "What the other people say in Teams, Zoom or Meet.", symbol: "speaker.wave.2.fill", done: sysOK, action: "Allow") { Task { await allowSystemAudio() } }
            permissionRow(title: "Your meetings folder", detail: Storage.root.path.replacingOccurrences(of: home.path, with: "~"), symbol: "folder.fill", done: folderOK, action: "Allow") { allowFolder() }
            permissionRow(title: "Notifications", detail: "Tells you when a transcript or the minutes are ready.", symbol: "bell.badge.fill", done: notifOK, action: "Allow") { Task { await allowNotifications() } }
            if wordInstalled {
                permissionRow(title: "PDF export with Word", detail: pdfBusy ? "Checking with Word…" : "Lets Minute make the PDF through Word. Word may ask for folder access too.", symbol: "doc.richtext.fill", done: pdfOK, action: "Allow") { Task { await allowPDF() } }
            }
            if let e = permError { Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = 3 }.glassButton().controlSize(.large)
                Spacer()
                if !(micOK && sysOK && folderOK && notifOK && (pdfOK || !wordInstalled)) {
                    Button("Allow All") { Task { await allowAll() } }.glassButton(prominent: true).controlSize(.large).disabled(allowing)
                }
                Button("Continue") { step = 5 }.glassButton(prominent: micOK && sysOK && folderOK).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .task { await refreshPermissions() }
    }

    // MARK: asking, in one place

    func refreshPermissions() async {
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        sysOK = UserDefaults.standard.bool(forKey: "sysAudioOK")
        pdfOK = UserDefaults.standard.bool(forKey: "pdfOK")
        folderOK = (try? FileManager.default.contentsOfDirectory(atPath: Storage.root.path)) != nil
        let n = await UNUserNotificationCenter.current().notificationSettings()
        notifOK = n.authorizationStatus == .authorized || n.authorizationStatus == .provisional
    }

    func allowMic() async { micOK = await AVCaptureDevice.requestAccess(for: .audio) }

    func allowSystemAudio() async {
        let t = SystemTap()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minute-setup.caf")
        do {
            try t.start(url: url)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            t.stop(); sysOK = true; UserDefaults.standard.set(true, forKey: "sysAudioOK")
        } catch { sysOK = false; permError = "Meeting audio could not start: \(error.localizedDescription). Allow it in System Settings > Privacy & Security > Screen & System Audio Recording." }
    }

    func allowFolder() {
        if let e = Storage.verifyWritable(Storage.root) { folderOK = false; permError = e } else { folderOK = true }
    }

    func allowNotifications() async {
        notifOK = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func allowPDF() async {
        pdfBusy = true; defer { pdfBusy = false }
        let (code, tail) = await runMom(["--test-pdf"])
        pdfOK = code == 0
        UserDefaults.standard.set(pdfOK, forKey: "pdfOK")
        if !pdfOK { permError = tail }
    }

    func allowAll() async {
        allowing = true; permError = nil; defer { allowing = false }
        if !micOK { await allowMic() }
        if !sysOK { await allowSystemAudio() }
        if !folderOK { allowFolder() }
        if !notifOK { await allowNotifications() }
        if wordInstalled && !pdfOK { await allowPDF() }
    }

    func permissionRow(title: String, detail: String, symbol: String, done: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 30).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.body.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if done { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
            else { Button(action, action: perform).glassButton().controlSize(.large) }
        }
        .padding(14).glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var r: Recorder
    @ObservedObject var lib: Library
    @StateObject private var mover = StorageMover()
    @State private var choice = Storage.root
    @State private var deleteAudio = Storage.deleteAudio
    @State private var count = Storage.meetingFolders(in: Storage.root).count
    @State private var tplVersion = 0
    @State private var terms = (try? String(contentsOf: home.appendingPathComponent(".mom/terms.txt"), encoding: .utf8)) ?? ""

    var changed: Bool { choice.standardizedFileURL.path != Storage.root.standardizedFileURL.path }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current location") {
                    Text(Storage.root.path.replacingOccurrences(of: home.path, with: "~")).textSelection(.enabled).foregroundStyle(.secondary)
                }
                LabeledContent("Meetings") { Text("\(count)").foregroundStyle(.secondary) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Storage.root]) }
            } header: { Text("Storage") }

            Section {
                LocationPicker(selection: $choice)
                if changed {
                    Text("All \(count) existing meeting\(count == 1 ? "" : "s") will move to the new location, so everything stays in one place.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if mover.busy { ProgressView(value: mover.progress).frame(width: 140); Text(mover.status).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Move Everything Here") {
                            mover.change(to: choice) { ok in if ok { lib.refresh(); count = Storage.meetingFolders(in: Storage.root).count } }
                        }.glassButton(prominent: true).disabled(mover.busy || r.isRecording || r.isBusy)
                    }
                }
                if let e = mover.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if r.isRecording || r.isBusy { Text("Finish the current recording before moving the library.").font(.caption).foregroundStyle(.orange) }
            } header: { Text("Change location") }

            Section {
                let tp = TemplateProfile.current
                LabeledContent("Current template") { Text(tp.generic ? "Clean template" : "Your Word template").foregroundStyle(.secondary) }
                if tp.generic, let logo = PaperAssets.logo {
                    LabeledContent("Logo") { Image(nsImage: logo).resizable().scaledToFit().frame(height: 28) }
                }
                TemplatePicker { tplVersion += 1 }.id(tplVersion)
            } header: { Text("Template") }

            Section { ReadyStep() } header: { Text("This Mac") }

            Section {
                TextEditor(text: $terms).font(.system(.callout, design: .monospaced)).frame(height: 110)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .onChange(of: terms) { _, v in try? v.write(to: home.appendingPathComponent(".mom/terms.txt"), atomically: true, encoding: .utf8) }
                Text("Minute already knows common Indonesian brands, restaurants, places and work terms, and learns from the words you fix in a transcript. Add your own here, one per line, for example a client, a product or a cafe. To force a spelling write: heard = correct").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Names & terms") }

            Section {
                Toggle("Delete recordings after the minutes are exported", isOn: $deleteAudio)
                    .onChange(of: deleteAudio) { _, v in Storage.deleteAudio = v }
                Text("Keeps the transcript and minutes only. Useful when the folder syncs to the cloud.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Privacy") }

            Section {
                Button("Welcome Tour & Setup…") { openWindow(id: "setup"); NSApp.activate(ignoringOtherApps: true) }
            } header: { Text("Setup") }
        }
        .formStyle(.grouped).frame(width: 560, height: 820)
        .onAppear { choice = Storage.root; count = Storage.meetingFolders(in: Storage.root).count }
    }
}
