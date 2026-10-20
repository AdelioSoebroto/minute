import SwiftUI
import Carbon.HIToolbox

// MARK: - Flags dropped during a meeting ("this is an action", "this was decided")

enum MarkKind: String, CaseIterable, Codable {
    case action, decision, important
    var label: String { switch self { case .action: return "Action"; case .decision: return "Decision"; case .important: return "Important" } }
    var symbol: String { switch self { case .action: return "checkmark.circle"; case .decision: return "hand.thumbsup"; case .important: return "star" } }
    var tint: Color { switch self { case .action: return .blue; case .decision: return .green; case .important: return .orange } }
    var hotkey: String { switch self { case .action: return "A"; case .decision: return "D"; case .important: return "I" } }
}

struct Mark: Identifiable, Equatable {
    let id = UUID()
    let t: Int, kind: MarkKind
    var time: String { String(format: "%02d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) }

    static func load(from dir: URL?) -> [Mark] {
        guard let dir, let d = try? Data(contentsOf: dir.appendingPathComponent("marks.json")),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let t = e["t"] as? Int, let k = (e["kind"] as? String).flatMap(MarkKind.init) else { return nil }
            return Mark(t: t, kind: k)
        }
    }

    static func save(_ marks: [Mark], to dir: URL) {
        let arr = marks.map { ["t": $0.t, "kind": $0.kind.rawValue] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("marks.json")) }
    }
}

/// System-wide shortcuts so a flag can be dropped from inside Teams or Zoom: ⌃⌥A action, ⌃⌥D decision, ⌃⌥I important. No permission needed.
@MainActor
final class MarkHotKeys {
    static let shared = MarkHotKeys()
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    var fire: (MarkKind) -> Void = { _ in }

    func register() {
        guard handler == nil else { return }
        let codes: [(MarkKind, Int)] = [(.action, kVK_ANSI_A), (.decision, kVK_ANSI_D), (.important, kVK_ANSI_I)]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let kinds = MarkKind.allCases
            if Int(id.id) < kinds.count { let k = kinds[Int(id.id)]; DispatchQueue.main.async { MarkHotKeys.shared.fire(k) } }
            return noErr
        }, 1, &spec, nil, &handler)
        for (i, (_, code)) in codes.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4D4E5445), id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

/// A small flag menu used on the floating control and the recording card.
struct FlagMenu: View {
    @ObservedObject var r: Recorder
    var body: some View {
        Menu {
            ForEach(MarkKind.allCases, id: \.self) { k in
                Button { r.addMark(k) } label: { Label("\(k.label)  ⌃⌥\(k.hotkey)", systemImage: k.symbol) }
            }
        } label: { Image(systemName: r.marks.isEmpty ? "flag" : "flag.fill") }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).foregroundStyle(r.marks.isEmpty ? Color.secondary : Color.orange)
            .help("Flag this moment so it can't be missed in the minutes").accessibilityLabel("Flag this moment")
    }
}
