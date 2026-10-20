import Foundation

// MARK: - Transcript lines ("[hh:mm:ss] Who: text" in transcript.md)

struct TLine: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var who: String
    var text: String

    var seconds: Double {
        let p = time.split(separator: ":").compactMap { Double($0) }
        return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
    }
    var speaker: String { who == "Me" ? "You" : who }

    static func parse(_ text: String) -> [TLine] {
        text.split(separator: "\n").compactMap { raw -> TLine? in
            let s = String(raw)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
            let time = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            return TLine(time: time, who: String(rest[..<colon]), text: String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func serialize(_ lines: [TLine]) -> String {
        "# Transcript\n\n" + lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "[\($0.time)] \($0.who): \($0.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\n"
    }
}
