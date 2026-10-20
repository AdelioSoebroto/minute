import Foundation

/// Free-space checks, so a long meeting never fails silently on a full disk.
enum DiskGuard {
    static let warnBytes: Int64 = 2_000_000_000
    static let stopBytes: Int64 = 200_000_000

    static func freeBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    static func text(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / 1_000_000) MB"
    }
}

/// A recording that was running when the app or the Mac stopped leaves a marker file behind; on the next launch it can be recovered.
enum Recovery {
    static let lockName = "recording.lock"

    static func markStarted(_ dir: URL) { try? Data("recording".utf8).write(to: dir.appendingPathComponent(lockName)) }
    static func markFinished(_ dir: URL) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(lockName)) }

    static func unfinished(in root: URL, excluding current: URL?) -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0 != current && fm.fileExists(atPath: $0.appendingPathComponent(lockName).path)
            && fm.fileExists(atPath: $0.appendingPathComponent("mic.caf").path) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
