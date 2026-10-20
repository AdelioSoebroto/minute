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

struct ActionRecord: Codable, Equatable { var task: String; var owner: String; var due: String }

extension ActionItems {
    private static let months: [String: Int] = [
        "januari": 1, "january": 1, "jan": 1, "februari": 2, "february": 2, "feb": 2, "maret": 3, "march": 3, "mar": 3, "april": 4, "apr": 4, "mei": 5, "may": 5,
        "juni": 6, "june": 6, "jun": 6, "juli": 7, "july": 7, "jul": 7, "agustus": 8, "august": 8, "agu": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "oktober": 10, "october": 10, "okt": 10, "oct": 10, "november": 11, "nov": 11, "desember": 12, "december": 12, "des": 12, "dec": 12]

    /// "Friday, October 23rd, 2026", "23 Oktober 2026" or "23 Oktober" (year taken from `reference`) -> a date; "TBD" and the like -> nil.
    static func dueDate(_ text: String, reference: Date = Date()) -> Date? {
        if let r = text.range(of: #"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, options: .regularExpression) {      // 2026-10-23
            let p = text[r].split(separator: "-").compactMap { Int($0) }
            if p.count == 3, let d = Calendar(identifier: .gregorian).date(from: DateComponents(year: p[0], month: p[1], day: p[2])) { return d }
        }
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var day: Int?, month: Int?, year: Int?
        for w in words {
            if let m = months[w] { month = month ?? m }
            else if let n = Int(w) { if n >= 2000 && n < 2100 { year = n } else if (1...31).contains(n) && day == nil { day = n } }
            else if w.count > 2, let n = Int(w.dropLast(2)), ["st", "nd", "rd", "th"].contains(String(w.suffix(2))), (1...31).contains(n), day == nil { day = n }
        }
        guard let d = day, let m = month else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let y = year ?? cal.component(.year, from: reference)
        return cal.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// "2026-10-23" -> "23 Oct 2026" for display; anything else is shown as written.
    static func niceDue(_ text: String) -> String {
        guard text.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil, let d = dueDate(text) else { return text }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f.string(from: d)
    }

    static func isOverdue(due: String, now: Date = Date()) -> Bool {
        guard let d = dueDate(due, reference: now) else { return false }
        return d < Calendar.current.startOfDay(for: now)
    }
}

enum Changelog {
    /// The body of the "## [x.y.z]" section of CHANGELOG.md, or nil if there is none.
    static func section(for version: String, in text: String) -> String? {
        var out: [String] = []; var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { if inside { break }; inside = line.contains("[\(version)]"); continue }
            if inside { out.append(line) }
        }
        let s = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
