import SwiftUI
import Charts
import UIKit
import LocalAuthentication
import CoreTransferable
import UniformTypeIdentifiers

// =====================================================================================
//  Spends – iOS 17+
//  CSV line format:  2026-10-01 11:40, Source|Last4|Amount|Merchant
//  Structure:  Models → Formatting → Categoriser → Engine (actor, off-main parsing)
//              → Store (@Observable) → Views (Today / Month / Spends / Settings)
// =====================================================================================

// MARK: - Constants

enum Keys {
    static let overrides = "ov"          // kept from the old version (migrated on load)
    static let budgets = "bud"
    static let hideTransfers = "ht"
    static let bookmark = "bm"
    static let txOverrides = "tov"
    static let excluded = "exc"
    static let dedupe = "dd"
    static let cycleDay = "cyc"
    static let masked = "mask"
    static let cover = "cover"
    static let lock = "lock"
}

enum Cats {
    static let all: [(name: String, color: Color, symbol: String)] = [
        ("Food", .orange, "fork.knife"),
        ("Groceries", .green, "cart"),
        ("Transport", .blue, "car"),
        ("Shopping", .purple, "bag"),
        ("Bills", .brown, "doc.text"),
        ("Health", .red, "cross.case"),
        ("Fun", .teal, "ticket"),
        ("Transfers", .gray, "arrow.left.arrow.right"),
        ("Other", Color(.systemGray2), "questionmark.circle")
    ]
    static var names: [String] { all.map { $0.name } }
    static func color(_ n: String) -> Color { all.first { $0.name == n }?.color ?? .gray }
    static func symbol(_ n: String) -> String { all.first { $0.name == n }?.symbol ?? "circle" }
}

// MARK: - Formatting (Indian grouping, paise-aware)

extension Decimal {
    var dbl: Double { NSDecimalNumber(decimal: self).doubleValue }
}

enum Fmt {
    static let rupee0: NumberFormatter = make(0)
    static let rupee2: NumberFormatter = make(2)
    private static func make(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_IN")
        f.currencyCode = "INR"
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

/// ₹12,34,567 – shows paise only when there are some (₹99.50 stays ₹99.50)
func inr(_ d: Decimal) -> String {
    let ns = NSDecimalNumber(decimal: d)
    let x = ns.doubleValue
    let f = (x == x.rounded()) ? Fmt.rupee0 : Fmt.rupee2
    return f.string(from: ns) ?? "₹\(x)"
}

/// ₹1.2L, ₹45k – for chart axes
func inrCompact(_ v: Double) -> String {
    let a = abs(v)
    let s = v < 0 ? "-" : ""
    func t(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...1))) }
    if a >= 1e7 { return "\(s)₹\(t(a / 1e7))Cr" }
    if a >= 1e5 { return "\(s)₹\(t(a / 1e5))L" }
    if a >= 1e3 { return "\(s)₹\(t(a / 1e3))k" }
    return "\(s)₹\(Int(a))"
}

func dayTitle(_ d: Date) -> String {
    let c = Calendar.current
    if c.isDateInToday(d) { return "Today" }
    if c.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

/// Percentages that always add up to 100 (largest-remainder method)
func percents(_ v: [Double]) -> [Int] {
    let total = v.reduce(0, +)
    guard total > 0 else { return v.map { _ in 0 } }
    let raw = v.map { $0 / total * 100 }
    var out = raw.map { Int($0) }
    var left = 100 - out.reduce(0, +)
    let order = raw.indices.sorted { (raw[$0] - Double(out[$0])) > (raw[$1] - Double(out[$1])) }
    for i in order {
        if left <= 0 { break }
        out[i] += 1
        left -= 1
    }
    return out
}

func csvEscape(_ s: String) -> String {
    var v = s
    if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }      // spreadsheet formula injection
    v = v.replacingOccurrences(of: "\"", with: "\"\"")              // RFC 4180
    return "\"\(v)\""
}

// MARK: - Merchant cleanup and categorisation

enum Merchant {
    private static func words(_ raw: String) -> [String] {
        var s = raw
        if let i = s.firstIndex(of: "*") { s = String(s[..<i]) }
        return s.split(whereSeparator: { !($0.isLetter || $0 == "&" || $0 == "'") }).map { String($0) }
    }
    /// Stable key for "apply to all": SWIGGY*ORD123 → "swiggy"
    static func key(_ raw: String) -> String {
        let w = words(raw).prefix(2).map { $0.lowercased() }
        return w.isEmpty ? raw.trimmingCharacters(in: .whitespaces).lowercased() : w.joined(separator: " ")
    }
    /// Display name: SWIGGY*ORD123 → "Swiggy"
    static func clean(_ raw: String) -> String {
        let w = words(raw).prefix(3).map { word -> String in
            if word.count <= 3 && word == word.uppercased() { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        let r = w.joined(separator: " ")
        return r.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : r
    }
}

enum Categorizer {
    // Edit freely. Short alphanumeric keywords (≤5 chars) match whole words only,
    // so "ola" no longer hits "Coca Cola" and "cred" no longer hits "Credit Card".
    static let rules: [(String, [String])] = [
        ("Food", ["swiggy", "zomato", "restaurant", "cafe", "kfc", "domino", "pizza", "starbucks", "bakery"]),
        ("Groceries", ["blinkit", "zepto", "bigbasket", "instamart", "dmart", "grocer"]),
        ("Transport", ["uber", "ola", "olacabs", "rapido", "irctc", "fuel", "petrol", "metro", "redbus", "fastag", "mmt"]),
        ("Shopping", ["amazon", "flipkart", "myntra", "ajio", "nykaa"]),
        ("Bills", ["jio", "airtel", "electric", "bescom", "recharge", "cred", "insurance", "rent", "raz*", "furnish"]),
        ("Health", ["pharm", "apollo", "hospital", "clinic", "medic", "1mg"]),
        ("Fun", ["netflix", "spotify", "bookmyshow", "prime", "hotstar"]),
        ("Transfers", ["a/c", "account"])
    ]

    private static let compiled: [(String, NSRegularExpression)] = rules.map { cat, keys in
        let parts = keys.map { k -> String in
            let e = NSRegularExpression.escapedPattern(for: k)
            let whole = k.count <= 5 && k.allSatisfy { $0.isLetter || $0.isNumber }
            return whole ? "(?<![a-z0-9])\(e)(?![a-z0-9])" : "(?<![a-z0-9])\(e)"
        }
        let rx = try! NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.caseInsensitive])
        return (cat, rx)
    }

    /// Matches the merchant only – never the card name.
    static func category(for merchant: String) -> String {
        let r = NSRange(merchant.startIndex..., in: merchant)
        for (c, rx) in compiled where rx.firstMatch(in: merchant, options: [], range: r) != nil { return c }
        return "Other"
    }
}

/// "AU Bank Credit Card" → "AU", "HDFC Account" → "HDFC", "Bank of Baroda" stays as is
func bankName(_ src: String) -> String {
    var s = src.trimmingCharacters(in: .whitespaces)
    var changed = true
    while changed {
        changed = false
        for suffix in [" credit card", " debit card", " account", " bank"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            changed = true
        }
    }
    return s.isEmpty ? src : s
}

// MARK: - Models

struct Tx: Identifiable, Sendable {
    enum Reason: Sendable {
        case excluded, duplicate, transfer
        var label: String {
            switch self {
            case .excluded: return "excluded"
            case .duplicate: return "duplicate"
            case .transfer: return "transfer"
            }
        }
    }
    let id: String
    let date: Date
    let src: String
    let last4: String
    let amt: Decimal
    let merchant: String      // raw text from the CSV
    let name: String          // cleaned for display
    let key: String           // used for "apply to all"
    let bank: String
    let auto: String          // automatic category
    let hay: String           // lowercase search text
    var cat: String           // effective category (after overrides)
    var reason: Reason?       // nil = counted in totals
    var counted: Bool { reason == nil }

    static func make(id: String, date: Date, src: String, last4: String, amt: Decimal, merchant: String) -> Tx {
        let auto = Categorizer.category(for: merchant)
        let hay = "\(merchant) \(src) \(last4) \(amt)".lowercased()
        return Tx(id: id, date: date, src: src, last4: last4, amt: amt, merchant: merchant,
                  name: Merchant.clean(merchant), key: Merchant.key(merchant), bank: bankName(src),
                  auto: auto, hay: hay, cat: auto)
    }
}

struct Period: Hashable, Identifiable {
    let anchor: Date, start: Date, end: Date, cycleDay: Int
    var id: Date { anchor }
    var title: String {
        if cycleDay == 1 { return anchor.formatted(.dateTime.month(.wide).year()) }
        let last = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return start.formatted(f) + " – " + last.formatted(f)
    }
    static let placeholder = Period(anchor: .now, start: .now, end: .now, cycleDay: 1)
}

struct Part: Identifiable {
    let id: String
    let value: Decimal
    let pct: Int
    let color: Color
    var dbl: Double { value.dbl }
}
struct DayTotal: Identifiable {
    let date: Date
    let total: Decimal
    let pct: Int
    var id: Date { date }
    var dbl: Double { total.dbl }
}
struct PeriodTotal: Identifiable {
    let anchor: Date
    let total: Decimal
    var id: Date { anchor }
    var dbl: Double { total.dbl }
}
struct MerchantTotal: Identifiable { let id: String; let total: Decimal; let count: Int }
struct Recurring: Identifiable { let id: String; let name: String; let amount: Decimal; let count: Int }
struct ReviewItem: Identifiable { let id: String; let name: String; let count: Int; let total: Decimal }
struct BudgetTarget: Identifiable { let id: String }
struct Toast: Identifiable { let id = UUID(); let text: String; let canUndo: Bool }
struct DayGroup: Identifiable { let date: Date; let items: [Tx]; let total: Decimal; var id: Date { date } }

struct MonthStats {
    var period: Period
    var isCurrent = true
    var txs: [Tx] = []                    // everything in the period, newest first
    var total: Decimal = 0
    var countedCount = 0
    var prevTotal: Decimal = 0            // same span of the previous period
    var cats: [Part] = []
    var banks: [Part] = []
    var days: [DayTotal] = []             // newest first
    var dailyAvg: Decimal = 0
    var projected: Decimal?
    var biggest: Tx?
    var merchants: [MerchantTotal] = []
    var busiestDay: String?
    var summary: String {
        var s = "Spends – \(period.title)\nTotal: \(inr(total))\n"
        for c in cats where c.value != 0 { s += "\(c.id): \(inr(c.value))\n" }
        return s
    }
}

struct TodayStats {
    var txs: [Tx] = []
    var total: Decimal = 0
    var count = 0
    var avg: Decimal?                     // average of the last 30 days
    var week: [DayTotal] = []
    var allowance: Decimal?               // today's share of the remaining monthly budget
    var left: Decimal?
}

enum SyncState: Equatable {
    case noFile, loading, synced(Date), missing, unreadable, sample
}

// MARK: - Grouping helpers (pure, safe to call off the main thread)

func groupByDay(_ txs: [Tx]) -> [DayGroup] {
    let cal = Calendar.current
    var out: [DayGroup] = []
    var curDay: Date?
    var items: [Tx] = []
    var total = Decimal.zero
    for t in txs {
        let d = cal.startOfDay(for: t.date)
        if d != curDay {
            if let c = curDay { out.append(DayGroup(date: c, items: items, total: total)) }
            curDay = d; items = []; total = 0
        }
        items.append(t)
        if t.counted { total += t.amt }
    }
    if let c = curDay { out.append(DayGroup(date: c, items: items, total: total)) }
    return out
}

func buildGroups(_ src: [Tx], cat: String, bank: String, query: String) -> [DayGroup] {
    let filtered = src.filter { t in
        if cat != "All" && t.cat != cat { return false }
        if bank != "All" && t.bank != bank { return false }
        if !query.isEmpty && !t.hay.contains(query) { return false }
        return true
    }
    return groupByDay(filtered)
}

// =====================================================================================
// MARK: - Engine: file access, incremental parsing, disk cache (all off the main thread)
// =====================================================================================

struct Stamp: Equatable, Sendable { var date: Date?; var size: Int? }
enum ReadOutcome: Sendable { case unchanged, failed, data(Data, Stamp?) }
enum LoadResult: Sendable { case unchanged, noFile, missing, unreadable, updated([Tx], Int) }

actor Engine {
    private var committed: [Tx] = []
    private var seen: [String: Int] = [:]
    private var parsedBytes = 0
    private var tailSig = Data()
    private var bad = 0
    private var lastStamp: Stamp?
    private var generation = 0
    private var dayCache: [String: Date] = [:]
    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Public

    func reset() {
        generation += 1
        committed = []; seen = [:]; parsedBytes = 0; tailSig = Data(); bad = 0
        lastStamp = nil; dayCache = [:]
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Instant first frame: parse the cached copy of the CSV.
    func loadCache() -> ([Tx], Int)? {
        guard UserDefaults.standard.data(forKey: Keys.bookmark) != nil,
              let d = try? Data(contentsOf: cacheURL), !d.isEmpty else { return nil }
        let txs = process(d, force: true)
        return (txs, bad)
    }

    func load(force: Bool) async -> LoadResult {
        switch resolve() {
        case .none: return .noFile
        case .missing: return .missing
        case .url(let url):
            let gen = generation
            let outcome = await Self.read(url, last: force ? nil : lastStamp)
            guard gen == generation else { return .unchanged }
            switch outcome {
            case .unchanged: return .unchanged
            case .failed: return .unreadable
            case .data(let d, let st):
                lastStamp = st
                let txs = process(d, force: force)
                writeCache(d)
                return .updated(txs, bad)
            }
        }
    }

    // MARK: File access

    private enum Resolved { case none, missing, url(URL) }

    private func resolve() -> Resolved {
        guard let b = UserDefaults.standard.data(forKey: Keys.bookmark) else { return .none }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale) else { return .missing }
        if stale {   // refresh the bookmark so it never silently expires
            let ok = url.startAccessingSecurityScopedResource()
            if let nb = try? url.bookmarkData() { UserDefaults.standard.set(nb, forKey: Keys.bookmark) }
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return .url(url)
    }

    /// Reads on a background queue; skips the read entirely when modification date and size are unchanged.
    private static func read(_ url: URL, last: Stamp?) async -> ReadOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<ReadOutcome, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let stamp = Stamp(date: rv?.contentModificationDate, size: rv?.fileSize)
                if let last, stamp.date != nil, stamp == last {
                    cont.resume(returning: .unchanged)
                    return
                }
                var err: NSError?
                var data: Data?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
                    data = try? Data(contentsOf: u)
                }
                if let data { cont.resume(returning: .data(data, stamp)) }
                else { cont.resume(returning: .failed) }
            }
        }
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spends-cache.csv")
    }

    private func writeCache(_ d: Data) {
        let url = cacheURL
        DispatchQueue.global(qos: .background).async { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Parsing (incremental when the file was only appended to)

    private func process(_ data: Data, force: Bool) -> [Tx] {
        let n = data.count
        var incremental = false
        if !force, parsedBytes > 0, n >= parsedBytes {
            let from = max(0, parsedBytes - 64)
            incremental = data.subdata(in: from..<parsedBytes) == tailSig
        }
        if !incremental {
            committed = []; seen = [:]; parsedBytes = 0; tailSig = Data(); bad = 0; dayCache = [:]
        }
        // Commit only complete lines
        if let nl = data[parsedBytes..<n].lastIndex(of: 0x0A) {
            let end = nl + 1
            let parsed = parseChunk(data[parsedBytes..<end], seen: &seen, bad: &bad)
            committed.append(contentsOf: parsed)
            parsedBytes = end
            tailSig = data.subdata(in: max(0, end - 64)..<end)
        }
        var result = committed
        if parsedBytes < n {   // last line without a newline yet: show it, don't commit it
            var tmpSeen = seen
            var tmpBad = 0
            result.append(contentsOf: parseChunk(data[parsedBytes..<n], seen: &tmpSeen, bad: &tmpBad))
        }
        return result.sorted { a, b in a.date != b.date ? a.date > b.date : a.id > b.id }
    }

    private func parseChunk(_ chunk: Data, seen: inout [String: Int], bad: inout Int) -> [Tx] {
        var out: [Tx] = []
        let text = String(decoding: chunk, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let p = parseLine(line) else { bad += 1; continue }
            // Stable id: the raw line plus an occurrence counter (handles genuine duplicates)
            let key = String(line)
            let n = seen[key, default: 0]
            seen[key] = n + 1
            out.append(Tx.make(id: "\(key)#\(n)", date: p.date, src: p.src, last4: p.last4, amt: p.amt, merchant: p.merchant))
        }
        return out
    }

    private func parseLine(_ l: Substring) -> (date: Date, src: String, last4: String, amt: Decimal, merchant: String)? {
        guard let i = l.firstIndex(of: ",") else { return nil }
        guard let date = parseDate(l[..<i]) else { return nil }
        let p = l[l.index(after: i)...]
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count >= 4 else { return nil }
        let amtText = p[2].replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "₹", with: "")
        guard let amt = Decimal(string: amtText, locale: Locale(identifier: "en_US_POSIX")), !amt.isNaN else { return nil }
        return (date, p[0], p[1], amt, p[3...].joined(separator: "|"))
    }

    /// "yyyy-MM-dd HH:mm" without a DateFormatter per line (day start is cached)
    private func parseDate(_ s: Substring) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 16 else { return nil }
        let dayKey = String(t.prefix(10))
        guard let hh = Int(t.dropFirst(11).prefix(2)), let mm = Int(t.dropFirst(14).prefix(2)),
              (0..<24).contains(hh), (0..<60).contains(mm) else { return nil }
        let day: Date
        if let c = dayCache[dayKey] { day = c }
        else {
            guard let d = dayFmt.date(from: dayKey) else { return nil }
            dayCache[dayKey] = d
            day = d
        }
        return day.addingTimeInterval(TimeInterval(hh * 3600 + mm * 60))
    }
}

// MARK: - Sample data (demo mode)

struct LCG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s
    }
}

enum Sample {
    static func make() -> [Tx] {
        var rng = LCG(s: 42)
        let cal = Calendar.current
        let sod = cal.startOfDay(for: .now)
        let cards = [("HDFC Credit Card", "4321"), ("AU Bank Credit Card", "8890"), ("SBI Account", "1122")]
        let pool: [(String, Int, Int)] = [
            ("SWIGGY*ORD", 180, 650), ("ZOMATO", 200, 700), ("BLINKIT", 250, 1400), ("UBER *TRIP", 120, 480),
            ("AMAZON PAY INDIA", 300, 3500), ("MYNTRA", 700, 2800), ("APOLLO PHARMACY", 150, 900),
            ("BOOKMYSHOW", 300, 900), ("STARBUCKS", 250, 600), ("IRCTC", 400, 2200), ("Coca Cola Stall", 40, 120)
        ]
        var out: [Tx] = []
        for day in 0..<130 {
            guard let d0 = cal.date(byAdding: .day, value: -day, to: sod) else { continue }
            let count = Int.random(in: 1...4, using: &rng)
            for i in 0..<count {
                let item = pool.randomElement(using: &rng)!
                let card = cards.randomElement(using: &rng)!
                let amt = Int.random(in: item.1...item.2, using: &rng)
                let minutes = Int.random(in: 8 * 60...22 * 60, using: &rng)
                guard let date = cal.date(byAdding: .minute, value: minutes, to: d0), date <= .now else { continue }
                let merchant = item.0.hasSuffix("ORD") ? "\(item.0)\(Int.random(in: 100...999, using: &rng))" : item.0
                out.append(Tx.make(id: "sample-\(day)-\(i)", date: date, src: card.0, last4: card.1,
                                   amt: Decimal(amt), merchant: merchant))
            }
            let dom = cal.component(.day, from: d0)
            if dom == 5, let date = cal.date(byAdding: .minute, value: 9 * 60, to: d0) {
                out.append(Tx.make(id: "sample-nf-\(day)", date: date, src: cards[0].0, last4: cards[0].1, amt: 649, merchant: "NETFLIX.COM"))
            }
            if dom == 12, let date = cal.date(byAdding: .minute, value: 10 * 60, to: d0) {
                out.append(Tx.make(id: "sample-jio-\(day)", date: date, src: cards[1].0, last4: cards[1].1, amt: 299, merchant: "JIO RECHARGE"))
            }
        }
        return out.sorted { a, b in a.date != b.date ? a.date > b.date : a.id > b.id }
    }
}

// =====================================================================================
// MARK: - Store
// =====================================================================================

@MainActor @Observable final class Store {
    // Data
    var ledger: [Tx] = []
    var hasData = false
    var banks: [String] = []
    var today = TodayStats()
    var month = MonthStats(period: Period.placeholder)
    var periods: [Period] = []
    var history: [PeriodTotal] = []
    var recurring: [Recurring] = []
    var review: [ReviewItem] = []
    var version = 0
    var now = Date()

    // Sync
    var sync: SyncState = .noFile
    var skipped = 0
    var newSpendTick = 0

    // UI
    var detailTx: Tx?
    var budgetTarget: BudgetTarget?
    var showPicker = false
    var toast: Toast?
    var locked = false

    // Settings (persisted)
    var overrides: [String: String] = [:]
    var txOverrides: [String: String] = [:]
    var excluded: Set<String> = []
    var budgets: [String: Double] = [:]
    var hideTransfers = false
    var dedupe = false
    var cycleDay = 1
    var masked = false
    var coverEnabled = true
    var lockEnabled = false

    @ObservationIgnored private var raw: [Tx] = []
    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isSample = false
    @ObservationIgnored private var lastUpdate: Date?
    @ObservationIgnored private var selectedAnchor: Date?
    @ObservationIgnored private var anchorCache: [Int: Date] = [:]
    @ObservationIgnored private var cal = Calendar.current
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var undoState: Undo?
    @ObservationIgnored private var needsPrompt = false
    @ObservationIgnored private var unlocking = false

    private struct Undo { var ov: [String: String]; var tov: [String: String]; var ex: Set<String> }

    init() {
        let d = UserDefaults.standard
        // Old overrides were keyed by the uppercased raw merchant; normalise them to the new key
        var ov: [String: String] = [:]
        for (k, v) in (d.dictionary(forKey: Keys.overrides) as? [String: String] ?? [:]) { ov[Merchant.key(k)] = v }
        overrides = ov
        txOverrides = d.dictionary(forKey: Keys.txOverrides) as? [String: String] ?? [:]
        excluded = Set(d.stringArray(forKey: Keys.excluded) ?? [])
        budgets = d.dictionary(forKey: Keys.budgets) as? [String: Double] ?? [:]
        hideTransfers = d.bool(forKey: Keys.hideTransfers)
        dedupe = d.bool(forKey: Keys.dedupe)
        let c = d.integer(forKey: Keys.cycleDay)
        cycleDay = (1...28).contains(c) ? c : 1
        masked = d.bool(forKey: Keys.masked)
        coverEnabled = d.object(forKey: Keys.cover) as? Bool ?? true
        lockEnabled = d.bool(forKey: Keys.lock)
        if lockEnabled { locked = true; needsPrompt = true }
        month = MonthStats(period: period(containing: now))
    }

    func m(_ d: Decimal) -> String { masked ? "₹•••••" : inr(d) }

    // MARK: Lifecycle

    func phaseChanged(_ p: ScenePhase) {
        if p == .background, lockEnabled { locked = true; needsPrompt = true }
        if p == .active {
            tickNow()
            if locked && needsPrompt { needsPrompt = false; Task { await unlock() } }
        }
    }

    func startup() async {
        guard !started else { return }
        started = true
        if let (txs, bad) = await engine.loadCache(), !txs.isEmpty {
            apply(txs, bad: bad)
            sync = .loading
        }
        await refresh()
    }

    func refresh(force: Bool = false) async {
        guard !isSample else { return }
        switch await engine.load(force: force) {
        case .unchanged:
            if sync == .loading { sync = .synced(lastUpdate ?? Date()) }
        case .noFile: sync = .noFile
        case .missing: sync = .missing
        case .unreadable: sync = .unreadable
        case .updated(let txs, let bad):
            apply(txs, bad: bad)
            lastUpdate = Date()
            sync = .synced(lastUpdate ?? Date())
        }
    }

    func chooseFile(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let b = try? url.bookmarkData() { UserDefaults.standard.set(b, forKey: Keys.bookmark) }
        isSample = false
        sync = .loading
        Task {
            await engine.reset()
            await refresh(force: true)
        }
    }

    func useSample() {
        isSample = true
        apply(Sample.make(), bad: 0)
        sync = .sample
    }

    private func apply(_ txs: [Tx], bad: Int) {
        let known = Set(raw.prefix(100).map { $0.id })
        let added = loaded && txs.prefix(100).contains { !known.contains($0.id) }
        raw = txs
        skipped = bad
        now = Date()
        if loaded { withAnimation(.snappy) { recompute() } } else { recompute() }
        if added { newSpendTick += 1 }
        loaded = true
    }

    /// Midnight rollover: "Today" and the current month stay correct without any file change
    func tickNow() {
        let n = Date()
        cal = Calendar.current
        if !cal.isDate(n, inSameDayAs: now) {
            now = n
            derive()
        }
    }

    // MARK: Face ID

    func unlock() async {
        guard locked, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your spends")
            if ok { locked = false }
        } catch {}
    }

    // MARK: Periods

    func period(containing d: Date) -> Period {
        let off = cycleDay - 1
        let shifted = cal.date(byAdding: .day, value: -off, to: d) ?? d
        let anchor = cal.dateInterval(of: .month, for: shifted)?.start ?? cal.startOfDay(for: shifted)
        return period(anchor: anchor)
    }

    func period(anchor: Date) -> Period {
        let off = cycleDay - 1
        let start = cal.date(byAdding: .day, value: off, to: anchor) ?? anchor
        let next = cal.date(byAdding: .month, value: 1, to: anchor) ?? anchor
        let end = cal.date(byAdding: .day, value: off, to: next) ?? next
        return Period(anchor: anchor, start: start, end: end, cycleDay: cycleDay)
    }

    func selectPeriod(_ anchor: Date) {
        selectedAnchor = (anchor == period(containing: now).anchor) ? nil : anchor
        derive()
    }

    func shiftMonth(_ n: Int) {
        guard let new = cal.date(byAdding: .month, value: n, to: month.period.anchor) else { return }
        if new > period(containing: now).anchor { return }
        selectPeriod(new)
    }

    private func dayIndex(_ d: Date) -> Int {
        Int(floor((d.timeIntervalSinceReferenceDate + Double(cal.timeZone.secondsFromGMT(for: d))) / 86400))
    }

    private func anchor(of d: Date) -> Date {
        let i = dayIndex(d)
        if let a = anchorCache[i] { return a }
        let a = period(containing: d).anchor
        anchorCache[i] = a
        return a
    }

    private func span(_ p: Period, current: Bool) -> (total: Int, elapsed: Int) {
        let total = max(cal.dateComponents([.day], from: p.start, to: p.end).day ?? 30, 1)
        guard current else { return (total, total) }
        let sod = cal.startOfDay(for: now)
        let e = (cal.dateComponents([.day], from: p.start, to: sod).day ?? 0) + 1
        return (total, min(max(e, 1), total))
    }

    // MARK: Recompute (single pass each; never inside a view body)

    /// Resolve categories/exclusions, then rebuild everything derived from the ledger.
    func recompute() {
        version &+= 1
        let ov = overrides, tov = txOverrides, ex = excluded, hide = hideTransfers
        var l = raw
        for i in l.indices {
            let c = tov[l[i].id] ?? ov[l[i].key] ?? l[i].auto
            l[i].cat = c
            if ex.contains(l[i].id) { l[i].reason = .excluded }
            else if hide && c == "Transfers" { l[i].reason = .transfer }
            else { l[i].reason = nil }
        }
        if dedupe {   // same card + amount + merchant within 2 minutes → counted once
            var last: [String: Date] = [:]
            for i in l.indices.reversed() {   // oldest first
                let t = l[i]
                let sig = "\(t.src)|\(t.last4)|\(t.amt)|\(t.key)"
                if let d = last[sig], t.date.timeIntervalSince(d) < 120 {
                    if l[i].reason == nil { l[i].reason = .duplicate }
                } else {
                    last[sig] = t.date
                }
            }
        }
        ledger = l
        hasData = !l.isEmpty
        banks = Set(l.map { $0.bank }).sorted()

        // Needs-a-category inbox
        var rv: [String: (name: String, n: Int, total: Decimal)] = [:]
        for t in l where t.cat == "Other" && ov[t.key] == nil && tov[t.id] == nil && t.counted {
            let e = rv[t.key] ?? (t.name, 0, Decimal.zero)
            rv[t.key] = (e.name, e.n + 1, e.total + t.amt)
        }
        review = rv.map { ReviewItem(id: $0.key, name: $0.value.name, count: $0.value.n, total: $0.value.total) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        review = Array(review.prefix(40))

        // Totals per period (history chart)
        var tot: [Date: Decimal] = [:]
        for t in l where t.counted { tot[anchor(of: t.date), default: 0] += t.amt }
        history = tot.map { PeriodTotal(anchor: $0.key, total: $0.value) }.sorted { $0.anchor < $1.anchor }

        recurring = detectRecurring(l)
        derive()
    }

    private func detectRecurring(_ l: [Tx]) -> [Recurring] {
        let groups = Dictionary(grouping: l.filter { $0.counted && $0.amt > 0 }, by: { $0.key })
        var out: [Recurring] = []
        for (k, g) in groups where g.count >= 3 && !k.isEmpty {
            let s = g.sorted { $0.date < $1.date }
            var gaps: [Double] = []
            for i in 1..<s.count { gaps.append(s[i].date.timeIntervalSince(s[i - 1].date) / 86400) }
            gaps.sort()
            guard (25.0...35.0).contains(gaps[gaps.count / 2]) else { continue }
            let amts = s.map { $0.amt.dbl }.sorted()
            let med = amts[amts.count / 2]
            guard med > 0, let lo = amts.first, let hi = amts.last, hi - lo <= med * 0.15 else { continue }
            guard let lastSeen = s.last, now.timeIntervalSince(lastSeen.date) < 45 * 86400 else { continue }
            out.append(Recurring(id: k, name: lastSeen.name, amount: lastSeen.amt, count: s.count))
        }
        return out.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.name < $1.name }
    }

    private func parts(_ dict: [String: Decimal], color: (String) -> Color) -> [Part] {
        let arr = dict.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let pc = percents(arr.map { max($0.1.dbl, 0) })
        return arr.indices.map { Part(id: arr[$0].0, value: arr[$0].1, pct: pc[$0], color: color(arr[$0].0)) }
    }

    /// Cheap rebuild of today + selected month (runs when month, day or ledger changes)
    func derive() {
        cal = Calendar.current
        let cur = period(containing: now)
        let sel = selectedAnchor.map { period(anchor: $0) } ?? cur
        let isCur = sel.anchor == cur.anchor
        let (totalDays, elapsed) = span(sel, current: isCur)

        // ---- Selected month
        let inPeriod = ledger.filter { $0.date >= sel.start && $0.date < sel.end }
        let counted = inPeriod.filter { $0.counted }
        let total = counted.reduce(Decimal.zero) { $0 + $1.amt }

        // Compare the same number of days of the previous period
        let prevAnchor = cal.date(byAdding: .month, value: -1, to: sel.anchor) ?? sel.anchor
        let prevStart = period(anchor: prevAnchor).start
        let prevEnd = min(cal.date(byAdding: .day, value: elapsed, to: prevStart) ?? sel.start, sel.start)
        var prevTotal = Decimal.zero
        for t in ledger where t.counted && t.date >= prevStart && t.date < prevEnd { prevTotal += t.amt }

        var byCat: [String: Decimal] = [:]
        var byBank: [String: Decimal] = [:]
        var byDay: [Date: Decimal] = [:]
        var mt: [String: (Decimal, Int)] = [:]
        var wd: [Int: Decimal] = [:]
        for t in counted {
            byCat[t.cat, default: 0] += t.amt
            byBank[t.bank, default: 0] += t.amt
            byDay[cal.startOfDay(for: t.date), default: 0] += t.amt
            if t.amt > 0 {
                let e = mt[t.name] ?? (Decimal.zero, 0)
                mt[t.name] = (e.0 + t.amt, e.1 + 1)
                wd[cal.component(.weekday, from: t.date), default: 0] += t.amt
            }
        }
        for k in budgets.keys where k != "All" && byCat[k] == nil { byCat[k] = 0 }

        let bankList = banks
        let dayRows = byDay.map { ($0.key, $0.value) }.sorted { $0.0 > $1.0 }
        let dayPct = percents(dayRows.map { max($0.1.dbl, 0) })

        var ms = MonthStats(period: sel)
        ms.isCurrent = isCur
        ms.txs = inPeriod
        ms.total = total
        ms.countedCount = counted.count
        ms.prevTotal = prevTotal
        ms.cats = parts(byCat) { Cats.color($0) }
        ms.banks = parts(byBank) { b in
            let palette: [Color] = [.indigo, .pink, .mint, .orange, .cyan, .brown, .purple, .green]
            return palette[(bankList.firstIndex(of: b) ?? 0) % palette.count]
        }
        ms.days = dayRows.indices.map { DayTotal(date: dayRows[$0].0, total: dayRows[$0].1, pct: dayPct[$0]) }
        ms.dailyAvg = total / Decimal(max(elapsed, 1))
        if isCur && elapsed >= 3 { ms.projected = total / Decimal(elapsed) * Decimal(totalDays) }
        ms.biggest = counted.filter { $0.amt > 0 }.max { $0.amt < $1.amt }
        ms.merchants = mt.map { MerchantTotal(id: $0.key, total: $0.value.0, count: $0.value.1) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
        ms.merchants = Array(ms.merchants.prefix(5))
        if counted.count >= 7, let top = wd.max(by: { $0.value < $1.value }) {
            ms.busiestDay = cal.weekdaySymbols[top.key - 1]
        }
        month = ms

        var set = Set(history.map { $0.anchor })
        set.insert(cur.anchor); set.insert(sel.anchor)
        periods = set.sorted(by: >).map { period(anchor: $0) }

        // ---- Today
        let sod = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: sod) ?? sod
        let todayTx = ledger.filter { $0.date >= sod && $0.date < tomorrow }
        let todayTotal = todayTx.reduce(Decimal.zero) { $1.counted ? $0 + $1.amt : $0 }

        let weekStart = cal.date(byAdding: .day, value: -6, to: sod) ?? sod
        var wk: [Date: Decimal] = [:]
        for t in ledger where t.counted && t.date >= weekStart && t.date < tomorrow {
            wk[cal.startOfDay(for: t.date), default: 0] += t.amt
        }
        let week: [DayTotal] = (0..<7).map { i in
            let d = cal.startOfDay(for: cal.date(byAdding: .day, value: i - 6, to: sod) ?? sod)
            return DayTotal(date: d, total: wk[d] ?? 0, pct: 0)
        }

        var avg: Decimal?
        if let oldest = ledger.last?.date {
            let start30 = cal.date(byAdding: .day, value: -30, to: sod) ?? sod
            var sum30 = Decimal.zero
            for t in ledger where t.counted && t.date >= start30 && t.date < sod { sum30 += t.amt }
            let histDays = max(min(cal.dateComponents([.day], from: cal.startOfDay(for: oldest), to: sod).day ?? 0, 30), 0)
            if histDays >= 3 { avg = sum30 / Decimal(histDays) }
        }

        var allowance: Decimal?
        var left: Decimal?
        if let b = budgets["All"] {
            let curTotal: Decimal = isCur ? total : ledger.reduce(Decimal.zero) {
                ($1.counted && $1.date >= cur.start && $1.date < cur.end) ? $0 + $1.amt : $0
            }
            let cs = span(cur, current: true)
            let remainingDays = max(cs.total - cs.elapsed + 1, 1)
            let before = curTotal - todayTotal
            let a = (Decimal(b) - before) / Decimal(remainingDays)
            allowance = a
            left = a - todayTotal
        }

        today = TodayStats(txs: todayTx, total: todayTotal, count: todayTx.filter { $0.counted }.count,
                           avg: avg, week: week, allowance: allowance, left: left)
    }

    // MARK: Editing

    private func snapshot() -> Undo { Undo(ov: overrides, tov: txOverrides, ex: excluded) }

    private func persistRules() {
        let d = UserDefaults.standard
        d.set(overrides, forKey: Keys.overrides)
        d.set(txOverrides, forKey: Keys.txOverrides)
        d.set(Array(excluded), forKey: Keys.excluded)
    }

    func assign(_ t: Tx, to c: String, all: Bool) {
        let u = snapshot()
        let msg: String
        if all {
            overrides[t.key] = c
            let ids = ledger.filter { $0.key == t.key }.map { $0.id }
            for id in ids { txOverrides[id] = nil }
            msg = "Moved \(ids.count) \(t.name) spend\(ids.count == 1 ? "" : "s") to \(c)"
        } else {
            txOverrides[t.id] = c
            msg = "Moved 1 spend to \(c)"
        }
        persistRules(); recompute(); show(msg, undo: u)
    }

    func assign(key: String, name: String, count: Int, to c: String) {
        let u = snapshot()
        overrides[key] = c
        persistRules(); recompute()
        show("Moved \(count) \(name) spend\(count == 1 ? "" : "s") to \(c)", undo: u)
    }

    func resetCategory(_ t: Tx) {
        let u = snapshot()
        overrides[t.key] = nil
        txOverrides[t.id] = nil
        persistRules(); recompute(); show("Category reset to automatic", undo: u)
    }

    func removeOverride(_ key: String) {
        overrides[key] = nil
        persistRules(); recompute()
    }

    func resetAllOverrides() {
        let u = snapshot()
        overrides = [:]; txOverrides = [:]
        persistRules(); recompute(); show("All learned categories cleared", undo: u)
    }

    func toggleExclude(_ t: Tx) {
        let u = snapshot()
        let wasExcluded = excluded.contains(t.id)
        if wasExcluded { excluded.remove(t.id) } else { excluded.insert(t.id) }
        persistRules(); recompute()
        show(wasExcluded ? "Included in totals" : "Excluded from totals", undo: u)
    }

    func undo() {
        guard let u = undoState else { return }
        overrides = u.ov; txOverrides = u.tov; excluded = u.ex
        persistRules(); recompute()
        toast = nil
    }

    private func show(_ text: String, undo: Undo?) {
        undoState = undo
        toast = Toast(text: text, canUndo: undo != nil)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Settings

    func setBudget(_ id: String, _ v: Double?) {
        budgets[id] = v
        UserDefaults.standard.set(budgets, forKey: Keys.budgets)
        derive()
    }
    func setHideTransfers(_ v: Bool) {
        hideTransfers = v
        UserDefaults.standard.set(v, forKey: Keys.hideTransfers)
        recompute()
    }
    func setDedupe(_ v: Bool) {
        dedupe = v
        UserDefaults.standard.set(v, forKey: Keys.dedupe)
        recompute()
    }
    func setCycleDay(_ v: Int) {
        cycleDay = min(max(v, 1), 28)
        UserDefaults.standard.set(cycleDay, forKey: Keys.cycleDay)
        anchorCache = [:]
        selectedAnchor = nil
        recompute()
    }
    func toggleMask() {
        masked.toggle()
        UserDefaults.standard.set(masked, forKey: Keys.masked)
    }
    func setCover(_ v: Bool) { coverEnabled = v; UserDefaults.standard.set(v, forKey: Keys.cover) }
    func setLock(_ v: Bool) { lockEnabled = v; UserDefaults.standard.set(v, forKey: Keys.lock) }
}

// =====================================================================================
// MARK: - Export
// =====================================================================================

struct CSVExport: Transferable {
    let txs: [Tx]
    let name: String

    func csv() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "Date,Source,Last4,Amount,Merchant,Category,Counted\r\n"
        for t in txs {
            s += "\(f.string(from: t.date)),\(csvEscape(t.src)),\(csvEscape(t.last4)),\(t.amt),\(csvEscape(t.merchant)),\(csvEscape(t.cat)),\(t.counted ? "yes" : "no")\r\n"
        }
        return s
    }

    // Built lazily: only when the user actually taps Share
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            let safe = item.name.replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("spends-\(safe).csv")
            try Data(item.csv().utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

// =====================================================================================
// MARK: - Small shared views
// =====================================================================================

struct Logo: View {
    var size: CGFloat = 30
    var body: some View {
        Group {
            if UIImage(named: "AppLogo") != nil {
                Image("AppLogo").resizable().scaledToFit()
            } else {
                Image(systemName: "indianrupeesign.circle.fill").resizable().scaledToFit().foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

struct CatBadge: View {
    let cat: String
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: Cats.symbol(cat))
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Cats.color(cat), in: Circle())
            .accessibilityHidden(true)
    }
}

struct SyncLabel: View {
    @Environment(Store.self) private var store
    var body: some View {
        Group {
            switch store.sync {
            case .noFile: Text("No file chosen")
            case .loading: Text("Reading…")
            case .synced(let d): Text("Updated \(d, style: .relative) ago")
            case .missing: Text("File not found – choose it again").foregroundStyle(.orange)
            case .unreadable: Text("Couldn't read the file").foregroundStyle(.orange)
            case .sample: Text("Sample data")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct SpendRow: View {
    @Environment(Store.self) private var store
    let t: Tx

    private var subtitle: String {
        var s = "\(t.src) \(t.last4) · \(Fmt.time.string(from: t.date))"
        if let r = t.reason { s += " · not counted (\(r.label))" }
        return s
    }

    var body: some View {
        Button { store.detailTx = t } label: {
            HStack(spacing: 12) {
                CatBadge(cat: t.cat)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(store.m(t.amt)).bold().monospacedDigit()
                    .foregroundStyle(t.amt < 0 ? Color.green : Color.primary)
            }
            .opacity(t.counted ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button { store.detailTx = t } label: { Label("Category", systemImage: "tag") }.tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            if t.counted || t.reason == .excluded {
                Button { store.toggleExclude(t) } label: {
                    Label(t.counted ? "Exclude" : "Include", systemImage: t.counted ? "eye.slash" : "eye")
                }.tint(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(t.name), \(store.m(t.amt)), \(t.cat), \(t.src) \(t.last4), \(Fmt.time.string(from: t.date))")
        .accessibilityHint("Opens details")
    }
}

struct DayHeader: View {
    @Environment(Store.self) private var store
    let g: DayGroup
    var body: some View {
        HStack {
            Text(dayTitle(g.date))
            Spacer()
            Text(store.m(g.total))
        }
    }
}

struct Chip: View {
    let title: String
    let icon: String
    let active: Bool
    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? Color.indigo.opacity(0.18) : Color(.secondarySystemGroupedBackground), in: Capsule())
            .foregroundStyle(active ? Color.indigo : Color.primary)
    }
}

struct DonutView: View {
    @Environment(Store.self) private var store
    let parts: [Part]
    let total: Decimal
    @State private var angle: Double?

    private var selected: Part? {
        guard let a = angle else { return nil }
        var acc = 0.0
        for p in parts { acc += p.dbl; if a <= acc { return p } }
        return nil
    }

    var body: some View {
        Chart(parts) { p in
            SectorMark(angle: .value("Spent", p.dbl), innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(p.color)
                .opacity(selected == nil || selected?.id == p.id ? 1 : 0.35)
        }
        .chartAngleSelection(value: $angle)
        .chartLegend(.hidden)
        .frame(height: 240)
        .overlay {
            VStack {
                Text(selected?.id ?? "Total").font(.caption).foregroundStyle(.secondary)
                Text(store.m(selected?.value ?? total)).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1)
            }
            .padding(.horizontal, 44)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending breakdown. " + parts.map { "\($0.id) \($0.pct) percent" }.joined(separator: ", "))
    }
}

// =====================================================================================
// MARK: - Today
// =====================================================================================

struct WeekChart: View {
    let days: [DayTotal]
    var body: some View {
        Chart(days) { d in
            BarMark(x: .value("Day", d.date, unit: .day), y: .value("Spent", max(d.dbl, 0)))
                .foregroundStyle(Calendar.current.isDateInToday(d.date) ? Color.indigo : Color.secondary.opacity(0.35))
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .frame(height: 90)
        .accessibilityLabel("Spending over the last 7 days")
    }
}

struct TodayView: View {
    @Environment(Store.self) private var store
    private var today: TodayStats { store.today }

    var body: some View {
        NavigationStack {
            List {
                Section { hero }
                Section("Last 7 days") { WeekChart(days: today.week) }
                Section {
                    if today.txs.isEmpty {
                        Label("No spends yet today", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        ForEach(today.txs) { SpendRow(t: $0) }
                    }
                } header: {
                    Text("Today's spends")
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo(size: 28) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.toggleMask() } label: { Image(systemName: store.masked ? "eye.slash" : "eye") }
                        .accessibilityLabel(store.masked ? "Show amounts" : "Hide amounts")
                }
            }
            .refreshable { await store.refresh(force: true) }
            .sensoryFeedback(.success, trigger: store.newSpendTick)
            .overlay { if !store.hasData { EmptyStateView() } }
        }
    }

    @ViewBuilder private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(store.m(today.total))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: today.total)
                .onTapGesture { store.toggleMask() }
            Text("\(today.count) spend\(today.count == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary)
            if let avg = today.avg { contextLine(avg) }
            budgetLine
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func contextLine(_ avg: Decimal) -> some View {
        let diff = today.total - avg
        if abs(diff) < 1 {
            Text("In line with your daily average").font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("\(store.m(abs(diff))) \(diff > 0 ? "above" : "below") your daily average")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(diff > 0 ? Color.orange : Color.green)
        }
    }

    @ViewBuilder private var budgetLine: some View {
        if let a = today.allowance {
            if a <= 0 {
                Text("Monthly budget already used up").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            } else if let l = today.left {
                if l >= 0 {
                    Text("\(store.m(l)) left today to stay on budget")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Text("\(store.m(-l)) over today's allowance")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
    }
}

// =====================================================================================
// MARK: - Month
// =====================================================================================

enum Scope: Hashable {
    case cat(String), bank(String), day(Date), merchant(String)
    func matches(_ t: Tx) -> Bool {
        switch self {
        case .cat(let c): return t.cat == c
        case .bank(let b): return t.bank == b
        case .day(let d): return Calendar.current.isDate(t.date, inSameDayAs: d)
        case .merchant(let n): return t.name == n
        }
    }
}

struct TxListScreen: View {
    @Environment(Store.self) private var store
    let title: String
    let scope: Scope
    @State private var todayOnly = false

    var body: some View {
        let all = store.month.txs.filter { scope.matches($0) }
        let shown = todayOnly ? all.filter { Calendar.current.isDateInToday($0.date) } : all
        let groups = groupByDay(shown)
        List {
            Section {
                if case .bank = scope {
                    Picker("Scope", selection: $todayOnly) {
                        Text("Today").tag(true)
                        Text(store.month.period.title).tag(false)
                    }.pickerStyle(.segmented)
                }
                HStack {
                    Text(store.m(shown.reduce(Decimal.zero) { $1.counted ? $0 + $1.amt : $0 }))
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Spacer()
                    Text("\(shown.count) spends").foregroundStyle(.secondary)
                }
                if shown.isEmpty { Text("No spends").foregroundStyle(.secondary) }
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.items) { SpendRow(t: $0) }
                } header: { DayHeader(g: g) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MonthView: View {
    @Environment(Store.self) private var store

    enum Mode: String, CaseIterable, Identifiable {
        case category = "Category", day = "Day", bank = "Bank", history = "History"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .category
    private var m: MonthStats { store.month }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                chartSections
                insightSections
            }
            .navigationTitle("Month")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh(force: true) }
            .overlay { if !store.hasData { EmptyStateView() } }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            HStack {
                Button { store.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("Previous month")
                Spacer()
                Menu {
                    ForEach(store.periods) { p in
                        Button(p.title) { store.selectPeriod(p.anchor) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(m.period.title).font(.headline)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                }
                Spacer()
                Button { store.shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(m.isCurrent).accessibilityLabel("Next month")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(store.m(m.total))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: m.total)
                if m.prevTotal > 0 { compareLine }
                if let p = m.projected {
                    Text("On pace for \(store.m(p))").font(.subheadline).foregroundStyle(.secondary)
                }
                budgetBlock
                HStack(spacing: 4) {
                    Text("\(m.countedCount) spends ·")
                    SyncLabel()
                }
                .font(.footnote).foregroundStyle(.secondary)
                if store.skipped > 0 {
                    Text("\(store.skipped) lines couldn't be read").font(.footnote).foregroundStyle(.orange)
                }
                if m.txs.isEmpty { Text("No spends in this period").font(.footnote).foregroundStyle(.secondary) }
            }
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var compareLine: some View {
        let up = m.total >= m.prevTotal
        let pct = Int(((m.total - m.prevTotal) / m.prevTotal * 100).dbl.rounded())
        Text("\(up ? "▲" : "▼") \(abs(pct))% \(m.isCurrent ? "vs same days last month" : "vs previous month")")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(up ? Color.red : Color.green)
    }

    @ViewBuilder private var budgetBlock: some View {
        if let b = store.budgets["All"] {
            Button { store.budgetTarget = BudgetTarget(id: "All") } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(max(m.total.dbl / b, 0), 1)).tint(m.total.dbl > b ? .red : .green)
                    Text(m.total.dbl > b ? "Over budget by \(store.m(m.total - Decimal(b)))"
                                         : "\(store.m(Decimal(b) - m.total)) left of \(store.m(Decimal(b)))")
                        .font(.caption).foregroundStyle(m.total.dbl > b ? Color.red : Color.secondary)
                }
            }.buttonStyle(.plain)
        } else {
            Button("Set a monthly budget") { store.budgetTarget = BudgetTarget(id: "All") }
                .font(.footnote)
        }
    }

    // MARK: Charts + breakdowns

    @ViewBuilder private var chartSections: some View {
        switch mode {
        case .category:
            Section { DonutView(parts: m.cats.filter { $0.value > 0 }, total: m.total) }
            Section {
                ForEach(m.cats) { p in
                    NavigationLink { TxListScreen(title: p.id, scope: .cat(p.id)) } label: { catRow(p) }
                        .swipeActions {
                            Button { store.budgetTarget = BudgetTarget(id: p.id) } label: {
                                Label("Budget", systemImage: "target")
                            }.tint(.indigo)
                        }
                }
            } header: { Text("By category") } footer: { Text("Swipe a category to set a monthly budget.") }

        case .day:
            Section {
                Chart(Array(m.days.reversed())) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Spent", max(d.dbl, 0)))
                        .foregroundStyle(Color.indigo)
                }
                .chartYAxis { compactAxis }
                .frame(height: 200)
            }
            Section("By day") {
                ForEach(m.days) { d in
                    NavigationLink { TxListScreen(title: dayTitle(d.date), scope: .day(d.date)) } label: {
                        HStack {
                            Text(dayTitle(d.date)); Spacer()
                            Text(store.m(d.total)).bold().monospacedDigit()
                            Text("\(d.pct)%").foregroundStyle(.secondary).frame(minWidth: 36, alignment: .trailing)
                        }
                    }
                }
            }

        case .bank:
            Section { DonutView(parts: m.banks.filter { $0.value > 0 }, total: m.total) }
            Section {
                ForEach(m.banks) { b in
                    NavigationLink { TxListScreen(title: b.id, scope: .bank(b.id)) } label: {
                        HStack {
                            Circle().fill(b.color).frame(width: 10, height: 10)
                            Text(b.id); Spacer()
                            Text(store.m(b.value)).bold().monospacedDigit()
                            Text("\(b.pct)%").foregroundStyle(.secondary).frame(minWidth: 36, alignment: .trailing)
                        }
                    }
                }
            } header: { Text("By bank") } footer: { Text("Tap a bank to see its spends for today or the month.") }

        case .history:
            Section {
                Chart(store.history.suffix(12)) { h in
                    BarMark(x: .value("Month", h.anchor, unit: .month), y: .value("Spent", max(h.dbl, 0)))
                        .foregroundStyle(Color.indigo)
                }
                .chartYAxis { compactAxis }
                .frame(height: 200)
            }
            Section("By month") {
                ForEach(store.history.reversed()) { h in
                    Button {
                        store.selectPeriod(h.anchor)
                        mode = .category
                    } label: {
                        HStack {
                            Text(store.period(anchor: h.anchor).title); Spacer()
                            Text(store.m(h.total)).bold().monospacedDigit()
                        }
                    }.foregroundStyle(.primary)
                }
            }
        }
    }

    private var compactAxis: some AxisContent {
        AxisMarks { v in
            AxisGridLine()
            AxisValueLabel {
                if let x = v.as(Double.self) { Text(inrCompact(x)) }
            }
        }
    }

    private func catRow(_ p: Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CatBadge(cat: p.id, size: 24)
                Text(p.id); Spacer()
                Text(store.m(p.value)).bold().monospacedDigit()
                Text("\(p.pct)%").foregroundStyle(.secondary).frame(minWidth: 36, alignment: .trailing)
            }
            if let b = store.budgets[p.id] {
                ProgressView(value: min(max(p.dbl / b, 0), 1)).tint(p.dbl > b ? .red : .green)
                Text(p.dbl > b ? "Over by \(store.m(p.value - Decimal(b)))"
                               : "\(store.m(Decimal(b) - p.value)) left of \(store.m(Decimal(b)))")
                    .font(.caption).foregroundStyle(p.dbl > b ? Color.red : Color.secondary)
            }
        }
    }

    // MARK: Insights

    @ViewBuilder private var insightSections: some View {
        if m.countedCount > 0 {
            Section("Insights") {
                LabeledContent("Daily average", value: store.m(m.dailyAvg))
                if let p = m.projected { LabeledContent("Projected month-end", value: store.m(p)) }
                if let b = m.biggest {
                    Button { store.detailTx = b } label: {
                        LabeledContent("Biggest spend") { Text("\(b.name) · \(store.m(b.amt))") }
                    }.buttonStyle(.plain)
                }
                if let d = m.busiestDay { LabeledContent("Busiest day", value: d) }
            }
            if !m.merchants.isEmpty {
                Section("Top merchants") {
                    ForEach(m.merchants) { x in
                        NavigationLink { TxListScreen(title: x.id, scope: .merchant(x.id)) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(x.id)
                                    Text("\(x.count)×").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(store.m(x.total)).bold().monospacedDigit()
                            }
                        }
                    }
                }
            }
            if !store.recurring.isEmpty {
                Section {
                    ForEach(store.recurring) { r in
                        HStack {
                            Text(r.name); Spacer()
                            Text("\(store.m(r.amount))/mo").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Subscriptions · ≈ \(store.m(store.recurring.reduce(Decimal.zero) { $0 + $1.amount }))/mo")
                }
            }
        }
    }
}

// =====================================================================================
// MARK: - Spends (all history: search, filter chips, grouped by day)
// =====================================================================================

struct SpendsView: View {
    @Environment(Store.self) private var store
    @State private var search = ""
    @State private var query = ""
    @State private var cat = "All"
    @State private var bank = "All"
    @State private var groups: [DayGroup] = []
    @State private var showReview = false

    private struct Key: Hashable { var v: Int; var q: String; var c: String; var b: String }
    private var key: Key { Key(v: store.version, q: query, c: cat, b: bank) }
    private var filtered: Bool { cat != "All" || bank != "All" || !query.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section { chips }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if filtered {
                    Section {
                        HStack {
                            Text("\(groups.reduce(0) { $0 + $1.items.count }) results")
                            Spacer()
                            Text(store.m(groups.reduce(Decimal.zero) { $0 + $1.total })).bold()
                        }
                    }
                }
                ForEach(groups) { g in
                    Section {
                        ForEach(g.items) { SpendRow(t: $0) }
                    } header: { DayHeader(g: g) }
                }
            }
            .navigationTitle("Spends")
            .searchable(text: $search, prompt: "Merchant, card or amount")
            .toolbar {
                if !store.review.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showReview = true } label: {
                            Label("Review (\(store.review.count))", systemImage: "tray.full")
                        }
                    }
                }
            }
            .refreshable { await store.refresh(force: true) }
            .task(id: search) {   // debounce typing
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                query = search.trimmingCharacters(in: .whitespaces)
            }
            .task(id: key) {      // grouping runs off the main thread
                let src = store.ledger
                let c = cat, b = bank, q = query.lowercased()
                let g = await Task.detached(priority: .userInitiated) {
                    buildGroups(src, cat: c, bank: b, query: q)
                }.value
                if !Task.isCancelled { groups = g }
            }
            .onChange(of: store.banks) { _, banks in
                if bank != "All" && !banks.contains(bank) { bank = "All" }
            }
            .overlay {
                if store.hasData && groups.isEmpty && filtered { ContentUnavailableView.search(text: query) }
                if !store.hasData { EmptyStateView() }
            }
            .sheet(isPresented: $showReview) { ReviewView() }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Category", selection: $cat) {
                        Text("All categories").tag("All")
                        ForEach(Cats.names, id: \.self) { n in Label(n, systemImage: Cats.symbol(n)).tag(n) }
                    }
                } label: { Chip(title: cat == "All" ? "Category" : cat, icon: "tag", active: cat != "All") }
                Menu {
                    Picker("Bank", selection: $bank) {
                        Text("All banks").tag("All")
                        ForEach(store.banks, id: \.self) { Text($0).tag($0) }
                    }
                } label: { Chip(title: bank == "All" ? "Bank" : bank, icon: "creditcard", active: bank != "All") }
                if filtered {
                    Button {
                        cat = "All"; bank = "All"; search = ""; query = ""
                    } label: { Chip(title: "Clear", icon: "xmark", active: false) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
    }
}

// =====================================================================================
// MARK: - Sheets: transaction detail, review inbox, budget
// =====================================================================================

struct TxDetail: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let t: Tx
    @State private var cat: String
    @State private var applyAll = true

    init(t: Tx) {
        self.t = t
        _cat = State(initialValue: t.cat)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.m(t.amt)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(t.name).font(.headline)
                    }
                    LabeledContent("Original text", value: t.merchant)
                    LabeledContent("Card", value: "\(t.src) \(t.last4)")
                    LabeledContent("When", value: t.date.formatted(date: .abbreviated, time: .shortened))
                }
                Section("Category") {
                    ForEach(Cats.names, id: \.self) { n in
                        Button { cat = n } label: {
                            HStack {
                                CatBadge(cat: n, size: 26)
                                Text(n)
                                Spacer()
                                if cat == n { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }.foregroundStyle(.primary)
                    }
                    Toggle("Apply to all “\(t.name)” spends (\(store.ledger.filter { $0.key == t.key }.count))", isOn: $applyAll)
                }
                Section {
                    Toggle("Exclude from totals", isOn: Binding(
                        get: { store.excluded.contains(t.id) },
                        set: { _ in store.toggleExclude(t) }))
                    Button("Reset category to automatic") {
                        store.resetCategory(t)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Spend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if cat != t.cat { store.assign(t, to: cat, all: applyAll) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ReviewView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.review) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name)
                            Text("\(r.count) spend\(r.count == 1 ? "" : "s") · \(store.m(r.total))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(Cats.names, id: \.self) { n in
                                Button { store.assign(key: r.id, name: r.name, count: r.count, to: n) } label: {
                                    Label(n, systemImage: Cats.symbol(n))
                                }
                            }
                        } label: {
                            Text("Categorise").font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .overlay {
                if store.review.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                           description: Text("Every spend has a category."))
                }
            }
            .navigationTitle("Needs a category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct BudgetSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: BudgetTarget
    @State private var text = ""

    private var value: Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return v
    }
    private var title: String { target.id == "All" ? "Overall monthly budget" : "\(target.id) budget" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Monthly amount in ₹", text: $text).keyboardType(.numberPad)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([2000, 5000, 10000, 20000, 50000], id: \.self) { v in
                                Button { text = String(v) } label: { Chip(title: inrCompact(Double(v)), icon: "plus", active: text == String(v)) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                } footer: {
                    if !text.isEmpty && value == nil { Text("Enter a number greater than zero.").foregroundStyle(.red) }
                }
                if store.budgets[target.id] != nil {
                    Section {
                        Button("Remove budget", role: .destructive) {
                            store.setBudget(target.id, nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let v = value { store.setBudget(target.id, v) }
                        dismiss()
                    }.disabled(value == nil)
                }
            }
            .onAppear { text = store.budgets[target.id].map { String(Int($0)) } ?? "" }
        }
        .presentationDetents([.medium])
    }
}

// =====================================================================================
// MARK: - Empty state / onboarding
// =====================================================================================

struct EmptyStateView: View {
    @Environment(Store.self) private var store

    private var title: String {
        switch store.sync {
        case .noFile: return "Track every spend"
        case .loading: return "Reading your spends…"
        case .missing: return "Can't find the file"
        case .unreadable: return "Couldn't read the file"
        case .synced, .sample: return "No spends found"
        }
    }
    private var message: String {
        switch store.sync {
        case .noFile: return "Connect the CSV that your Shortcut writes to and your spends show up here."
        case .loading: return "One moment."
        case .missing: return "The file was moved or deleted. Choose it again."
        case .unreadable: return "Check that the file is downloaded and try again."
        case .synced, .sample: return "The file was read, but no valid lines were found."
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Logo(size: 72)
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if store.sync == .loading { ProgressView() }
                if store.sync == .noFile {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your Shortcut appends each spend to myspends.csv", systemImage: "1.circle")
                        Label("Choose that file here once", systemImage: "2.circle")
                        Label("The app updates itself as new spends arrive", systemImage: "3.circle")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                if store.skipped > 0 {
                    Text("\(store.skipped) lines couldn't be read. Expected: 2026-10-01 11:40, Card|1234|450.00|Merchant")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Button("Choose CSV file") { store.showPicker = true }.buttonStyle(.borderedProminent)
                Button("Try with sample data") { store.useSample() }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// =====================================================================================
// MARK: - Settings
// =====================================================================================

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section("Data file") {
                    LabeledContent("Status") { SyncLabel() }
                    Button("Choose CSV file", systemImage: "doc") { store.showPicker = true }
                    Button("Refresh now", systemImage: "arrow.clockwise") { Task { await store.refresh(force: true) } }
                    Button("Use sample data", systemImage: "wand.and.stars") { store.useSample() }
                    if store.skipped > 0 {
                        Text("\(store.skipped) lines couldn't be read").foregroundStyle(.orange)
                    }
                }
                Section("Totals") {
                    Toggle("Hide transfers from totals", isOn: Binding(
                        get: { store.hideTransfers }, set: { store.setHideTransfers($0) }))
                    Toggle("Merge duplicate entries", isOn: Binding(
                        get: { store.dedupe }, set: { store.setDedupe($0) }))
                    Stepper("Month starts on day \(store.cycleDay)",
                            value: Binding(get: { store.cycleDay }, set: { store.setCycleDay($0) }), in: 1...28)
                }
                Section {
                    budgetRow("All", title: "Overall")
                    ForEach(Cats.names.filter { $0 != "Transfers" }, id: \.self) { budgetRow($0, title: $0) }
                } header: { Text("Monthly budgets") }
                Section("Privacy") {
                    Toggle("Hide amounts", isOn: Binding(get: { store.masked }, set: { _ in store.toggleMask() }))
                    Toggle("Hide in app switcher", isOn: Binding(get: { store.coverEnabled }, set: { store.setCover($0) }))
                    Toggle("Require Face ID / passcode", isOn: Binding(get: { store.lockEnabled }, set: { store.setLock($0) }))
                }
                Section("Share") {
                    ShareLink(item: CSVExport(txs: store.month.txs, name: store.month.period.title),
                              preview: SharePreview("Spends – \(store.month.period.title)")) {
                        Label("Share month CSV", systemImage: "square.and.arrow.up")
                    }
                    ShareLink(item: store.month.summary) {
                        Label("Share month summary", systemImage: "text.alignleft")
                    }
                }
                Section {
                    if store.overrides.isEmpty {
                        Text("Nothing yet. Tap a spend and change its category to teach the app.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.overrides.keys.sorted(), id: \.self) { k in
                            HStack {
                                Text(k.capitalized); Spacer()
                                Text(store.overrides[k] ?? "").foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idx in
                            let keys = store.overrides.keys.sorted()
                            for i in idx { store.removeOverride(keys[i]) }
                        }
                        Button("Reset all", role: .destructive) { store.resetAllOverrides() }
                    }
                } header: { Text("Learned categories") } footer: { Text("Swipe to delete a rule and return to automatic.") }
            }
            .navigationTitle("Settings")
        }
    }

    private func budgetRow(_ id: String, title: String) -> some View {
        Button { store.budgetTarget = BudgetTarget(id: id) } label: {
            LabeledContent(title) {
                Text(store.budgets[id].map { inr(Decimal($0)) } ?? "Not set").foregroundStyle(.secondary)
            }
        }.foregroundStyle(.primary)
    }
}

// =====================================================================================
// MARK: - Root, privacy cover, app entry
// =====================================================================================

struct CoverView: View {
    @Environment(Store.self) private var store
    var body: some View {
        ZStack {
            Group {
                if store.locked { Color(.systemBackground) } else { Rectangle().fill(.ultraThickMaterial) }
            }
            .ignoresSafeArea()
            VStack(spacing: 16) {
                Logo(size: 72)
                if store.locked {
                    Text("Locked").font(.headline)
                    Button("Unlock") { Task { await store.unlock() } }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            TodayView().tabItem { Label("Today", systemImage: "sun.max") }
            MonthView().tabItem { Label("Month", systemImage: "chart.pie") }
            SpendsView().tabItem { Label("Spends", systemImage: "list.bullet") }
                .badge(store.review.count)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(item: Binding(get: { store.detailTx }, set: { store.detailTx = $0 })) { TxDetail(t: $0) }
        .sheet(item: Binding(get: { store.budgetTarget }, set: { store.budgetTarget = $0 })) { BudgetSheet(target: $0) }
        .fileImporter(isPresented: Binding(get: { store.showPicker }, set: { store.showPicker = $0 }),
                      allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let u) = result { store.chooseFile(u) }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                HStack(spacing: 12) {
                    Text(t.text).font(.subheadline).lineLimit(2)
                    if t.canUndo {
                        Button("Undo") { store.undo() }.font(.subheadline.weight(.bold))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.toast?.id)
        .overlay {
            if store.locked || (store.coverEnabled && phase != .active) { CoverView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in store.tickNow() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in store.tickNow() }
        // One task: lifecycle + polling. Polling only runs while the app is active and
        // is nearly free because the engine skips unchanged files (mod date + size).
        .task(id: phase) {
            store.phaseChanged(phase)
            guard phase == .active else { return }
            await store.startup()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await store.refresh()
            }
        }
    }
}

@main struct SpendsApp: App {
    @State private var store = Store()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.indigo)
        }
    }
}
