import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - What the current template looks like (written by `mom --learn-template` / `--make-template`)

struct TemplateProfile {
    var org = "", generic = true
    var labels: [String: String] = [:]
    var found: [String] = []

    func label(_ key: String, _ fallback: String) -> String {
        let v = labels[key] ?? ""
        return v.isEmpty ? fallback : v
    }

    private static var cache: (Date, TemplateProfile)?
    static var current: TemplateProfile {
        let url = home.appendingPathComponent(".mom/template.json")
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let c = cache, c.0 == m { return c.1 }
        var p = TemplateProfile()
        if let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            p.org = j["org"] as? String ?? ""
            p.generic = j["generic"] as? Bool ?? false
            p.labels = j["labels"] as? [String: String] ?? [:]
            p.found = j["found"] as? [String] ?? []
        }
        cache = (m, p)
        return p
    }
    static var exists: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".mom/template.json").path) }
}

// MARK: - Hardware report (`mom --hardware`)

struct HardwareInfo: Decodable {
    let chip: String, ram: Int, tier: String, model: String, installed: Bool, ollama: Bool, size_gb: Double
    var tierName: String { tier == "light" ? "Light" : "Standard" }
    static func read() async -> HardwareInfo? {
        let (_, out) = await runMom(["--hardware"], full: true)
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("HARDWARE ") }),
              let d = line.dropFirst(9).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HardwareInfo.self, from: d)
    }
}

// MARK: - Choosing a template

struct Found: Equatable {
    let slots: [String], org: String, topics: Bool
    static let names: [(String, String)] = [("agenda", "Meeting title"), ("date", "Date"), ("time", "Time"), ("internal_names", "Your participants"),
                                            ("internal_unit", "Your unit"), ("external_names", "Guests"), ("external_company", "Guest company")]
    var missingKey: [String] { Found.names.map(\.0).filter { !slots.contains($0) && ["agenda", "date", "time"].contains($0) } }
}

struct TemplatePicker: View {
    enum Kind { case mine, clean }
    var showSkip = false
    var onDone: () -> Void

    @State private var kind: Kind = .clean
    @State private var docx: URL?
    @State private var logo: URL?
    @State private var org = ""
    @State private var busy = false
    @State private var stage = ""
    @State private var error: String?
    @State private var targeted = false
    @State private var found: Found?

    var body: some View {
        if let f = found { result(f) } else { picker }
    }

    private func result(_ f: Found) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(f.org.isEmpty ? "Template ready" : "Template ready · \(f.org)", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            Text("Here is what Minute will fill in:").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(Found.names, id: \.0) { key, title in
                    HStack {
                        Image(systemName: f.slots.contains(key) ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(f.slots.contains(key) ? Color.green : .secondary)
                        Text(title); Spacer()
                        if !f.slots.contains(key) { Text("not in this template").font(.caption).foregroundStyle(.secondary) }
                    }.font(.callout)
                }
                HStack {
                    Image(systemName: f.topics ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(f.topics ? Color.green : .orange)
                    Text("Topics discussed"); Spacer()
                    if !f.topics { Text("added at the end").font(.caption).foregroundStyle(.secondary) }
                }.font(.callout)
            }
            .padding(12).glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !f.missingKey.isEmpty {
                Label("Minute could not find where \(f.missingKey.map { $0 == "agenda" ? "the title" : $0 }.joined(separator: " or ")) goes, so it will be left out. Choose another file if that is wrong.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose Another") { found = nil }.glassButton().controlSize(.large)
                Spacer()
                Button("Looks Right") { onDone() }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                choice("doc.text.magnifyingglass", "Use my template", "Minute reads your Word file and fills it in.", .mine)
                choice("doc.richtext", "Clean template", "A neutral page with your logo.", .clean)
            }
            Group {
                if kind == .mine { mine } else { clean }
            }
            .animation(.spring(duration: 0.35), value: kind)
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text(stage).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if showSkip && TemplateProfile.exists && !busy {
                    Button("Keep current") { onDone() }.glassButton().controlSize(.large)
                }
                Button(kind == .mine ? "Read Template" : "Create Template") { apply() }
                    .glassButton(prominent: true).controlSize(.large)
                    .disabled(busy || (kind == .mine && docx == nil))
            }
        }
    }

    private func choice(_ symbol: String, _ title: String, _ detail: String, _ k: Kind) -> some View {
        Button { Haptic.tick(); kind = k } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical)
                    Spacer()
                    if kind == k { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: kind == k ? Color.accentColor.opacity(0.25) : nil, interactive: true)
        }.buttonStyle(.plain)
    }

    private var mine: some View {
        dropZone(symbol: "arrow.down.doc", title: docx?.lastPathComponent ?? "Drop your Word template here",
                 detail: docx == nil ? "or click to choose a .docx. Minute studies where the agenda, date, participants and topics go." : "Click to choose another file.",
                 types: ["docx"]) { docx = $0 } open: { pick(["docx"]) { docx = $0 } }
    }

    private var clean: some View {
        VStack(spacing: 10) {
            dropZone(symbol: "photo.badge.plus", title: logo?.lastPathComponent ?? "Drop your logo here",
                     detail: logo == nil ? "PNG or JPG. Optional: without a logo, your organisation name is used." : "Click to choose another image.",
                     types: ["png", "jpg", "jpeg", "heic", "gif", "tiff"]) { logo = $0 } open: { pick(["png", "jpg", "jpeg", "heic", "gif", "tiff"]) { logo = $0 } }
            TextField("Organisation name (optional)", text: $org).textFieldStyle(.roundedBorder)
        }
    }

    private func dropZone(symbol: String, title: String, detail: String, types: [String], set: @escaping (URL) -> Void, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
                Text(title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 110).padding(14).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear))
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { types.contains($0.pathExtension.lowercased()) }) else { return false }
            Haptic.tick(); set(u); return true
        } isTargeted: { targeted = $0 }
    }

    private func pick(_ exts: [String], _ set: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let u = panel.url { set(u) }
    }

    private func apply() {
        busy = true; error = nil; stage = kind == .mine ? "Reading your template…" : "Creating your template…"
        let args: [String]
        if kind == .mine, let d = docx { args = ["--learn-template", d.path] + (org.isEmpty ? [] : ["--org", org]) }
        else { args = ["--make-template"] + (logo.map { ["--logo", $0.path] } ?? []) + (org.isEmpty ? [] : ["--org", org]) }
        Task {
            let (code, out) = await runMom(args, full: true) { s in Task { @MainActor in stage = s + "…" } }
            busy = false
            if code == 0, let line = out.split(separator: "\n").last(where: { $0.hasPrefix("TEMPLATE ") }),
               let d = line.dropFirst(9).data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                Haptic.tick()
                found = Found(slots: j["found"] as? [String] ?? [], org: j["org"] as? String ?? "", topics: j["topics"] as? Bool ?? true)
            }
            else { error = out.split(separator: "\n").last.map(String.init) ?? "Could not read this template." }
        }
    }
}

// MARK: - Hardware step

struct HardwareStep: View {
    @State private var info: HardwareInfo?
    @State private var pulling = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let i = info {
                HStack(spacing: 14) {
                    Image(systemName: "cpu").font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i.chip), \(i.ram) GB").font(.body.weight(.medium))
                        Text("\(i.tierName) setup: \(i.model) for the minutes, Whisper for speech").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if i.installed { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                }
                .padding(14).glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(i.tier == "light"
                     ? "This Mac has a little less memory, so Minute uses a smaller model and shorter passes. It runs the same checks (draft, fact-check, deadlines, tidy), so the minutes stay reliable; it just takes a bit longer."
                     : "Minute also adapts on its own while it works: it slows down on battery, in Low Power Mode or when the Mac gets warm, and frees the memory afterwards.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !i.installed {
                    if !i.ollama {
                        Label("The language model runner (Ollama) is not installed yet. Install it from ollama.com, then come back to Settings.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Text("The \(i.model) model (\(String(format: "%.1f", i.size_gb)) GB) downloads once and then works offline.").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if pulling { ProgressView().controlSize(.small) }
                            Button("Download") { pull() }.glassButton(prominent: true).controlSize(.large).disabled(pulling)
                        }
                    }
                }
                if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking this Mac…").foregroundStyle(.secondary) }
            }
        }
        .task { info = await HardwareInfo.read() }
    }
    private func pull() {
        pulling = true; error = nil
        Task {
            let (code, out) = await runMom(["--pull-model"], full: true)
            pulling = false
            if code != 0 { error = out.split(separator: "\n").last.map(String.init) ?? "Download failed." }
            info = await HardwareInfo.read()
        }
    }
}
