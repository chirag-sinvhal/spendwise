import SwiftUI
import Charts
import UIKit
import LocalAuthentication
import CoreTransferable
import UniformTypeIdentifiers

// =====================================================================================
//  Spends – iOS 17+ (Fully Optimised Edition)
//  CSV line format:  2026-10-01 11:40, Source|Last4|Amount|Merchant
//  Structure:  Models → Formatting → Categoriser → Engine (actor, off-main parsing)
//              → Store (@Observable) → Views (Today / Fixed / Month / Spends / Settings)
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
    static let fixedTargets = "fxt"
    static let fixedMerchantMap = "fxm"
    static let fixedTxMap = "fxtx"
    static let bankBalance = "bbal"
    static let bankBalanceDate = "bbal_dt"
    static let bankBalanceMode = "bbal_mode" // "sinceDate" or "month"
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
    static let names: [String] = all.map { $0.name }
    private static let colorMap: [String: Color] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.color) })
    private static let symbolMap: [String: String] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.symbol) })

    static func color(_ n: String) -> Color { colorMap[n] ?? .gray }
    static func symbol(_ n: String) -> String { symbolMap[n] ?? "circle" }
}

// MARK: - Fixed Expense Buckets (Auto-detected + Manual Pinning)

enum FixedBucket: String, CaseIterable, Identifiable, Codable, Sendable, Equatable {
    case rent = "Rent"
    case home = "Home"
    case elecFlat = "Electricity Bill Flat"
    case elecHome = "Electricity Bill Home"
    case fuel = "Fuel"
    case food = "Food"
    case groceries = "Groceries"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .rent: return "building.2.fill"
        case .home: return "house.fill"
        case .elecFlat: return "bolt.fill"
        case .elecHome: return "bolt.circle.fill"
        case .fuel: return "fuelpump.fill"
        case .food: return "fork.knife"
        case .groceries: return "cart.fill"
        }
    }

    var color: Color {
        switch self {
        case .rent: return .indigo
        case .home: return .teal
        case .elecFlat: return .yellow
        case .elecHome: return .orange
        case .fuel: return .blue
        case .food: return .pink
        case .groceries: return .green
        }
    }

    var ruleDescription: String {
        switch self {
        case .food: return "Auto-tracks all Food category spends"
        case .groceries: return "Auto-tracks all Groceries category spends"
        case .fuel: return "Auto-tracks fuel/petrol spends & pinned merchants"
        case .rent: return "Auto-tracks rent keywords & pinned merchants"
        case .home: return "Auto-tracks home maintenance & pinned merchants"
        case .elecFlat: return "Auto-tracks flat electricity keywords & pinned spends"
        case .elecHome: return "Auto-tracks home electricity keywords & pinned spends"
        }
    }
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
    static let rules: [(String, [String])] = [
        ("Food", ["swiggy", "zomato", "restaurant", "cafe", "kfc", "domino", "pizza", "starbucks", "bakery", "eatfit", "mcdonald", "burger"]),
        ("Groceries", ["blinkit", "zepto", "bigbasket", "instamart", "dmart", "grocer", "ratnadeep", "reliance smart", "more supermarket"]),
        ("Transport", ["uber", "ola", "olacabs", "rapido", "irctc", "fuel", "petrol", "diesel", "shell", "hpcl", "bpcl", "iocl", "indian oil", "bharat petroleum", "hindustan petroleum", "metro", "redbus", "fastag", "mmt"]),
        ("Shopping", ["amazon", "flipkart", "myntra", "ajio", "nykaa", "decathlon", "uniqlo", "zara"]),
        ("Bills", ["jio", "airtel", "electric", "bescom", "mahadiscom", "tata power", "adani elec", "ebill", "recharge", "cred", "insurance", "rent", "nobroker", "nestaway", "raz*", "furnish", "society", "maintenance", "urban company", "ikea", "home centre"]),
        ("Health", ["pharm", "apollo", "hospital", "clinic", "medic", "1mg", "medplus", "practo"]),
        ("Fun", ["netflix", "spotify", "bookmyshow", "prime", "hotstar", "pvr", "inox"]),
        ("Transfers", ["a/c", "account", "upi transfer", "self transfer", "neft", "imps"])
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

    private static let fixedRules: [(FixedBucket, NSRegularExpression)] = [
        (.rent, try! NSRegularExpression(
            pattern: "(?<![a-z0-9])(rent|house rent|flat rent|nobroker|nestaway|stanza|landlord)(?![a-z0-9])",
            options: [.caseInsensitive]
        )),
        (.elecHome, try! NSRegularExpression(
            pattern: "(?<![a-z0-9])(electricity home|eb home|home electric|home bescom|parents electric)(?![a-z0-9])",
            options: [.caseInsensitive]
        )),
        (.elecFlat, try! NSRegularExpression(
            pattern: "(?<![a-z0-9])(bescom|electric|electricity|ebill|mahadiscom|tata power|adani elec|cesc|tneb|mseb|kseb)(?![a-z0-9])",
            options: [.caseInsensitive]
        )),
        (.fuel, try! NSRegularExpression(
            pattern: "(?<![a-z0-9])(fuel|petrol|diesel|shell|hpcl|bpcl|iocl|indian oil|bharat petroleum|hindustan petroleum)(?![a-z0-9])",
            options: [.caseInsensitive]
        )),
        (.home, try! NSRegularExpression(
            pattern: "(?<![a-z0-9])(home|maintenance|society|mygate|adda|urban company|urbanclap|ikea|furnish|maid|cook|water bill|gas bill|indane|bharatgas|hp gas)(?![a-z0-9])",
            options: [.caseInsensitive]
        ))
    ]

    static func category(for merchant: String) -> String {
        let r = NSRange(merchant.startIndex..., in: merchant)
        for (c, rx) in compiled where rx.firstMatch(in: merchant, options: [], range: r) != nil { return c }
        return "Other"
    }

    /// Evaluates keyword-based fixed buckets first, then falls back to category-based mapping.
    static func fixedBucket(for merchant: String, category: String) -> FixedBucket? {
        let r = NSRange(merchant.startIndex..., in: merchant)
        for (bucket, rx) in fixedRules where rx.firstMatch(in: merchant, options: [], range: r) != nil {
            return bucket
        }
        if category == "Food" { return .food }
        if category == "Groceries" { return .groceries }
        return nil
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

struct CustomTxRecord: Codable, Sendable, Equatable {
    var id: String
    var date: Date
    var src: String
    var last4: String
    var amt: Decimal
    var merchant: String
    var isManual: Bool
}

struct LocalDeltaStore: Codable, Sendable, Equatable {
    var custom: [CustomTxRecord] = []         // User-added transactions
    var edits: [String: CustomTxRecord] = [:] // Edits to CSV or manual transactions keyed by ID
    var deleted: Set<String> = []             // Deleted transaction IDs
}

struct Tx: Identifiable, Sendable, Equatable {
    enum Reason: Sendable, Equatable {
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
    let merchant: String          // raw text from the CSV or user input
    let name: String              // cleaned for display
    let key: String               // used for "apply to all"
    let bank: String
    let auto: String              // automatic category
    let autoFixed: FixedBucket?   // automatic fixed bucket (cached off-main-thread)
    let hay: String               // lowercase search text
    var cat: String               // effective category (after overrides)
    var fixedBucket: FixedBucket? // effective fixed expense bucket (auto or manual)
    var isManual: Bool = false
    var isEdited: Bool = false
    var reason: Reason?           // nil = counted in totals
    var counted: Bool { reason == nil }

    static func make(id: String, date: Date, src: String, last4: String, amt: Decimal, merchant: String, isManual: Bool = false, isEdited: Bool = false) -> Tx {
        let auto = Categorizer.category(for: merchant)
        let autoFixed = Categorizer.fixedBucket(for: merchant, category: auto)
        let hay = "\(merchant) \(src) \(last4) \(amt)".lowercased()
        return Tx(id: id, date: date, src: src, last4: last4, amt: amt, merchant: merchant,
                  name: Merchant.clean(merchant), key: Merchant.key(merchant), bank: bankName(src),
                  auto: auto, autoFixed: autoFixed, hay: hay, cat: auto, fixedBucket: autoFixed,
                  isManual: isManual, isEdited: isEdited)
    }
}

struct Period: Hashable, Identifiable, Sendable {
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

struct Part: Identifiable, Equatable {
    let id: String
    let value: Decimal
    let pct: Int
    let color: Color
    var dbl: Double { value.dbl }
}
struct DayTotal: Identifiable, Equatable {
    let date: Date
    let total: Decimal
    let pct: Int
    var id: Date { date }
    var dbl: Double { total.dbl }
}
struct PeriodTotal: Identifiable, Equatable {
    let anchor: Date
    let total: Decimal
    var id: Date { anchor }
    var dbl: Double { total.dbl }
}
struct MerchantTotal: Identifiable, Equatable { let id: String; let total: Decimal; let count: Int }
struct Recurring: Identifiable, Equatable { let id: String; let name: String; let amount: Decimal; let count: Int }
struct ReviewItem: Identifiable, Equatable { let id: String; let name: String; let count: Int; let total: Decimal }
struct BudgetTarget: Identifiable, Equatable { let id: String }
struct FixedBudgetTarget: Identifiable, Equatable { let bucket: FixedBucket; var id: String { bucket.rawValue } }
struct Toast: Identifiable, Equatable { let id = UUID(); let text: String; let canUndo: Bool }
struct DayGroup: Identifiable, Equatable { let date: Date; let items: [Tx]; let total: Decimal; var id: Date { date } }
struct SourcePair: Hashable, Identifiable, Sendable {
    let src: String
    let last4: String
    var id: String { "\(src)|\(last4)" }
}

struct FixedItemStat: Identifiable, Equatable {
    let bucket: FixedBucket
    var spent: Decimal
    var target: Decimal?
    var count: Int
    var txs: [Tx]
    var id: String { bucket.rawValue }
    var remaining: Decimal? {
        guard let t = target else { return nil }
        return max(t - spent, 0)
    }
}

struct FixedMonthSummary: Equatable {
    var items: [FixedItemStat] = []
    var totalSpent: Decimal = 0
    var totalBudgeted: Decimal = 0
    var unpaidRemaining: Decimal = 0
}

struct BalanceStatus: Equatable {
    var isConfigured: Bool = false
    var startingBalance: Decimal = 0
    var asOfDate: Date = .now
    var mode: String = "month" // "month" or "sinceDate"
    var spentAgainstBalance: Decimal = 0
    var realRemaining: Decimal = 0
    var unpaidFixedCommitments: Decimal = 0
    var safeToSpend: Decimal = 0
}

struct MonthStats: Equatable {
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
    var fixed = FixedMonthSummary()
    var summary: String {
        var s = "Spends – \(period.title)\nTotal: \(inr(total))\n"
        for c in cats where c.value != 0 { s += "\(c.id): \(inr(c.value))\n" }
        return s
    }
}

struct TodayStats: Equatable {
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
    guard !txs.isEmpty else { return [] }
    let cal = Calendar.current
    var out: [DayGroup] = []
    out.reserveCapacity(min(txs.count, 31))
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
    if cat == "All" && bank == "All" && query.isEmpty {
        return groupByDay(src)
    }
    let filtered = src.filter { t in
        if cat != "All" && t.cat != cat { return false }
        if bank != "All" && t.bank != bank { return false }
        if !query.isEmpty && !t.hay.contains(query) { return false }
        return true
    }
    return groupByDay(filtered)
}

// =====================================================================================
// MARK: - Engine: file access, incremental parsing, serialized disk cache (off-main)
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

    /// Serialized, thread-safe write for local CRUD delta changes.
    func saveDelta(_ delta: LocalDeltaStore, to url: URL) {
        if let encoded = try? JSONEncoder().encode(delta) {
            try? encoded.write(to: url, options: .atomic)
        }
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
                try? d.write(to: cacheURL, options: .atomic)
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
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            if let nb = try? url.bookmarkData() { UserDefaults.standard.set(nb, forKey: Keys.bookmark) }
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return .url(url)
    }

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

    // MARK: Parsing (incremental fast-path when the file was only appended to)

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
        if let nl = data[parsedBytes..<n].lastIndex(of: 0x0A) {
            let end = nl + 1
            let parsed = parseChunk(data[parsedBytes..<end], seen: &seen, bad: &bad)
            if !parsed.isEmpty {
                let sortedChunk = parsed.sorted { a, b in a.date != b.date ? a.date > b.date : a.id > b.id }
                if committed.isEmpty {
                    committed = sortedChunk
                } else if let newestCommitted = committed.first, let oldestNew = sortedChunk.last, oldestNew.date >= newestCommitted.date {
                    // Fast path: appended lines are newer than existing committed history
                    committed.insert(contentsOf: sortedChunk, at: 0)
                } else {
                    committed.append(contentsOf: sortedChunk)
                    committed.sort { a, b in a.date != b.date ? a.date > b.date : a.id > b.id }
                }
            }
            parsedBytes = end
            tailSig = data.subdata(in: max(0, end - 64)..<end)
        }
        if parsedBytes < n {
            var tmpSeen = seen
            var tmpBad = 0
            let tail = parseChunk(data[parsedBytes..<n], seen: &tmpSeen, bad: &tmpBad)
            if !tail.isEmpty {
                var result = committed
                result.append(contentsOf: tail)
                result.sort { a, b in a.date != b.date ? a.date > b.date : a.id > b.id }
                return result
            }
        }
        return committed
    }

    private func parseChunk(_ chunk: Data, seen: inout [String: Int], bad: inout Int) -> [Tx] {
        var out: [Tx] = []
        let text = String(decoding: chunk, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let p = parseLine(line) else { bad += 1; continue }
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
            ("SHELL PETROL PUMP", 600, 2500), ("AMAZON PAY INDIA", 300, 3500), ("MYNTRA", 700, 2800),
            ("APOLLO PHARMACY", 150, 900), ("BOOKMYSHOW", 300, 900), ("STARBUCKS", 250, 600), ("IRCTC", 400, 2200)
        ]
        var out: [Tx] = []
        for day in 0..<130 {
            guard let d0 = cal.date(byAdding: .day, value: -day, to: sod) else { continue }
            let count = Int.random(in: 1...3, using: &rng)
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
            if dom == 2, let date = cal.date(byAdding: .minute, value: 9 * 60, to: d0), date <= .now {
                out.append(Tx.make(id: "sample-rent-\(day)", date: date, src: cards[2].0, last4: cards[2].1, amt: 28000, merchant: "HOUSE RENT NOBROKER"))
            }
            if dom == 5, let date = cal.date(byAdding: .minute, value: 9 * 60, to: d0), date <= .now {
                out.append(Tx.make(id: "sample-nf-\(day)", date: date, src: cards[0].0, last4: cards[0].1, amt: 649, merchant: "NETFLIX.COM"))
            }
            if dom == 8, let date = cal.date(byAdding: .minute, value: 11 * 60, to: d0), date <= .now {
                out.append(Tx.make(id: "sample-bescom-\(day)", date: date, src: cards[2].0, last4: cards[2].1, amt: 1850, merchant: "BESCOM ELECTRICITY BILL"))
            }
            if dom == 10, let date = cal.date(byAdding: .minute, value: 14 * 60, to: d0), date <= .now {
                out.append(Tx.make(id: "sample-ebhome-\(day)", date: date, src: cards[2].0, last4: cards[2].1, amt: 2400, merchant: "ELECTRICITY HOME BILL"))
            }
            if dom == 12, let date = cal.date(byAdding: .minute, value: 10 * 60, to: d0), date <= .now {
                out.append(Tx.make(id: "sample-jio-\(day)", date: date, src: cards[1].0, last4: cards[1].1, amt: 299, merchant: "JIO RECHARGE"))
            }
            if dom == 15, let date = cal.date(byAdding: .minute, value: 16 * 60, to: d0), date <= .now {
                out.append(Tx.make(id: "sample-home-\(day)", date: date, src: cards[2].0, last4: cards[2].1, amt: 3500, merchant: "MYGATE SOCIETY MAINTENANCE"))
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
    var sources: [SourcePair] = []
    var today = TodayStats()
    var month = MonthStats(period: Period.placeholder)
    var balanceStatus = BalanceStatus()
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

    // UI Sheets & Navigation
    var detailTx: Tx?
    var showAddSheet = false
    var showBalanceSheet = false
    var budgetTarget: BudgetTarget?
    var fixedBudgetTarget: FixedBudgetTarget?
    var showPicker = false
    var toast: Toast?
    var locked = false

    // Settings & Rules (persisted)
    var overrides: [String: String] = [:]
    var txOverrides: [String: String] = [:]
    var excluded: Set<String> = []
    var budgets: [String: Double] = [:]
    var fixedTargets: [String: Double] = [:]       // FixedBucket.rawValue -> Monthly target
    var fixedMerchantMap: [String: String] = [:]   // Merchant.key -> FixedBucket.rawValue
    var fixedTxMap: [String: String] = [:]         // Tx.id -> FixedBucket.rawValue ("NONE" to unpin)
    var bankBalance: Double?
    var bankBalanceDate: Date = .now
    var bankBalanceMode: String = "month"          // "month" or "sinceDate"
    var hideTransfers = false
    var dedupe = false
    var cycleDay = 1
    var masked = false
    var coverEnabled = true
    var lockEnabled = false

    // O(1) Lookup caches & Internal state
    @ObservationIgnored var keyCounts: [String: Int] = [:]
    @ObservationIgnored private var delta = LocalDeltaStore()
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

    private struct Undo {
        var ov: [String: String]
        var tov: [String: String]
        var ex: Set<String>
        var fxm: [String: String]
        var fxtx: [String: String]
        var delta: LocalDeltaStore
    }

    private var deltaFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spends-local-delta.json")
    }

    init() {
        let d = UserDefaults.standard
        var ov: [String: String] = [:]
        for (k, v) in (d.dictionary(forKey: Keys.overrides) as? [String: String] ?? [:]) { ov[Merchant.key(k)] = v }
        overrides = ov
        txOverrides = d.dictionary(forKey: Keys.txOverrides) as? [String: String] ?? [:]
        excluded = Set(d.stringArray(forKey: Keys.excluded) ?? [])
        budgets = d.dictionary(forKey: Keys.budgets) as? [String: Double] ?? [:]
        fixedTargets = d.dictionary(forKey: Keys.fixedTargets) as? [String: Double] ?? [:]
        fixedMerchantMap = d.dictionary(forKey: Keys.fixedMerchantMap) as? [String: String] ?? [:]
        fixedTxMap = d.dictionary(forKey: Keys.fixedTxMap) as? [String: String] ?? [:]
        if let bal = d.object(forKey: Keys.bankBalance) as? Double { bankBalance = bal }
        if let bdt = d.object(forKey: Keys.bankBalanceDate) as? Date { bankBalanceDate = bdt }
        bankBalanceMode = d.string(forKey: Keys.bankBalanceMode) ?? "month"
        hideTransfers = d.bool(forKey: Keys.hideTransfers)
        dedupe = d.bool(forKey: Keys.dedupe)
        let c = d.integer(forKey: Keys.cycleDay)
        cycleDay = (1...28).contains(c) ? c : 1
        masked = d.bool(forKey: Keys.masked)
        coverEnabled = d.object(forKey: Keys.cover) as? Bool ?? true
        lockEnabled = d.bool(forKey: Keys.lock)
        if lockEnabled { locked = true; needsPrompt = true }

        if let data = try? Data(contentsOf: deltaFileURL),
           let loadedDelta = try? JSONDecoder().decode(LocalDeltaStore.self, from: data) {
            delta = loadedDelta
        }

        month = MonthStats(period: period(containing: now))
        if !delta.custom.isEmpty { recompute() }
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
        if fixedTargets.isEmpty {
            fixedTargets = [
                FixedBucket.rent.rawValue: 28000,
                FixedBucket.home.rawValue: 4000,
                FixedBucket.elecFlat.rawValue: 2000,
                FixedBucket.elecHome.rawValue: 2500,
                FixedBucket.fuel.rawValue: 4000,
                FixedBucket.food.rawValue: 8000,
                FixedBucket.groceries.rawValue: 6000
            ]
            UserDefaults.standard.set(fixedTargets, forKey: Keys.fixedTargets)
        }
        if bankBalance == nil {
            bankBalance = 145000
            bankBalanceDate = period(containing: now).start
            bankBalanceMode = "month"
        }
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
        cal.ordinality(of: .day, in: .era, for: d) ?? Int(floor(d.timeIntervalSinceReferenceDate / 86400))
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

    // MARK: Recompute (Single O(N) pass, Zero Main-Thread Regex)

    func recompute() {
        version &+= 1
        let ov = overrides, tov = txOverrides, ex = excluded, hide = hideTransfers
        let fxm = fixedMerchantMap, fxtx = fixedTxMap

        var merged: [Tx] = []
        merged.reserveCapacity(raw.count + delta.custom.count)

        let hasDeletes = !delta.deleted.isEmpty
        let hasEdits = !delta.edits.isEmpty

        if !hasDeletes && !hasEdits {
            merged = raw
        } else {
            for item in raw {
                if hasDeletes && delta.deleted.contains(item.id) { continue }
                if hasEdits, let edit = delta.edits[item.id] {
                    merged.append(Tx.make(id: item.id, date: edit.date, src: edit.src, last4: edit.last4,
                                          amt: edit.amt, merchant: edit.merchant, isManual: false, isEdited: true))
                } else {
                    merged.append(item)
                }
            }
        }

        for manual in delta.custom where !delta.deleted.contains(manual.id) {
            let rec = delta.edits[manual.id] ?? manual
            merged.append(Tx.make(id: rec.id, date: rec.date, src: rec.src, last4: rec.last4,
                                  amt: rec.amt, merchant: rec.merchant, isManual: true, isEdited: delta.edits[manual.id] != nil))
        }

        if hasEdits || !delta.custom.isEmpty {
            merged.sort { a, b in a.date != b.date ? a.date > b.date : a.id > b.id }
        }

        var kCounts: [String: Int] = [:]
        kCounts.reserveCapacity(min(merged.count, 256))
        var bankSet = Set<String>()
        var seenSrc = Set<String>()
        var srcList: [SourcePair] = []
        var rv: [String: (name: String, n: Int, total: Decimal)] = [:]
        var tot: [Date: Decimal] = [:]

        // Resolve categories, fixed buckets, and exclusions first
        for i in merged.indices {
            let k = merged[i].key
            let id = merged[i].id
            kCounts[k, default: 0] += 1

            let c = tov[id] ?? ov[k] ?? merged[i].auto
            merged[i].cat = c

            // O(1) Fixed Bucket Resolution (No regex on MainActor)
            if let pinned = fxtx[id] {
                merged[i].fixedBucket = (pinned == "NONE") ? nil : FixedBucket(rawValue: pinned)
            } else if let mPinned = fxm[k] {
                merged[i].fixedBucket = (mPinned == "NONE") ? nil : FixedBucket(rawValue: mPinned)
            } else {
                let af = merged[i].autoFixed
                if let af, af != .food && af != .groceries {
                    merged[i].fixedBucket = af
                } else if c == "Food" {
                    merged[i].fixedBucket = .food
                } else if c == "Groceries" {
                    merged[i].fixedBucket = .groceries
                } else {
                    merged[i].fixedBucket = nil
                }
            }

            if ex.contains(id) { merged[i].reason = .excluded }
            else if hide && c == "Transfers" { merged[i].reason = .transfer }
            else { merged[i].reason = nil }
        }

        if dedupe {
            var last: [String: Date] = [:]
            for i in merged.indices.reversed() {
                let t = merged[i]
                let sig = "\(t.src)|\(t.last4)|\(t.amt)|\(t.key)"
                if let d = last[sig], abs(t.date.timeIntervalSince(d)) < 120 {
                    if merged[i].reason == nil { merged[i].reason = .duplicate }
                } else {
                    last[sig] = t.date
                }
            }
        }

        // Single pass for aggregates (banks, sources, review inbox, history totals)
        for t in merged {
            bankSet.insert(t.bank)
            if !t.src.isEmpty {
                let pair = SourcePair(src: t.src, last4: t.last4)
                if seenSrc.insert(pair.id).inserted {
                    srcList.append(pair)
                }
            }
            if t.counted {
                tot[anchor(of: t.date), default: 0] += t.amt
                if t.cat == "Other" && ov[t.key] == nil && tov[t.id] == nil {
                    let e = rv[t.key] ?? (t.name, 0, Decimal.zero)
                    rv[t.key] = (e.name, e.n + 1, e.total + t.amt)
                }
            }
        }

        keyCounts = kCounts
        ledger = merged
        hasData = !merged.isEmpty
        banks = bankSet.sorted()
        sources = srcList

        let sortedReview = rv.map { ReviewItem(id: $0.key, name: $0.value.name, count: $0.value.n, total: $0.value.total) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        review = Array(sortedReview.prefix(40))

        history = tot.map { PeriodTotal(anchor: $0.key, total: $0.value) }.sorted { $0.anchor < $1.anchor }
        recurring = detectRecurring(merged)
        derive()
    }

    private func detectRecurring(_ l: [Tx]) -> [Recurring] {
        var groups: [String: [Tx]] = [:]
        for t in l where t.counted && t.amt > 0 && !t.key.isEmpty {
            groups[t.key, default: []].append(t)
        }
        var out: [Recurring] = []
        for (k, g) in groups where g.count >= 3 {
            // `l` is newest-first, so `g.reversed()` is oldest-first without sorting!
            let s = Array(g.reversed())
            var gaps: [Double] = []
            gaps.reserveCapacity(s.count - 1)
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

    // MARK: Derive (Early-Exit O(K) Sorted Loops)

    func derive() {
        cal = Calendar.current
        let cur = period(containing: now)
        let sel = selectedAnchor.map { period(anchor: $0) } ?? cur
        let isCur = sel.anchor == cur.anchor
        let (totalDays, elapsed) = span(sel, current: isCur)

        // 1. Slice selected month with early exit
        var inPeriod: [Tx] = []
        var counted: [Tx] = []
        var total = Decimal.zero
        for t in ledger {
            if t.date >= sel.end { continue }
            if t.date < sel.start { break }
            inPeriod.append(t)
            if t.counted {
                counted.append(t)
                total += t.amt
            }
        }

        // 2. Compare same number of days of previous period with early exit
        let prevAnchor = cal.date(byAdding: .month, value: -1, to: sel.anchor) ?? sel.anchor
        let prevStart = period(anchor: prevAnchor).start
        let prevEnd = min(cal.date(byAdding: .day, value: elapsed, to: prevStart) ?? sel.start, sel.start)
        var prevTotal = Decimal.zero
        for t in ledger {
            if t.date >= prevEnd { continue }
            if t.date < prevStart { break }
            if t.counted { prevTotal += t.amt }
        }

        // 3. Selected month breakdowns
        var byCat: [String: Decimal] = [:]
        var byBank: [String: Decimal] = [:]
        var byDay: [Date: Decimal] = [:]
        var mt: [String: (Decimal, Int)] = [:]
        var wd: [Int: Decimal] = [:]
        var byFixed: [FixedBucket: [Tx]] = [:]
        var biggest: Tx?

        for t in counted {
            byCat[t.cat, default: 0] += t.amt
            byBank[t.bank, default: 0] += t.amt
            byDay[cal.startOfDay(for: t.date), default: 0] += t.amt
            if let fb = t.fixedBucket {
                byFixed[fb, default: []].append(t)
            }
            if t.amt > 0 {
                let e = mt[t.name] ?? (Decimal.zero, 0)
                mt[t.name] = (e.0 + t.amt, e.1 + 1)
                wd[cal.component(.weekday, from: t.date), default: 0] += t.amt
                if biggest == nil || t.amt > biggest!.amt { biggest = t }
            }
        }
        for k in budgets.keys where k != "All" && byCat[k] == nil { byCat[k] = 0 }

        var fixedItems: [FixedItemStat] = []
        fixedItems.reserveCapacity(FixedBucket.allCases.count)
        var fixedSpentTotal = Decimal.zero
        var fixedBudgetTotal = Decimal.zero
        var unpaidFixed = Decimal.zero

        for bucket in FixedBucket.allCases {
            let bucketTxs = byFixed[bucket] ?? []
            let spent = bucketTxs.reduce(Decimal.zero) { $0 + $1.amt }
            let targetDec = fixedTargets[bucket.rawValue].map { Decimal($0) }
            fixedSpentTotal += spent
            if let td = targetDec {
                fixedBudgetTotal += td
                unpaidFixed += max(td - spent, 0)
            }
            fixedItems.append(FixedItemStat(bucket: bucket, spent: spent, target: targetDec, count: bucketTxs.count, txs: bucketTxs))
        }

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
        ms.biggest = biggest
        let sortedMerchants = mt.map { MerchantTotal(id: $0.key, total: $0.value.0, count: $0.value.1) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
        ms.merchants = Array(sortedMerchants.prefix(5))
        if counted.count >= 7, let top = wd.max(by: { $0.value < $1.value }) {
            ms.busiestDay = cal.weekdaySymbols[top.key - 1]
        }
        ms.fixed = FixedMonthSummary(items: fixedItems, totalSpent: fixedSpentTotal, totalBudgeted: fixedBudgetTotal, unpaidRemaining: unpaidFixed)
        month = ms

        var set = Set(history.map { $0.anchor })
        set.insert(cur.anchor); set.insert(sel.anchor)
        periods = set.sorted(by: >).map { period(anchor: $0) }

        // 4. Today, 7-day chart & 30-day average in a single early-exit scan
        let sod = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: sod) ?? sod
        let weekStart = cal.date(byAdding: .day, value: -6, to: sod) ?? sod
        let start30 = cal.date(byAdding: .day, value: -30, to: sod) ?? sod

        var todayTx: [Tx] = []
        var todayTotal = Decimal.zero
        var todayCount = 0
        var wk: [Date: Decimal] = [:]
        var sum30 = Decimal.zero

        for t in ledger {
            if t.date >= tomorrow { continue }
            if t.date < start30 { break } // Early exit at 30 days ago!

            if t.date >= sod {
                todayTx.append(t)
                if t.counted {
                    todayTotal += t.amt
                    todayCount += 1
                }
            } else if t.counted {
                sum30 += t.amt
            }

            if t.counted && t.date >= weekStart {
                wk[cal.startOfDay(for: t.date), default: 0] += t.amt
            }
        }

        let week: [DayTotal] = (0..<7).map { i in
            let d = cal.startOfDay(for: cal.date(byAdding: .day, value: i - 6, to: sod) ?? sod)
            return DayTotal(date: d, total: wk[d] ?? 0, pct: 0)
        }

        var avg: Decimal?
        if let oldest = ledger.last?.date {
            let histDays = max(min(cal.dateComponents([.day], from: cal.startOfDay(for: oldest), to: sod).day ?? 0, 30), 0)
            if histDays >= 3 { avg = sum30 / Decimal(histDays) }
        }

        // Current period metrics (when viewing a past month)
        var curTotal = total
        var curUnpaidFixed = unpaidFixed
        if !isCur {
            curTotal = 0
            var curByFixed: [FixedBucket: Decimal] = [:]
            for t in ledger {
                if t.date >= cur.end { continue }
                if t.date < cur.start { break }
                if t.counted {
                    curTotal += t.amt
                    if let fb = t.fixedBucket { curByFixed[fb, default: 0] += t.amt }
                }
            }
            var uf = Decimal.zero
            for b in FixedBucket.allCases {
                if let td = fixedTargets[b.rawValue].map({ Decimal($0) }) {
                    uf += max(td - (curByFixed[b] ?? 0), 0)
                }
            }
            curUnpaidFixed = uf
        }

        // 5. Real Bank Balance Calculation (Early-exit scan)
        if let bal = bankBalance {
            let startBal = Decimal(bal)
            let spentAgainst: Decimal
            if bankBalanceMode == "sinceDate" {
                var sumSince = Decimal.zero
                for t in ledger {
                    if t.date < bankBalanceDate { break }
                    if t.counted { sumSince += t.amt }
                }
                spentAgainst = sumSince
            } else {
                spentAgainst = curTotal
            }
            let realRem = startBal - spentAgainst
            balanceStatus = BalanceStatus(
                isConfigured: true,
                startingBalance: startBal,
                asOfDate: bankBalanceDate,
                mode: bankBalanceMode,
                spentAgainstBalance: spentAgainst,
                realRemaining: realRem,
                unpaidFixedCommitments: curUnpaidFixed,
                safeToSpend: realRem - curUnpaidFixed
            )
        } else {
            balanceStatus = BalanceStatus(isConfigured: false)
        }

        var allowance: Decimal?
        var left: Decimal?
        if let b = budgets["All"] {
            let cs = span(cur, current: true)
            let remainingDays = max(cs.total - cs.elapsed + 1, 1)
            let before = curTotal - todayTotal
            let a = (Decimal(b) - before) / Decimal(remainingDays)
            allowance = a
            left = a - todayTotal
        }

        today = TodayStats(txs: todayTx, total: todayTotal, count: todayCount,
                           avg: avg, week: week, allowance: allowance, left: left)
    }

    // MARK: Persistence & CRUD Operations

    private func snapshot() -> Undo {
        Undo(ov: overrides, tov: txOverrides, ex: excluded, fxm: fixedMerchantMap, fxtx: fixedTxMap, delta: delta)
    }

    private func persistRules() {
        let d = UserDefaults.standard
        d.set(overrides, forKey: Keys.overrides)
        d.set(txOverrides, forKey: Keys.txOverrides)
        d.set(Array(excluded), forKey: Keys.excluded)
        d.set(fixedMerchantMap, forKey: Keys.fixedMerchantMap)
        d.set(fixedTxMap, forKey: Keys.fixedTxMap)
        let currentDelta = delta
        let url = deltaFileURL
        Task {
            await engine.saveDelta(currentDelta, to: url)
        }
    }

    func addManualTx(date: Date, src: String, last4: String, amt: Decimal, merchant: String, cat: String, fixedBucket: FixedBucket?) {
        let u = snapshot()
        let id = "manual-\(UUID().uuidString)"
        let cleanSrc = src.trimmingCharacters(in: .whitespaces).isEmpty ? "Cash / Manual" : src.trimmingCharacters(in: .whitespaces)
        let cleanLast4 = last4.trimmingCharacters(in: .whitespaces).isEmpty ? "0000" : last4.trimmingCharacters(in: .whitespaces)
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespaces).isEmpty ? "Manual Spend" : merchant.trimmingCharacters(in: .whitespaces)

        let record = CustomTxRecord(id: id, date: date, src: cleanSrc, last4: cleanLast4, amt: amt, merchant: cleanMerchant, isManual: true)
        delta.custom.append(record)
        txOverrides[id] = cat
        fixedTxMap[id] = fixedBucket?.rawValue ?? "NONE"
        persistRules()
        recompute()
        newSpendTick += 1
        show("Added \(Merchant.clean(cleanMerchant)) (\(m(amt)))", undo: u)
    }

    func updateTx(_ t: Tx, date: Date, src: String, last4: String, amt: Decimal, merchant: String, cat: String, applyCatAll: Bool, fixedBucket: FixedBucket?, applyFixedAll: Bool) {
        let u = snapshot()
        let cleanSrc = src.trimmingCharacters(in: .whitespaces).isEmpty ? t.src : src.trimmingCharacters(in: .whitespaces)
        let cleanLast4 = last4.trimmingCharacters(in: .whitespaces)
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespaces).isEmpty ? t.merchant : merchant.trimmingCharacters(in: .whitespaces)

        if t.date != date || t.src != cleanSrc || t.last4 != cleanLast4 || t.amt != amt || t.merchant != cleanMerchant {
            let rec = CustomTxRecord(id: t.id, date: date, src: cleanSrc, last4: cleanLast4, amt: amt, merchant: cleanMerchant, isManual: t.isManual)
            delta.edits[t.id] = rec
        }

        let newKey = Merchant.key(cleanMerchant)
        if applyCatAll {
            overrides[newKey] = cat
            for item in ledger where item.key == newKey { txOverrides[item.id] = nil }
        } else {
            txOverrides[t.id] = cat
        }

        let fbVal = fixedBucket?.rawValue ?? "NONE"
        if applyFixedAll {
            fixedMerchantMap[newKey] = fbVal
            for item in ledger where item.key == newKey { fixedTxMap[item.id] = nil }
        } else {
            fixedTxMap[t.id] = fbVal
        }

        persistRules()
        recompute()
        show("Updated \(Merchant.clean(cleanMerchant))", undo: u)
    }

    func deleteTx(_ t: Tx) {
        let u = snapshot()
        delta.deleted.insert(t.id)
        delta.custom.removeAll { $0.id == t.id }
        delta.edits[t.id] = nil
        persistRules()
        recompute()
        show("Deleted \(t.name) (\(m(t.amt)))", undo: u)
    }

    func assign(_ t: Tx, to c: String, all: Bool) {
        let u = snapshot()
        let msg: String
        if all {
            overrides[t.key] = c
            var count = 0
            for item in ledger where item.key == t.key {
                txOverrides[item.id] = nil
                count += 1
            }
            msg = "Moved \(count) \(t.name) spend\(count == 1 ? "" : "s") to \(c)"
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
        fixedMerchantMap[t.key] = nil
        fixedTxMap[t.id] = nil
        persistRules(); recompute(); show("Category & fixed bucket reset to automatic", undo: u)
    }

    func removeOverride(_ key: String) {
        overrides[key] = nil
        persistRules(); recompute()
    }

    func resetAllOverrides() {
        let u = snapshot()
        overrides = [:]; txOverrides = [:]; fixedMerchantMap = [:]; fixedTxMap = [:]
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
        fixedMerchantMap = u.fxm; fixedTxMap = u.fxtx; delta = u.delta
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

    // MARK: Settings & Targets

    func setBudget(_ id: String, _ v: Double?) {
        budgets[id] = v
        UserDefaults.standard.set(budgets, forKey: Keys.budgets)
        derive()
    }

    func setFixedTarget(_ bucket: FixedBucket, _ v: Double?) {
        fixedTargets[bucket.rawValue] = v
        UserDefaults.standard.set(fixedTargets, forKey: Keys.fixedTargets)
        derive()
    }

    func updateBankBalance(amount: Double?, asOf: Date, mode: String) {
        bankBalance = amount
        bankBalanceDate = asOf
        bankBalanceMode = mode
        let d = UserDefaults.standard
        if let amount {
            d.set(amount, forKey: Keys.bankBalance)
        } else {
            d.removeObject(forKey: Keys.bankBalance)
        }
        d.set(asOf, forKey: Keys.bankBalanceDate)
        d.set(mode, forKey: Keys.bankBalanceMode)
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
        var s = "Date,Source,Last4,Amount,Merchant,Category,FixedBucket,Counted\r\n"
        for t in txs {
            s += "\(f.string(from: t.date)),\(csvEscape(t.src)),\(csvEscape(t.last4)),\(t.amt),\(csvEscape(t.merchant)),\(csvEscape(t.cat)),\(csvEscape(t.fixedBucket?.rawValue ?? "")),\(t.counted ? "yes" : "no")\r\n"
        }
        return s
    }

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
    private static let hasCustomLogo = UIImage(named: "AppLogo") != nil
    var size: CGFloat = 30
    var body: some View {
        Group {
            if Self.hasCustomLogo {
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

struct CatBadge: View, Equatable {
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

struct FixedBadge: View, Equatable {
    let bucket: FixedBucket
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: bucket.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(bucket.color, in: RoundedRectangle(cornerRadius: size * 0.26))
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
        if let fb = t.fixedBucket, fb.rawValue != t.cat { s += " · \(fb.rawValue)" }
        if t.isManual { s += " · manual" }
        else if t.isEdited { s += " · edited" }
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
            Button { store.detailTx = t } label: { Label("Edit", systemImage: "pencil") }.tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { store.deleteTx(t) } label: {
                Label("Delete", systemImage: "trash")
            }
            if t.counted || t.reason == .excluded {
                Button { store.toggleExclude(t) } label: {
                    Label(t.counted ? "Exclude" : "Include", systemImage: t.counted ? "eye.slash" : "eye")
                }.tint(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(t.name), \(store.m(t.amt)), \(t.cat), \(t.src) \(t.last4), \(Fmt.time.string(from: t.date))")
        .accessibilityHint("Opens details to edit or delete")
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

struct Chip: View, Equatable {
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
// MARK: - Bank Balance Card (Real Balance Left)
// =====================================================================================

struct BalanceCardView: View {
    @Environment(Store.self) private var store
    private var bal: BalanceStatus { store.balanceStatus }

    var body: some View {
        Button { store.showBalanceSheet = true } label: {
            if bal.isConfigured {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Real Bank Balance Left", systemImage: "building.columns.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.indigo)
                        Spacer()
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.secondary)
                    }

                    Text(store.m(bal.realRemaining))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(bal.realRemaining < 0 ? Color.red : Color.primary)
                        .contentTransition(.numericText())

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Starting Balance").font(.caption2).foregroundStyle(.secondary)
                            Text(store.m(bal.startingBalance)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text(bal.mode == "sinceDate" ? "Spends Since \(bal.asOfDate.formatted(.dateTime.day().month(.abbreviated)))" : "This Month's Spends")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("−\(store.m(bal.spentAgainstBalance))").font(.caption.weight(.semibold)).foregroundStyle(.orange).monospacedDigit()
                        }
                        if bal.unpaidFixedCommitments > 0 {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("After Fixed Bills").font(.caption2).foregroundStyle(.secondary)
                                Text(store.m(bal.safeToSpend))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(bal.safeToSpend < 0 ? Color.red : Color.green)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "building.columns.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set your bank balance")
                            .font(.subheadline.weight(.semibold))
                        Text("Track how much balance is truly left after spends & fixed bills")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .buttonStyle(.plain)
    }
}

// =====================================================================================
// MARK: - Today
// =====================================================================================

struct WeekChart: View, Equatable {
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
                Section { BalanceCardView() }
                Section("Last 7 days") { WeekChart(days: today.week) }
                Section {
                    if today.txs.isEmpty {
                        Label("No spends yet today", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        ForEach(today.txs) { SpendRow(t: $0) }
                    }
                } header: {
                    HStack {
                        Text("Today's spends")
                        Spacer()
                        Button { store.showAddSheet = true } label: {
                            Label("Add Spend", systemImage: "plus.circle.fill").font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo(size: 28) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.toggleMask() } label: { Image(systemName: store.masked ? "eye.slash" : "eye") }
                        .accessibilityLabel(store.masked ? "Show amounts" : "Hide amounts")
                    Button { store.showAddSheet = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add manual spend")
                }
            }
            .refreshable { await store.refresh(force: true) }
            .sensoryFeedback(.success, trigger: store.newSpendTick)
            .overlay { if !store.hasData && !store.balanceStatus.isConfigured { EmptyStateView() } }
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
// MARK: - Monthly Fixed Expenses Sheet
// =====================================================================================

struct FixedExpensesView: View {
    @Environment(Store.self) private var store
    private var m: MonthStats { store.month }
    private var fx: FixedMonthSummary { m.fixed }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                bucketsSection
                if store.balanceStatus.isConfigured {
                    balanceImpactSection
                }
            }
            .navigationTitle("Fixed Expenses")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.showAddSheet = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add spend")
                }
            }
            .refreshable { await store.refresh(force: true) }
        }
    }

    private var headerSection: some View {
        Section {
            HStack {
                Button { store.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
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
                    .buttonStyle(.borderless).disabled(m.isCurrent)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fixed Spends So Far").font(.caption).foregroundStyle(.secondary)
                        Text(store.m(fx.totalSpent))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    if fx.totalBudgeted > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Monthly Plan").font(.caption).foregroundStyle(.secondary)
                            Text(store.m(fx.totalBudgeted))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if fx.totalBudgeted > 0 {
                    ProgressView(value: min(max(fx.totalSpent.dbl / fx.totalBudgeted.dbl, 0), 1))
                        .tint(fx.totalSpent > fx.totalBudgeted ? .red : .indigo)
                    HStack {
                        Text("\(store.m(fx.unpaidRemaining)) still pending from planned bills")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        let pct = Int((fx.totalSpent.dbl / max(fx.totalBudgeted.dbl, 1) * 100).rounded())
                        Text("\(pct)%").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Tap 'Set target' or swipe any row below to set your monthly fixed amounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var bucketsSection: some View {
        Section {
            ForEach(fx.items) { item in
                NavigationLink {
                    FixedBucketDetailScreen(bucket: item.bucket)
                } label: {
                    fixedRow(item)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        store.fixedBudgetTarget = FixedBudgetTarget(bucket: item.bucket)
                    } label: {
                        Label("Set Plan", systemImage: "target")
                    }
                    .tint(.indigo)
                }
            }
        } header: {
            Text("Monthly Fixed Sheet (Auto-Updated)")
        } footer: {
            Text("Groceries, Food, Fuel, Rent, Home, and Electricity bills auto-detect from your transactions. You can also pin any transaction manually from its detail sheet.")
        }
    }

    private func fixedRow(_ item: FixedItemStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                FixedBadge(bucket: item.bucket, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.bucket.rawValue).font(.body.weight(.medium))
                    Text(item.count == 0 ? "No spends yet" : "\(item.count) spend\(item.count == 1 ? "" : "s") auto-tracked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.m(item.spent))
                        .font(.body.bold())
                        .monospacedDigit()
                        .foregroundStyle(item.spent > 0 ? Color.primary : Color.secondary)
                    if let target = item.target {
                        Text("of \(store.m(target))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Button("Set target") {
                            store.fixedBudgetTarget = FixedBudgetTarget(bucket: item.bucket)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let target = item.target, target > 0 {
                let ratio = min(max(item.spent.dbl / target.dbl, 0), 1)
                ProgressView(value: ratio)
                    .tint(item.spent > target ? .red : (ratio >= 0.9 ? .orange : .green))
                HStack {
                    if item.spent >= target {
                        Label(item.spent == target ? "Paid in full" : "Over plan by \(store.m(item.spent - target))",
                              systemImage: item.spent == target ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(item.spent == target ? .green : .red)
                    } else {
                        Text("\(store.m(target - item.spent)) remaining")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var balanceImpactSection: some View {
        let bal = store.balanceStatus
        return Section("Bank Balance Projection") {
            LabeledContent("Real Bank Balance Left", value: store.m(bal.realRemaining))
            LabeledContent("Pending Fixed Expenses", value: "−\(store.m(bal.unpaidFixedCommitments))")
            LabeledContent("Free Balance After Fixed Bills") {
                Text(store.m(bal.safeToSpend))
                    .bold()
                    .foregroundStyle(bal.safeToSpend < 0 ? Color.red : Color.green)
            }
        }
    }
}

struct FixedBucketDetailScreen: View {
    @Environment(Store.self) private var store
    let bucket: FixedBucket

    private var item: FixedItemStat {
        store.month.fixed.items.first { $0.bucket == bucket }
            ?? FixedItemStat(bucket: bucket, spent: 0, target: nil, count: 0, txs: [])
    }

    var body: some View {
        let currentItem = item
        let groups = groupByDay(currentItem.txs)
        List {
            Section {
                HStack {
                    FixedBadge(bucket: bucket, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.m(currentItem.spent))
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text(bucket.ruleDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Target") {
                        store.fixedBudgetTarget = FixedBudgetTarget(bucket: bucket)
                    }
                    .buttonStyle(.bordered)
                }
                if let target = currentItem.target {
                    LabeledContent("Monthly Target", value: store.m(target))
                    LabeledContent("Difference", value: currentItem.spent > target ? "+\(store.m(currentItem.spent - target))" : store.m(target - currentItem.spent))
                }
            }
            if groups.isEmpty {
                Section {
                    Text("No transactions matched for \(bucket.rawValue) in \(store.month.period.title).")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groups) { g in
                    Section {
                        ForEach(g.items) { SpendRow(t: $0) }
                    } header: { DayHeader(g: g) }
                }
            }
        }
        .navigationTitle(bucket.rawValue)
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var groups: [DayGroup] = []
    @State private var totalAmount: Decimal = 0
    @State private var totalCount: Int = 0

    private struct CalcKey: Equatable {
        var version: Int
        var anchor: Date
        var todayOnly: Bool
        var scope: Scope
    }

    private var calcKey: CalcKey {
        CalcKey(version: store.version, anchor: store.month.period.anchor, todayOnly: todayOnly, scope: scope)
    }

    var body: some View {
        List {
            Section {
                if case .bank = scope {
                    Picker("Scope", selection: $todayOnly) {
                        Text("Today").tag(true)
                        Text(store.month.period.title).tag(false)
                    }.pickerStyle(.segmented)
                }
                HStack {
                    Text(store.m(totalAmount))
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Spacer()
                    Text("\(totalCount) spends").foregroundStyle(.secondary)
                }
                if totalCount == 0 { Text("No spends").foregroundStyle(.secondary) }
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.items) { SpendRow(t: $0) }
                } header: { DayHeader(g: g) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: calcKey, initial: true) { _, _ in
            let all = store.month.txs.filter { scope.matches($0) }
            let shown = todayOnly ? all.filter { Calendar.current.isDateInToday($0.date) } : all
            totalCount = shown.count
            totalAmount = shown.reduce(Decimal.zero) { $1.counted ? $0 + $1.amt : $0 }
            groups = groupByDay(shown)
        }
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !store.review.isEmpty {
                        Button { showReview = true } label: {
                            Label("Review (\(store.review.count))", systemImage: "tray.full")
                        }
                    }
                    Button { store.showAddSheet = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add manual spend")
                }
            }
            .refreshable { await store.refresh(force: true) }
            .task(id: search) {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                query = search.trimmingCharacters(in: .whitespaces)
            }
            .task(id: key) {
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
// MARK: - Sheets: Add Spend, Edit/Delete Spend Detail, Bank Balance, Review, Budgets
// =====================================================================================

struct AddTxSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var merchant = ""
    @State private var src = "HDFC Credit Card"
    @State private var last4 = "0000"
    @State private var date = Date()
    @State private var cat = "Food"
    @State private var userPickedCat = false
    @State private var userPickedFixed = false
    @State private var fixedBucket: FixedBucket? = .food

    private var parsedAmount: Decimal? {
        let cleaned = amountText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), !d.isNaN, d != 0 else { return nil }
        return d
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Spend Details") {
                    HStack {
                        Text("₹").font(.title2.bold()).foregroundStyle(.secondary)
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                    }
                    TextField("Merchant / Description (e.g. Bescom, Swiggy)", text: $merchant)
                        .onChange(of: merchant) { _, newVal in
                            let key = Merchant.key(newVal)
                            let detectedCat = store.overrides[key] ?? Categorizer.category(for: newVal)
                            if !userPickedCat {
                                cat = detectedCat
                            }
                            if !userPickedFixed {
                                if let pinned = store.fixedMerchantMap[key] {
                                    fixedBucket = (pinned == "NONE") ? nil : FixedBucket(rawValue: pinned)
                                } else {
                                    fixedBucket = Categorizer.fixedBucket(for: newVal, category: userPickedCat ? cat : detectedCat)
                                }
                            }
                        }
                    DatePicker("Date & Time", selection: $date)
                }

                Section("Payment Method") {
                    if !store.sources.isEmpty {
                        Menu {
                            ForEach(store.sources) { pair in
                                Button("\(pair.src) (\(pair.last4))") {
                                    src = pair.src
                                    last4 = pair.last4
                                }
                            }
                            Button("Cash / Manual (0000)") {
                                src = "Cash"
                                last4 = "0000"
                            }
                        } label: {
                            LabeledContent("Quick Select Card/Account") {
                                Text("\(src) · \(last4)").foregroundStyle(.indigo)
                            }
                        }
                    }
                    TextField("Source (e.g. HDFC Credit Card, SBI Account)", text: $src)
                    TextField("Last 4 Digits", text: $last4)
                        .keyboardType(.numberPad)
                }

                Section("Category & Fixed Expense Sheet") {
                    Picker("Category", selection: Binding(
                        get: { cat },
                        set: { newCat in
                            userPickedCat = true
                            cat = newCat
                            if !userPickedFixed {
                                if newCat == "Food" { fixedBucket = .food }
                                else if newCat == "Groceries" { fixedBucket = .groceries }
                                else if fixedBucket == .food || fixedBucket == .groceries { fixedBucket = nil }
                            }
                        }
                    )) {
                        ForEach(Cats.names, id: \.self) { n in
                            Label(n, systemImage: Cats.symbol(n)).tag(n)
                        }
                    }

                    Picker("Fixed Monthly Bucket", selection: Binding(
                        get: { fixedBucket },
                        set: { newBucket in
                            userPickedFixed = true
                            fixedBucket = newBucket
                        }
                    )) {
                        Text("None (Not a Fixed Expense)").tag(Optional<FixedBucket>.none)
                        ForEach(FixedBucket.allCases) { b in
                            Label(b.rawValue, systemImage: b.symbol).tag(Optional(b))
                        }
                    }
                }
            }
            .navigationTitle("Add Spend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let amt = parsedAmount else { return }
                        store.addManualTx(date: date, src: src, last4: last4, amt: amt, merchant: merchant, cat: cat, fixedBucket: fixedBucket)
                        dismiss()
                    }
                    .disabled(parsedAmount == nil)
                }
            }
            .onAppear {
                if let first = store.sources.first {
                    src = first.src
                    last4 = first.last4
                }
            }
        }
    }
}

struct TxDetail: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let t: Tx

    @State private var amountText: String
    @State private var merchant: String
    @State private var src: String
    @State private var last4: String
    @State private var date: Date
    @State private var cat: String
    @State private var applyCatAll = false
    @State private var fixedBucket: FixedBucket?
    @State private var applyFixedAll = false
    @State private var confirmDelete = false

    init(t: Tx) {
        self.t = t
        _amountText = State(initialValue: "\(t.amt)")
        _merchant = State(initialValue: t.merchant)
        _src = State(initialValue: t.src)
        _last4 = State(initialValue: t.last4)
        _date = State(initialValue: t.date)
        _cat = State(initialValue: t.cat)
        _fixedBucket = State(initialValue: t.fixedBucket)
    }

    private var parsedAmount: Decimal? {
        let cleaned = amountText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), !d.isNaN else { return nil }
        return d
    }

    var body: some View {
        let currentKey = Merchant.key(merchant)
        let matchCount = store.keyCounts[currentKey, default: 0]
        let cleanName = Merchant.clean(merchant)

        NavigationStack {
            Form {
                Section("Edit Entry Details") {
                    HStack {
                        Text("₹").font(.title2.bold()).foregroundStyle(.secondary)
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                    }
                    TextField("Merchant", text: $merchant)
                    TextField("Bank / Card Name", text: $src)
                    TextField("Last 4 Digits", text: $last4)
                        .keyboardType(.numberPad)
                    DatePicker("When", selection: $date)
                }

                Section("Category") {
                    Picker("Category", selection: $cat) {
                        ForEach(Cats.names, id: \.self) { n in
                            Label(n, systemImage: Cats.symbol(n)).tag(n)
                        }
                    }
                    if matchCount > 1 {
                        Toggle("Apply category to all “\(cleanName)” (\(matchCount))", isOn: $applyCatAll)
                    }
                }

                Section {
                    Picker("Fixed Expense Sheet", selection: $fixedBucket) {
                        Text("None").tag(Optional<FixedBucket>.none)
                        ForEach(FixedBucket.allCases) { b in
                            Label(b.rawValue, systemImage: b.symbol).tag(Optional(b))
                        }
                    }
                    if matchCount > 1 {
                        Toggle("Always map “\(cleanName)” to this fixed sheet", isOn: $applyFixedAll)
                    }
                } header: {
                    Text("Monthly Fixed Expense Tracking")
                } footer: {
                    Text("Assigning this links the spend to your monthly Fixed Expenses tab.")
                }

                Section {
                    Toggle("Exclude from totals", isOn: Binding(
                        get: { store.excluded.contains(t.id) },
                        set: { _ in store.toggleExclude(t) }))
                    Button("Reset category & fixed bucket to automatic") {
                        store.resetCategory(t)
                        dismiss()
                    }
                    Button("Delete Spend", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
            .navigationTitle("Edit Spend")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete this spend?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Spend", role: .destructive) {
                    store.deleteTx(t)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amt = parsedAmount else { return }
                        store.updateTx(t, date: date, src: src, last4: last4, amt: amt, merchant: merchant,
                                       cat: cat, applyCatAll: applyCatAll, fixedBucket: fixedBucket, applyFixedAll: applyFixedAll)
                        dismiss()
                    }
                    .disabled(parsedAmount == nil)
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct BankBalanceSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var mode = "month"
    @State private var asOfDate = Date()

    private var value: Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v >= 0 else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("₹").font(.title2.bold()).foregroundStyle(.secondary)
                        TextField("Total Bank Balance", text: $text)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([25000, 50000, 100000, 200000, 500000], id: \.self) { v in
                                Button { text = String(v) } label: {
                                    Chip(title: inrCompact(Double(v)), icon: "plus", active: text == String(v))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Total Available Balance")
                }

                Section {
                    Picker("Deduct Spends From", selection: $mode) {
                        Text("Current Billing Cycle (\(store.month.period.title))").tag("month")
                        Text("Specific Date & Time").tag("sinceDate")
                    }
                    if mode == "sinceDate" {
                        DatePicker("Balance Entered As Of", selection: $asOfDate)
                    }
                } header: {
                    Text("How should spends be deducted?")
                } footer: {
                    Text(mode == "month"
                         ? "Deducts all counted spends in the current billing month from your starting balance."
                         : "Deducts only counted spends that occurred after the timestamp above.")
                }

                if store.bankBalance != nil {
                    Section {
                        Button("Clear Bank Balance", role: .destructive) {
                            store.updateBankBalance(amount: nil, asOf: .now, mode: "month")
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Bank Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let v = value {
                            store.updateBankBalance(amount: v, asOf: asOfDate, mode: mode)
                        }
                        dismiss()
                    }
                    .disabled(value == nil)
                }
            }
            .onAppear {
                text = store.bankBalance.map { String(Int($0)) } ?? ""
                mode = store.bankBalanceMode
                asOfDate = store.bankBalanceDate
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct FixedBudgetSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: FixedBudgetTarget
    @State private var text = ""

    private var value: Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v > 0 else { return nil }
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        FixedBadge(bucket: target.bucket, size: 32)
                        Text(target.bucket.rawValue).font(.headline)
                    }
                    TextField("Monthly planned amount in ₹", text: $text)
                        .keyboardType(.numberPad)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach([1500, 3000, 5000, 10000, 25000, 40000], id: \.self) { v in
                                Button { text = String(v) } label: {
                                    Chip(title: inrCompact(Double(v)), icon: "plus", active: text == String(v))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } footer: {
                    Text(target.bucket.ruleDescription)
                }

                if store.fixedTargets[target.bucket.rawValue] != nil {
                    Section {
                        Button("Remove Target", role: .destructive) {
                            store.setFixedTarget(target.bucket, nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("\(target.bucket.rawValue) Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let v = value { store.setFixedTarget(target.bucket, v) }
                        dismiss()
                    }
                    .disabled(value == nil)
                }
            }
            .onAppear {
                text = store.fixedTargets[target.bucket.rawValue].map { String(Int($0)) } ?? ""
            }
        }
        .presentationDetents([.medium])
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
        case .noFile: return "Connect the CSV that your Shortcut writes to, or add spends manually."
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
                        Label("Or tap + anytime to add spends manually", systemImage: "3.circle")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                if store.skipped > 0 {
                    Text("\(store.skipped) lines couldn't be read. Expected: 2026-10-01 11:40, Card|1234|450.00|Merchant")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Button("Choose CSV file") { store.showPicker = true }.buttonStyle(.borderedProminent)
                Button("Add a manual spend") { store.showAddSheet = true }.buttonStyle(.bordered)
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
                Section("Bank Balance") {
                    Button { store.showBalanceSheet = true } label: {
                        LabeledContent("Starting Balance") {
                            Text(store.bankBalance.map { inr(Decimal($0)) } ?? "Not set")
                                .foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                    if store.balanceStatus.isConfigured {
                        LabeledContent("Real Balance Left") {
                            Text(store.m(store.balanceStatus.realRemaining)).bold()
                        }
                    }
                }

                Section("Data file") {
                    LabeledContent("Status") { SyncLabel() }
                    Button("Choose CSV file", systemImage: "doc") { store.showPicker = true }
                    Button("Refresh now", systemImage: "arrow.clockwise") { Task { await store.refresh(force: true) } }
                    Button("Use sample data", systemImage: "wand.and.stars") { store.useSample() }
                    if store.skipped > 0 {
                        Text("\(store.skipped) lines couldn't be read").foregroundStyle(.orange)
                    }
                }

                Section("Monthly Fixed Expense Targets") {
                    ForEach(FixedBucket.allCases) { b in
                        Button { store.fixedBudgetTarget = FixedBudgetTarget(bucket: b) } label: {
                            LabeledContent(b.rawValue) {
                                Text(store.fixedTargets[b.rawValue].map { inr(Decimal($0)) } ?? "Not set")
                                    .foregroundStyle(.secondary)
                            }
                        }.foregroundStyle(.primary)
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
                } header: { Text("Category budgets") }

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
            FixedExpensesView().tabItem { Label("Fixed", systemImage: "checklist.checked") }
            MonthView().tabItem { Label("Month", systemImage: "chart.pie") }
            SpendsView().tabItem { Label("Spends", systemImage: "list.bullet") }
                .badge(store.review.count)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(item: Binding(get: { store.detailTx }, set: { store.detailTx = $0 })) { TxDetail(t: $0) }
        .sheet(isPresented: Binding(get: { store.showAddSheet }, set: { store.showAddSheet = $0 })) { AddTxSheet() }
        .sheet(isPresented: Binding(get: { store.showBalanceSheet }, set: { store.showBalanceSheet = $0 })) { BankBalanceSheet() }
        .sheet(item: Binding(get: { store.budgetTarget }, set: { store.budgetTarget = $0 })) { BudgetSheet(target: $0) }
        .sheet(item: Binding(get: { store.fixedBudgetTarget }, set: { store.fixedBudgetTarget = $0 })) { FixedBudgetSheet(target: $0) }
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
