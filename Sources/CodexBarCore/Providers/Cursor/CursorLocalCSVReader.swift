import Foundation

// MARK: - Cursor Local CSV Reader (tokscale compatible)

enum CursorLocalCSVReader {
    static func cachedCSVPaths(home: URL? = nil) -> [URL] {
        let base: URL = if let home {
            home.appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
        } else if let dir = ProcessInfo.processInfo.environment["TOKSCALE_CONFIG_DIR"] {
            URL(fileURLWithPath: dir).appendingPathComponent("cursor-cache", isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return contents.filter {
            let n = $0.lastPathComponent
            return n.hasPrefix("usage") && n.hasSuffix(".csv") && !$0.path.contains("/archive/") && !n
                .hasPrefix("usage.backup")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct Row: Sendable {
        let date: Date
        let model: String
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let totalTokens: Int?
        let cost: Double
    }

    static func parseFile(at url: URL, calendar: Calendar = .current) -> [Row] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return [] }
        let cols = self.parseCSVLine(header)
        let hasKind = cols.contains { $0.lowercased() == "kind" }
        struct Idx { let model: Int; let inW: Int; let inWo: Int; let read: Int; let out: Int; let cost: Int }
        let idx = if hasKind, cols.count >= 11 {
            Idx(model: 4, inW: 6, inWo: 7, read: 8, out: 9, cost: 11)
        } else if hasKind {
            Idx(model: 2, inW: 4, inWo: 5, read: 6, out: 7, cost: 9)
        } else {
            Idx(model: 1, inW: 2, inWo: 3, read: 4, out: 5, cost: 7)
        }
        var rows: [Row] = []
        for line in lines.dropFirst() {
            let c = self.parseCSVLine(line)
            guard c.count > max(idx.model, idx.cost) else { continue }
            let model = c[idx.model].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let inW = self.parseInt(c[idx.inW])
            let inWo = self.parseInt(c[idx.inWo])
            let read = self.parseInt(c[idx.read])
            let out = self.parseInt(c[idx.out])
            let cost = self.parseCost(c[idx.cost])
            // Parse the authoritative Total Tokens column if present.
            let totalIdx = idx.cost - 1
            let totalTokens = totalIdx < cols.count && totalIdx < c.count
                && cols[totalIdx].lowercased().contains("total") ? self.parseInt(c[totalIdx]) : nil
            guard let date = parseDate(c[0], calendar: calendar) else { continue }
            let write = max(0, inW - inWo)
            let input = inWo
            if input == 0, out == 0, read == 0, write == 0 { continue }
            rows.append(Row(
                date: date,
                model: model,
                input: input,
                cacheRead: read,
                cacheWrite: write,
                output: out,
                totalTokens: totalTokens,
                cost: cost))
        }
        return rows
    }

    static func makeDailyReport(
        from rows: [Row],
        calendar: Calendar = .current,
        now: Date = Date()) -> CostUsageDailyReport
    {
        var byDay: [String: CostUsageDailyReport.Entry] = [:]
        var totalCost: Double = 0
        var totalTokens = 0
        for row in rows {
            let key = CostUsageLocalDay.key(from: row.date, calendar: calendar)
            let existing = byDay[key]
            var e = existing ?? CostUsageDailyReport.Entry(
                date: key,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                totalTokens: 0,
                requestCount: 0,
                costUSD: 0,
                modelsUsed: nil,
                modelBreakdowns: [])
            // Honor the CSV's authoritative Total Tokens column when present;
            // otherwise derive from component columns.
            let tot = row.totalTokens ?? (row.input + row.output + row.cacheRead + row.cacheWrite)
            var bds = e.modelBreakdowns ?? []
            if let i = bds.firstIndex(where: { $0.modelName == row.model }) {
                let b = bds[i]
                bds[i] = CostUsageDailyReport.ModelBreakdown(
                    modelName: b.modelName,
                    costUSD: (b.costUSD ?? 0) + row.cost,
                    totalTokens: (b.totalTokens ?? 0) + tot,
                    requestCount: (b.requestCount ?? 0) + 1)
            } else {
                bds.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: row.model,
                    costUSD: row.cost,
                    totalTokens: tot,
                    requestCount: 1))
            }
            let ne = CostUsageDailyReport.Entry(
                date: key,
                inputTokens: (e.inputTokens ?? 0) + row.input,
                outputTokens: (e.outputTokens ?? 0) + row.output,
                cacheReadTokens: (e.cacheReadTokens ?? 0) + row.cacheRead,
                cacheCreationTokens: (e.cacheCreationTokens ?? 0) + row.cacheWrite,
                totalTokens: (e.totalTokens ?? 0) + tot,
                requestCount: (e.requestCount ?? 0) + 1,
                costUSD: (e.costUSD ?? 0) + row.cost,
                modelsUsed: e.modelsUsed,
                modelBreakdowns: bds)
            byDay[key] = ne
            totalCost += row.cost
            totalTokens += tot
        }
        let sorted = byDay.values.sorted { $0.date < $1.date }
        let summary: CostUsageDailyReport.Summary? = sorted.isEmpty ? nil : .init(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)
        return CostUsageDailyReport(data: sorted, summary: summary)
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var cols: [String] = []
        var cur = ""
        var q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == ",", !q {
                cols.append(cur); cur = ""
            } else { cur.append(ch) }
        }
        cols.append(cur)
        return cols
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"\"", with: "\"") }
    }

    static func parseInt(_ s: String) -> Int {
        Int(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")) ?? 0
    }

    static func parseCost(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "-" || t.lowercased() == "included" || t.lowercased() == "nan" { return 0 }
        return Double(t.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) ?? 0
    }

    static func parseDate(_ s: String, calendar: Calendar) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: t) {
                if fmt == "yyyy-MM-dd" {
                    var utcCal = Calendar(identifier: .gregorian)
                    utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
                    var c = utcCal.dateComponents([.year, .month, .day], from: d)
                    c.hour = 12; c.minute = 0; c.second = 0; c.timeZone = TimeZone(secondsFromGMT: 0)
                    return utcCal.date(from: c) ?? d
                }
                return d
            }
        }
        return nil
    }
}
