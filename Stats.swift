import Foundation

/// Sidecar `~/Dictation/stats.jsonl`. One JSON object per saved take:
/// `{ts, words, seconds, app}`. Older markdown-only takes still count for
/// the Words tile; speed, apps, and time saved need this file.
enum Stats {
    struct Take: Equatable {
        let date: Date
        let words: Int
        let seconds: Double
        let app: String
    }

    enum Range: String, CaseIterable, Hashable {
        case all, month, today
        var title: String {
            switch self {
            case .all: "All time"
            case .month: "This month"
            case .today: "Today"
            }
        }
    }

    struct Snapshot {
        var averageSpeed: Int
        var words: Int
        var appsUsed: Int
        var timeSavedMinutes: Double
    }

    static func file(in dir: URL) -> URL {
        dir.resolvingSymlinksInPath().appendingPathComponent("stats.jsonl")
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Typing minutes at 40 WPM minus speaking minutes, never negative.
    static func timeSavedMinutes(words: Int, seconds: Double) -> Double {
        max(0, Double(words) / 40.0 - seconds / 60.0)
    }

    /// Spec display: "11 hours" / "42 min".
    static func formatTimeSaved(minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded >= 60 {
            let h = Int((Double(rounded) / 60.0).rounded())
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        return "\(rounded) min"
    }

    static func contains(_ date: Date, range: Range, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch range {
        case .all: return true
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .month:
            let a = calendar.dateComponents([.year, .month], from: date)
            let b = calendar.dateComponents([.year, .month], from: now)
            return a.year == b.year && a.month == b.month
        }
    }

    /// Words from markdown history (includes pre-sidecar takes). Speed, apps,
    /// and time saved from the sidecar only.
    static func snapshot(stats: [Take], history: [Transcript], range: Range,
                         now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        let hist = history.filter { contains($0.date, range: range, now: now, calendar: calendar) }
        let side = stats.filter { contains($0.date, range: range, now: now, calendar: calendar) }
        let words = hist.reduce(0) { $0 + wordCount($1.text) }
        let sideWords = side.reduce(0) { $0 + $1.words }
        let seconds = side.reduce(0.0) { $0 + $1.seconds }
        let wpm = seconds > 0 ? Int((Double(sideWords) / seconds * 60).rounded()) : 0
        let apps = Set(side.map(\.app).filter { !$0.isEmpty }).count
        return Snapshot(
            averageSpeed: wpm,
            words: words,
            appsUsed: apps,
            timeSavedMinutes: timeSavedMinutes(words: sideWords, seconds: seconds)
        )
    }

    static func load(dir: URL) -> [Take] {
        let url = file(in: dir)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [Take] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let t = parse(line: line, iso: iso, isoFrac: isoFrac) { out.append(t) }
        }
        out.sort { $0.date > $1.date }
        return out
    }

    static func append(_ take: Take, in dir: URL) {
        let url = file(in: dir)
        guard let line = jsonLine(take) else { return }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func parse(line: Substring) -> Take? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parse(line: line, iso: iso, isoFrac: isoFrac)
    }

    private static func parse(line: Substring, iso: ISO8601DateFormatter, isoFrac: ISO8601DateFormatter) -> Take? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let ts = obj["ts"] as? String, let date = parseDate(ts, iso: iso, isoFrac: isoFrac) else { return nil }
        guard let words = intVal(obj["words"]), let seconds = doubleVal(obj["seconds"]) else { return nil }
        let app = obj["app"] as? String ?? ""
        return Take(date: date, words: max(0, words), seconds: max(0, seconds), app: app)
    }

    // MARK: JSON

    private static func jsonLine(_ take: Take) -> String? {
        let obj: [String: Any] = [
            "ts": isoString(take.date),
            "words": take.words,
            "seconds": take.seconds,
            "app": take.app
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func parseDate(_ s: String, iso: ISO8601DateFormatter, isoFrac: ISO8601DateFormatter) -> Date? {
        iso.date(from: s) ?? isoFrac.date(from: s)
    }

    private static func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleVal(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
