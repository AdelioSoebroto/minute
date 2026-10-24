import SwiftUI
import Security

// MARK: - Which engine writes the minutes: the model on this Mac (default, private) or the Claude API (online, optional)

enum AIEngine {
    static let service = "local.minute.app.anthropic"
    static let models: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (best quality)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (faster, cheaper)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (cheapest)"),
    ]

    static var useClaude: Bool {
        get { UserDefaults.standard.string(forKey: "aiProvider") == "anthropic" }
        set { UserDefaults.standard.set(newValue ? "anthropic" : "ollama", forKey: "aiProvider"); apply() }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-opus-5-5" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeModel"); apply() }
    }

    /// The pipeline reads the choice from ~/.mom/config.json; the key itself is never written there.
    static func apply() { Storage.writeConfig(["llm_provider": useClaude ? "anthropic" : "ollama", "claude_model": model]) }

    // Keychain: the key lives only here and is handed to the pipeline through its environment for the duration of a run.
    private static func query() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }

    static var key: String? {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static var hasKey: Bool { key?.isEmpty == false }

    @discardableResult static func saveKey(_ k: String) -> Bool {
        let trimmed = k.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query() as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var q = query(); q[kSecValueData as String] = Data(trimmed.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func environment() -> [String: String] {
        guard useClaude, let k = key, !k.isEmpty else { return [:] }
        return ["MINUTE_ANTHROPIC_KEY": k]
    }
}

struct AIEngineSection: View {
    @State private var claude = AIEngine.useClaude
    @State private var model = AIEngine.model
    @State private var field = ""
    @State private var saved = AIEngine.hasKey
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Section {
            Picker("Write the minutes with", selection: $claude) {
                Text("This Mac (private, works offline)").tag(false)
                Text("Claude API (online)").tag(true)
            }.onChange(of: claude) { _, v in AIEngine.useClaude = v; result = nil }

            if claude {
                Picker("Model", selection: $model) { ForEach(AIEngine.models, id: \.id) { Text($0.name).tag($0.id) } }
                    .onChange(of: model) { _, v in AIEngine.model = v }
                if saved {
                    LabeledContent("API key") {
                        HStack { Label("Saved in the Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("Remove") { AIEngine.saveKey(""); saved = false; result = nil } }
                    }
                } else {
                    LabeledContent("API key") {
                        HStack {
                            SecureField("sk-ant-…", text: $field).textFieldStyle(.roundedBorder).frame(width: 260)
                            Button("Save") { if AIEngine.saveKey(field) { saved = AIEngine.hasKey; field = "" } }.disabled(field.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(!saved || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = result { Text(r.text).font(.caption).foregroundStyle(r.ok ? .green : .red).fixedSize(horizontal: false, vertical: true) }
                }
                Text("With Claude, the transcript, the text read from shared screens and the names of calendar invitees are sent to Anthropic to write the minutes. Speech recognition still runs on this Mac and audio never leaves it. If Claude can't be reached, Minute uses the model on this Mac when it has one. Only use it where company policy allows.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Everything stays on this Mac. Turn on Claude to write the minutes online without downloading or running a model here.").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("AI engine") }
    }

    private func test() {
        testing = true; result = nil; AIEngine.apply()
        Task {
            let (code, out) = await runMom(["--claude-test"])
            testing = false
            result = code == 0 ? (true, "Connected (\(AIEngine.model))") : (false, out)
        }
    }
}
