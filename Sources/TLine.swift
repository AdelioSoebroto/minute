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

// MARK: - Finding where a minute was said, and sharing text

extension TLine {
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    /// Index of the transcript line a point in the minutes most likely came from (rare shared words count more), or nil if nothing fits.
    static func bestMatch(for text: String, in lines: [TLine]) -> Int? {
        let want = tokens(text); guard !want.isEmpty, !lines.isEmpty else { return nil }
        let sets = lines.map { tokens($0.text) }
        var df: [String: Int] = [:]
        for s in sets { for t in s { df[t, default: 0] += 1 } }
        var best: (Int, Double)?
        for (i, s) in sets.enumerated() {
            let shared = s.intersection(want); guard !shared.isEmpty else { continue }
            let score = shared.reduce(0.0) { $0 + 1.0 / Double(df[$1] ?? 1) } / (1 + 0.05 * Double(s.count))
            if best == nil || score > best!.1 { best = (i, score) }
        }
        guard let b = best, b.1 >= 0.35 else { return nil }
        return b.0
    }

    static func srt(_ lines: [TLine]) -> String {
        func stamp(_ t: Double) -> String { let ms = Int(t * 1000); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
        return lines.enumerated().map { i, l in
            let end = i + 1 < lines.count ? max(l.seconds + 1, min(lines[i + 1].seconds, l.seconds + 8)) : l.seconds + 5
            return "\(i + 1)\n\(stamp(l.seconds)) --> \(stamp(end))\n\(l.speaker): \(l.text)\n"
        }.joined(separator: "\n")
    }
}

enum ShareText {
    static func markdown(agenda: String, date: String, time: String, internalNames: [String], unit: String, externalNames: [String], company: String,
                         topics: [String], transcript: [TLine] = []) -> String {
        var o = "# \(agenda.isEmpty ? "Minutes of Meeting" : agenda)\n\n"
        o += "**Date:** \(date)  \n**Time:** \(time)\n\n"
        if !internalNames.isEmpty { o += "## Participants\n\n**Internal\(unit.isEmpty ? "" : " (\(unit))"):** \(internalNames.joined(separator: ", "))\n\n" }
        if !externalNames.isEmpty { o += (internalNames.isEmpty ? "## Participants\n\n" : "") + "**External\(company.isEmpty ? "" : " (\(company))"):** \(externalNames.joined(separator: ", "))\n\n" }
        o += "## Topics discussed\n\n" + topics.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n") + "\n"
        if !transcript.isEmpty { o += "\n## Transcript\n\n" + transcript.map { "**[\($0.time)] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n") + "\n" }
        return o
    }

    static func plain(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "## ", with: "").replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "  \n", with: "\n")
    }
}

// MARK: - Action items across meetings

enum ActionItems {
    private static let cues = ["akan ", "tolong", "follow up", "follow-up", "tindak lanjut", "deadline", "due ", "sebelum", "paling lambat", "harus", "perlu ", "segera",
                               "action", "pic ", "will ", "to be ", "needs to", "need to", "should ", "must ", "eskalasi", "escalate", "siapkan", "prepare", "kirim", "send ",
                               "by monday", "by tuesday", "by wednesday", "by thursday", "by friday", "by end", "minggu depan", "next week", "besok", "tomorrow", "hari ini", "today"]

    static func isAction(_ topic: String) -> Bool {
        let t = topic.lowercased() + " "
        return cues.contains { t.contains($0) }
    }

    static func key(folder: String, text: String) -> String {
        folder + "|" + String(text.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(80))
    }

    /// Which items are done or dismissed, kept in one small file (~/.mom/actions.json) so it survives edits and app updates.
    struct State: Codable, Equatable { var done: Set<String> = []; var dismissed: Set<String> = [] }

    static func load(_ url: URL) -> State { (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State() }
    static func save(_ st: State, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(st).write(to: url, options: .atomic)
    }
}
