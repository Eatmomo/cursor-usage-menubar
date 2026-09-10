// cursor-usage-menubar — macOS 菜单栏 Cursor 订阅用量监视器
// 数据源:
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents
//   GET  https://cursor.com/api/usage-summary  (on-demand 池)
// 鉴权: 本机 Cursor IDE 登录态 ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
//
// 注意: autoPercentUsed / apiPercentUsed 已是「百分点」数值（0.69 ≈ 官网 1%），不要再 ×100。
// 官网计划池两项 = Cursor Models (auto*) + Other Models (api*/named*)。
import AppKit
import ServiceManagement
import SQLite3

let DASHBOARD_BASE = "https://cursor.com/dashboard"
let API2 = "https://api2.cursor.sh"
let USAGE_SUMMARY = "https://cursor.com/api/usage-summary"
let STATE_DB = NSString(string: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb").expandingTildeInPath
let DISPLAY_KEY = "displayMetric"
let HEATMAP_EXPANDED_KEY = "heatmapExpanded"
let HEATMAP_SUMMARY_KEY = "heatmapSummary" // week | month
/// 与官网 Usage 页一致：Cursor Models / Other Models
let DISPLAY_MODES = ["cursorModels", "otherModels"]
let DISPLAY_LABELS = ["Cursor Models", "Other Models"]
/// Codex 风格贡献图周数（菜单栏宽度折中；Codex 桌面为 53）
let HEATMAP_WEEKS = 26

/// 菜单栏图标（Cursor_icns.icns）
let iconImage: NSImage? = {
    func find(_ base: URL) -> String? {
        let cands = [
            base.appendingPathComponent("Cursor_icns.icns").path,
            base.appendingPathComponent("Resources/AppIcon.icns").path,
            base.appendingPathComponent("Resources/Cursor_icns.icns").path,
        ]
        return cands.first { FileManager.default.fileExists(atPath: $0) }
    }
    let bin = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    // .app/Contents/MacOS → Resources；裸二进制 → 同目录
    let res = bin.deletingLastPathComponent().appendingPathComponent("Resources")
    guard let p = find(bin) ?? find(res) ?? find(bin.deletingLastPathComponent()),
          let img = NSImage(contentsOfFile: p) else { return nil }
    let ratio = img.size.width / max(img.size.height, 1)
    img.size = NSSize(width: 16 * ratio, height: 16)
    img.isTemplate = false
    return img
}()

struct ModelSpend {
    var name: String
    var cents: Double
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var eventCount: Int
    var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens }
}

struct DayTokens {
    var day: Date   // 当天 00:00
    var tokens: Int64
    var events: Int
}

struct Snapshot {
    var updatedAt: Date
    var membership: String?
    var cycleStart: Date?
    var cycleEnd: Date?
    var planUsedCents: Double?
    var planLimitCents: Double?
    var planRemainingCents: Double?
    /// autoPercentUsed / apiPercentUsed 原值（直接后缀 %）
    var cursorModelsPercent: Double?
    var otherModelsPercent: Double?
    var cursorModelsMessage: String?
    var otherModelsMessage: String?
    var onDemandEnabled: Bool?
    var onDemandUsedCents: Double?
    var onDemandLimitCents: Double?
    var models: [ModelSpend]
    /// 按日 Token（用于周热力图，含本周期外最近数周）
    var dailyTokens: [DayTokens]
    var error: String?
}

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func msToDate(_ v: Any?) -> Date? {
    if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000.0) }
    if let s = v as? String, let n = Double(s) { return Date(timeIntervalSince1970: n / 1000.0) }
    if let s = v as? String { return parseISO(s) }
    return nil
}

func asDouble(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String, let d = Double(s) { return d }
    return nil
}

func asInt64(_ v: Any?) -> Int64 {
    if let n = v as? NSNumber { return n.int64Value }
    if let s = v as? String, let i = Int64(s) { return i }
    return 0
}

func readSQLiteValue(dbPath: String, key: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
    defer { sqlite3_close(db) }
    let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    if let c = sqlite3_column_text(stmt, 0) {
        return String(cString: c)
    }
    return nil
}

func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = (4 - b64.count % 4) % 4
    b64 += String(repeating: "=", count: pad)
    guard let data = Data(base64Encoded: b64) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func loadAuth() -> (token: String, userId: String)? {
    guard let token = readSQLiteValue(dbPath: STATE_DB, key: "cursorAuth/accessToken"), !token.isEmpty else { return nil }
    let payload = jwtPayload(token) ?? [:]
    var sub = (payload["sub"] as? String) ?? ""
    if sub.hasPrefix("auth0|") { sub = String(sub.dropFirst(6)) }
    guard !sub.isEmpty else { return nil }
    return (token, sub)
}

func httpJSON(url: String, method: String, token: String, userId: String?, body: [String: Any]?) async throws -> [String: Any] {
    guard let u = URL(string: url) else { throw URLError(.badURL) }
    var req = URLRequest(url: u)
    req.httpMethod = method
    req.timeoutInterval = 20
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if url.contains("api2.cursor.sh") {
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    } else if let userId {
        let cookie = "WorkosCursorSessionToken=\(userId)%3A%3A\(token)"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
    }
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        let msg = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
        throw NSError(domain: "cursor-usage", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "http-\(http.statusCode) \(msg)"])
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "cursor-usage", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad-json"])
    }
    return obj
}

/// 展示 API 返回的 model / modelIntent 原名；default = Auto 路由（官方不披露底层模型）
func displayModelName(_ raw: String) -> String {
    if raw == "default" { return "default（Auto 路由）" }
    return raw
}

func fmtPct(_ p: Double?) -> String {
    guard let p else { return "—" }
    return String(format: "%.1f", p)
}

func fmtCents(_ cents: Double?) -> String {
    guard let c = cents else { return "—" }
    return String(format: "$%.2f", c / 100.0)
}

func fmtTokens(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func fmtCountdown(_ d: Date) -> String {
    let secs = Int(d.timeIntervalSinceNow)
    if secs <= 0 { return "已重置" }
    let days = secs / 86400, hours = (secs % 86400) / 3600, mins = (secs % 3600) / 60
    if days > 0 { return "\(days)天\(hours)小时" }
    if hours > 0 { return "\(hours)小时\(mins)分" }
    return "\(mins)分\(secs % 60)秒"
}

func colorFor(_ pct: Double) -> NSColor {
    if pct >= 80 { return .systemRed }
    if pct >= 60 { return .systemOrange }
    return .systemGreen
}

func mergeModels(agg: [[String: Any]], events: [[String: Any]]) -> [ModelSpend] {
    var map: [String: ModelSpend] = [:]

    func upsert(_ name: String, cents: Double, input: Int64, output: Int64, cache: Int64, events: Int) {
        var cur = map[name] ?? ModelSpend(name: name, cents: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, eventCount: 0)
        // Prefer larger token/cents totals (agg is authoritative when present)
        if cents > cur.cents { cur.cents = cents }
        if input > cur.inputTokens { cur.inputTokens = input }
        if output > cur.outputTokens { cur.outputTokens = output }
        if cache > cur.cacheReadTokens { cur.cacheReadTokens = cache }
        cur.eventCount += events
        map[name] = cur
    }

    for a in agg {
        let name = (a["modelIntent"] as? String) ?? "?"
        upsert(name,
               cents: asDouble(a["totalCents"]) ?? 0,
               input: asInt64(a["inputTokens"]),
               output: asInt64(a["outputTokens"]),
               cache: asInt64(a["cacheReadTokens"]),
               events: 0)
    }

    // Event feed: sum when agg missed cents; always count events; pick up concrete model ids
    var eventCents: [String: Double] = [:]
    var eventCount: [String: Int] = [:]
    var eventIn: [String: Int64] = [:]
    var eventOut: [String: Int64] = [:]
    var eventCache: [String: Int64] = [:]
    for e in events {
        let name = (e["model"] as? String) ?? (e["modelIntent"] as? String) ?? "?"
        eventCount[name, default: 0] += 1
        let tu = e["tokenUsage"] as? [String: Any] ?? [:]
        let c = asDouble(e["chargedCents"]) ?? asDouble(tu["totalCents"]) ?? 0
        eventCents[name, default: 0] += c
        eventIn[name, default: 0] += asInt64(tu["inputTokens"])
        eventOut[name, default: 0] += asInt64(tu["outputTokens"])
        eventCache[name, default: 0] += asInt64(tu["cacheReadTokens"])
    }
    for (name, n) in eventCount {
        let existing = map[name]
        let cents: Double
        if let ex = existing, ex.cents > 0 {
            cents = ex.cents
        } else {
            cents = eventCents[name] ?? 0
        }
        upsert(name,
               cents: cents,
               input: max(existing?.inputTokens ?? 0, eventIn[name] ?? 0),
               output: max(existing?.outputTokens ?? 0, eventOut[name] ?? 0),
               cache: max(existing?.cacheReadTokens ?? 0, eventCache[name] ?? 0),
               events: n)
    }

    return map.values.sorted {
        if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
        return $0.eventCount > $1.eventCount
    }
}

func startOfDay(_ d: Date) -> Date {
    Calendar.current.startOfDay(for: d)
}

/// 周一为一周起点
func startOfWeek(_ d: Date) -> Date {
    let cal = Calendar.current
    let day = startOfDay(d)
    let weekday = cal.component(.weekday, from: day) // 1=Sun … 7=Sat
    let daysFromMonday = (weekday + 5) % 7
    return cal.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
}

func buildDailyTokens(from events: [[String: Any]]) -> [DayTokens] {
    var map: [TimeInterval: (Int64, Int)] = [:]
    for e in events {
        guard let ts = asDouble(e["timestamp"]) else { continue }
        let day = startOfDay(Date(timeIntervalSince1970: ts / 1000.0))
        let key = day.timeIntervalSince1970
        let tu = e["tokenUsage"] as? [String: Any] ?? [:]
        let tok = asInt64(tu["inputTokens"]) + asInt64(tu["outputTokens"]) + asInt64(tu["cacheReadTokens"])
        let cur = map[key] ?? (0, 0)
        map[key] = (cur.0 + tok, cur.1 + 1)
    }
    return map.keys.sorted().map { k in
        let v = map[k]!
        return DayTokens(day: Date(timeIntervalSince1970: k), tokens: v.0, events: v.1)
    }
}

func fetchAllCycleEvents(token: String, userId: String, start: Int64, end: Int64) async throws -> [[String: Any]] {
    var out: [[String: Any]] = []
    var page = 1
    var total = Int.max
    while out.count < total && page <= 30 {
        let resp = try await httpJSON(
            url: "\(API2)/aiserver.v1.DashboardService/GetFilteredUsageEvents",
            method: "POST", token: token, userId: userId,
            body: ["startDate": start, "endDate": end, "page": page, "pageSize": 100]
        )
        let batch = resp["usageEventsDisplay"] as? [[String: Any]] ?? []
        total = (resp["totalUsageEventsCount"] as? NSNumber)?.intValue ?? batch.count
        out.append(contentsOf: batch)
        if batch.isEmpty { break }
        page += 1
    }
    return out
}

func refreshSnapshot() async -> Snapshot {
    func empty(error: String?) -> Snapshot {
        Snapshot(updatedAt: Date(), membership: nil, cycleStart: nil, cycleEnd: nil,
                 planUsedCents: nil, planLimitCents: nil, planRemainingCents: nil,
                 cursorModelsPercent: nil, otherModelsPercent: nil,
                 cursorModelsMessage: nil, otherModelsMessage: nil,
                 onDemandEnabled: nil, onDemandUsedCents: nil, onDemandLimitCents: nil,
                 models: [], dailyTokens: [], error: error)
    }
    guard let auth = loadAuth() else { return empty(error: "no-auth") }
    do {
        async let periodP = httpJSON(url: "\(API2)/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                                     method: "POST", token: auth.token, userId: auth.userId, body: [:])
        async let summaryP = httpJSON(url: USAGE_SUMMARY, method: "GET", token: auth.token, userId: auth.userId, body: nil)

        let period = try await periodP
        let summary = try? await summaryP
        let plan = period["planUsage"] as? [String: Any]

        // autoPercentUsed / apiPercentUsed 原样使用（不要 ×100）
        let cursorPct = asDouble(plan?["autoPercentUsed"])
            ?? asDouble(((summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])?["autoPercentUsed"])
        let otherPct = asDouble(plan?["apiPercentUsed"])
            ?? asDouble(((summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])?["apiPercentUsed"])

        var snap = Snapshot(
            updatedAt: Date(),
            membership: (summary?["membershipType"] as? String)
                ?? readSQLiteValue(dbPath: STATE_DB, key: "cursorAuth/stripeMembershipType"),
            cycleStart: msToDate(period["billingCycleStart"]) ?? msToDate(summary?["billingCycleStart"]),
            cycleEnd: msToDate(period["billingCycleEnd"]) ?? msToDate(summary?["billingCycleEnd"]),
            planUsedCents: asDouble(plan?["totalSpend"]),
            planLimitCents: asDouble(plan?["limit"]),
            planRemainingCents: asDouble(plan?["remaining"]),
            cursorModelsPercent: cursorPct,
            otherModelsPercent: otherPct,
            cursorModelsMessage: period["autoModelSelectedDisplayMessage"] as? String
                ?? summary?["autoModelSelectedDisplayMessage"] as? String,
            otherModelsMessage: period["namedModelSelectedDisplayMessage"] as? String
                ?? summary?["namedModelSelectedDisplayMessage"] as? String,
            onDemandEnabled: nil,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            models: [],
            dailyTokens: [],
            error: nil
        )

        if let indiv = summary?["individualUsage"] as? [String: Any],
           let od = indiv["onDemand"] as? [String: Any] {
            snap.onDemandEnabled = od["enabled"] as? Bool
            snap.onDemandUsedCents = asDouble(od["used"])
            snap.onDemandLimitCents = asDouble(od["limit"])
        }
        if snap.planUsedCents == nil,
           let planS = (summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] {
            snap.planUsedCents = asDouble(planS["used"])
            snap.planLimitCents = asDouble(planS["limit"])
            snap.planRemainingCents = asDouble(planS["remaining"])
        }

        let startMs = Int64(asDouble(period["billingCycleStart"]) ?? 0)
        let endMs = Int64(asDouble(period["billingCycleEnd"]) ?? 0)
        // 热力图：近 HEATMAP_WEEKS 周（Codex 同款贡献图窗口）
        let heatDays = Double(HEATMAP_WEEKS * 7 + 7)
        let heatStartMs = Int64(Date().addingTimeInterval(-heatDays * 86400).timeIntervalSince1970 * 1000)
        let heatEndMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fetchStart = min(startMs == 0 ? heatStartMs : startMs, heatStartMs)
        let fetchEnd = max(endMs == 0 ? heatEndMs : endMs, heatEndMs)

        async let aggP = httpJSON(url: "\(API2)/aiserver.v1.DashboardService/GetAggregatedUsageEvents",
                                  method: "POST", token: auth.token, userId: auth.userId,
                                  body: ["startDate": startMs, "endDate": endMs])
        async let eventsP = fetchAllCycleEvents(token: auth.token, userId: auth.userId, start: fetchStart, end: fetchEnd)

        let agg = try await aggP
        let events = (try? await eventsP) ?? []
        let cycleEvents = events.filter { e in
            guard let ts = asDouble(e["timestamp"]) else { return false }
            return ts >= Double(startMs) && ts <= Double(endMs)
        }
        let aggList = agg["aggregations"] as? [[String: Any]] ?? []
        snap.models = mergeModels(agg: aggList, events: cycleEvents)
        snap.dailyTokens = buildDailyTokens(from: events)
        return snap
    } catch {
        return empty(error: String(describing: error).prefix(140).description)
    }
}

final class RingView: NSView {
    var pct: Double = 0 { didSet { needsDisplay = true } }
    var ringColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = bounds.width
        let lw: CGFloat = 2.5
        let rect = CGRect(x: lw / 2, y: lw / 2, width: s - lw, height: s - lw)
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.4).cgColor)
        ctx.strokeEllipse(in: rect)
        let p = min(max(pct, 0), 100)
        if p > 0 {
            ctx.setStrokeColor(ringColor.cgColor)
            ctx.setLineCap(.round)
            let start = CGFloat(-Double.pi / 2)
            let end = start + CGFloat(p / 100.0) * 2 * .pi
            ctx.addArc(center: CGPoint(x: s / 2, y: s / 2), radius: (s - lw) / 2, startAngle: start, endAngle: end, clockwise: false)
            ctx.strokePath()
        }
    }
}

func makeRow(text: String, pct: Double?, width: CGFloat = 320) -> NSMenuItem {
    let item = NSMenuItem()
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
    let ring = RingView(frame: NSRect(x: 8, y: 2, width: 16, height: 16))
    ring.pct = pct ?? 0
    ring.ringColor = pct.map { colorFor($0) } ?? .secondaryLabelColor
    let label = NSTextField(labelWithString: text)
    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    label.textColor = .labelColor
    label.cell?.lineBreakMode = .byTruncatingTail
    label.frame = NSRect(x: 30, y: 2, width: width - 38, height: 16)
    v.addSubview(ring)
    v.addSubview(label)
    item.view = v
    return item
}

/// 本周 / 本月 Token 合计
func tokensInRange(days: [DayTokens], from start: Date, to end: Date) -> Int64 {
    let s = startOfDay(start).timeIntervalSince1970
    let e = startOfDay(end).timeIntervalSince1970
    return days.filter { $0.day.timeIntervalSince1970 >= s && $0.day.timeIntervalSince1970 <= e }
        .reduce(Int64(0)) { $0 + $1.tokens }
}

func startOfMonth(_ d: Date) -> Date {
    let cal = Calendar.current
    let c = cal.dateComponents([.year, .month], from: d)
    return cal.date(from: c).map(startOfDay) ?? startOfDay(d)
}

/// 周日为一周起点（Codex / GitHub 贡献图）
func startOfSundayWeek(_ d: Date) -> Date {
    let cal = Calendar.current
    let day = startOfDay(d)
    let weekday = cal.component(.weekday, from: day) // 1=Sun … 7=Sat
    return cal.date(byAdding: .day, value: -(weekday - 1), to: day) ?? day
}

func dayKey(_ d: Date) -> Int {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return (c.year! * 10_000) + (c.month! * 100) + c.day!
}

/// Codex 风格绿阶贡献图（仅网格 + 悬停浮窗；折叠/合计用菜单项）
final class HeatmapGridView: NSView {
    var days: [DayTokens] = [] { didSet { needsDisplay = true } }
    var weekCount: Int = HEATMAP_WEEKS

    private var hoveredDay: Date?
    private var hoveredTokens: Int64 = 0
    private var tracking: NSTrackingArea?
    private var cellFrames: [(rect: NSRect, day: Date, tokens: Int64)] = []
    private var tokenByDay: [Int: Int64] = [:]

    private func heatColor(level: Int) -> NSColor {
        func rgb(_ h: UInt32) -> NSColor {
            NSColor(calibratedRed: CGFloat((h >> 16) & 0xFF) / 255,
                    green: CGFloat((h >> 8) & 0xFF) / 255,
                    blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
        switch level {
        case 4: return rgb(0x216E39)
        case 3: return rgb(0x30A14E)
        case 2: return rgb(0x40C463)
        case 1: return rgb(0x9BE9A8)
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.22, alpha: 1)
                : rgb(0xEBEDF0)
        }
    }

    private func level(for tok: Int64, maxTok: Int64) -> Int {
        if tok <= 0 || maxTok <= 0 { return 0 }
        let r = Double(tok) / Double(maxTok)
        if r > 0.75 { return 4 }
        if r > 0.50 { return 3 }
        if r > 0.25 { return 2 }
        return 1
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var hit: (Date, Int64)?
        for c in cellFrames where c.rect.contains(p) {
            hit = (c.day, c.tokens)
            break
        }
        if hit?.0 != hoveredDay {
            hoveredDay = hit?.0
            hoveredTokens = hit?.1 ?? 0
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredDay != nil {
            hoveredDay = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        cellFrames.removeAll(keepingCapacity: true)
        tokenByDay = Dictionary(uniqueKeysWithValues: days.map { (dayKey($0.day), $0.tokens) })

        let cal = Calendar.current
        let today = startOfDay(Date())
        // 右端对齐本周（含今天），避免末列停在上周
        let thisSunday = startOfSundayWeek(today)
        guard let gridStart = cal.date(byAdding: .day, value: -7 * (weekCount - 1), to: thisSunday) else { return }

        let visibleToks = days.compactMap { d -> Int64? in
            guard d.day >= gridStart, d.day <= today else { return nil }
            return d.tokens
        }
        let maxTok = max(visibleToks.max() ?? 0, 1)

        let leftPad: CGFloat = 28
        let topPad: CGFloat = 16
        let pad: CGFloat = 10
        let gap: CGFloat = 2
        let availW = bounds.width - leftPad - pad
        let pitch = availW / CGFloat(weekCount)
        let cell = max(pitch - gap, 2)
        let font = NSFont.systemFont(ofSize: 9)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]

        let mf = DateFormatter(); mf.locale = Locale(identifier: "zh_CN"); mf.dateFormat = "M月"
        var lastMonth = -1
        for w in 0..<weekCount {
            guard let weekStart = cal.date(byAdding: .day, value: 7 * w, to: gridStart) else { continue }
            let m = cal.component(.month, from: weekStart)
            let dayNum = cal.component(.day, from: weekStart)
            if m != lastMonth, dayNum <= 7 {
                lastMonth = m
                let x = leftPad + CGFloat(w) * pitch
                (mf.string(from: weekStart) as NSString).draw(at: NSPoint(x: x, y: 1), withAttributes: attrs)
            }
        }

        // Sun=0 … Sat=6；标签放在一/三/五
        let rowLabels = ["", "一", "", "三", "", "五", ""]
        for (i, name) in rowLabels.enumerated() where !name.isEmpty {
            let y = topPad + CGFloat(i) * pitch + (pitch - 10) / 2
            (name as NSString).draw(at: NSPoint(x: 6, y: y), withAttributes: attrs)
        }

        for w in 0..<weekCount {
            for dow in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: w * 7 + dow, to: gridStart) else { continue }
                let sod = startOfDay(day)
                guard sod <= today else { continue }
                let tok = tokenByDay[dayKey(sod)] ?? 0
                let x = leftPad + CGFloat(w) * pitch + (pitch - cell) / 2
                let y = topPad + CGFloat(dow) * pitch + (pitch - cell) / 2
                let rect = NSRect(x: x, y: y, width: cell, height: cell)
                cellFrames.append((rect, sod, tok))
                heatColor(level: level(for: tok, maxTok: maxTok)).setFill()
                let corner = min(cell * 0.22, 2.5)
                let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
                path.fill()
                let isHover = hoveredDay.map { cal.isDate($0, inSameDayAs: sod) } ?? false
                let isToday = cal.isDate(sod, inSameDayAs: today)
                if isHover || isToday {
                    NSColor.labelColor.withAlphaComponent(isHover ? 0.75 : 0.45).setStroke()
                    path.lineWidth = isHover ? 1.5 : 1
                    path.stroke()
                }
            }
        }

        let legendY = topPad + 7 * pitch + 6
        ("少" as NSString).draw(at: NSPoint(x: leftPad, y: legendY), withAttributes: attrs)
        var lx = leftPad + 16
        for lv in 0...4 {
            heatColor(level: lv).setFill()
            NSBezierPath(roundedRect: NSRect(x: lx, y: legendY + 1, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            lx += 11
        }
        ("多" as NSString).draw(at: NSPoint(x: lx + 2, y: legendY), withAttributes: attrs)

        if let hd = hoveredDay {
            drawTooltip(day: hd, tokens: hoveredTokens, gridTop: topPad, gridHeight: 7 * pitch)
        }
    }

    private func drawTooltip(day: Date, tokens: Int64, gridTop: CGFloat, gridHeight: CGFloat) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE"
        let title = "\(fmtTokens(tokens)) tokens"
        let subtitle = df.string(from: day)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor]
        let tw = max((title as NSString).size(withAttributes: titleAttrs).width,
                     (subtitle as NSString).size(withAttributes: subAttrs).width) + 16
        let th: CGFloat = 40
        var anchor = CGPoint(x: bounds.midX, y: gridTop + gridHeight / 2)
        if let f = cellFrames.first(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) {
            anchor = CGPoint(x: f.rect.midX, y: f.rect.minY)
        }
        let ox = min(max(anchor.x - tw / 2, 8), bounds.width - tw - 8)
        var oy = anchor.y - th - 6
        if oy < gridTop { oy = anchor.y + 14 }
        if oy + th > bounds.height - 4 { oy = max(gridTop, bounds.height - th - 4) }

        let tip = NSRect(x: ox, y: oy, width: tw, height: th)
        let bg = NSBezierPath(roundedRect: tip, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        (title as NSString).draw(at: NSPoint(x: ox + 8, y: oy + 6), withAttributes: titleAttrs)
        (subtitle as NSString).draw(at: NSPoint(x: ox + 8, y: oy + 22), withAttributes: subAttrs)
    }

    static func preferredSize(weeks: Int) -> NSSize {
        let width: CGFloat = 320
        let pitch = (width - 28 - 10) / CGFloat(weeks)
        let h: CGFloat = 16 + 7 * pitch + 22
        return NSSize(width: width, height: h)
    }
}

func makeHeatmapGridItem(days: [DayTokens]) -> NSMenuItem {
    let item = NSMenuItem()
    let size = HeatmapGridView.preferredSize(weeks: HEATMAP_WEEKS)
    let view = HeatmapGridView(frame: NSRect(origin: .zero, size: size))
    view.days = days
    view.weekCount = HEATMAP_WEEKS
    item.view = view
    return item
}

func dashboardURLForRecentRange(days: Int = 7) -> URL {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd"
    let to = startOfDay(Date())
    let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: to) ?? to
    return URL(string: "\(DASHBOARD_BASE)?from=\(df.string(from: from))&to=\(df.string(from: to))")!
}

func reopenStatusMenu(_ statusItem: NSStatusItem) {
    DispatchQueue.main.async {
        statusItem.button?.performClick(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var snapshot: Snapshot?
    var refreshTimer: Timer?
    var menuTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerLoginItemIfNeeded()
        rebuildTitle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        menuTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    func refresh() {
        Task { @MainActor in
            let snap = await refreshSnapshot()
            snapshot = snap
            rebuildTitle()
            rebuildMenu()
        }
    }

    func registerLoginItemIfNeeded() {
        guard #available(macOS 13.0, *) else { return }
        let sm = SMAppService.mainApp
        guard sm.status != .enabled, sm.status != .requiresApproval else { return }
        do { try sm.register() } catch {
            NSLog("SMAppService register failed: \(error)")
        }
    }

    func displayMode() -> String {
        let v = UserDefaults.standard.string(forKey: DISPLAY_KEY) ?? "cursorModels"
        return DISPLAY_MODES.contains(v) ? v : "cursorModels"
    }

    func titlePercent(_ snap: Snapshot) -> Double? {
        switch displayMode() {
        case "otherModels": return snap.otherModelsPercent
        default: return snap.cursorModelsPercent
        }
    }

    func rebuildTitle() {
        guard let button = statusItem.button else { return }
        button.image = iconImage
        button.imagePosition = .imageLeft
        guard let snap = snapshot else {
            button.attributedTitle = NSAttributedString(string: "…", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            return
        }
        if let err = snap.error {
            button.attributedTitle = NSAttributedString(string: "⚠", attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            button.toolTip = "Cursor 用量 — \(err)"
            return
        }
        if let pct = titlePercent(snap) {
            let color = colorFor(pct)
            button.attributedTitle = NSAttributedString(string: "\(fmtPct(pct))%", attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            let modeLabel = DISPLAY_LABELS[DISPLAY_MODES.firstIndex(of: displayMode()) ?? 0]
            button.toolTip = "Cursor 用量（\(modeLabel)）— 点击查看详情"
        } else {
            button.attributedTitle = NSAttributedString(string: "—", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        guard let snap = snapshot else {
            menu.addItem(NSMenuItem(title: "加载中…", action: nil, keyEquivalent: ""))
            statusItem.menu = menu
            return
        }

        let mem = (snap.membership ?? "—").capitalized
        let hdr = NSMenuItem()
        hdr.attributedTitle = NSAttributedString(string: "Cursor 用量 · \(mem)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        menu.addItem(hdr)
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        menu.addItem(NSMenuItem(title: "更新于 \(fmt.string(from: snap.updatedAt))", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        if let err = snap.error {
            if err == "no-auth" {
                menu.addItem(NSMenuItem(title: "未找到 Cursor 登录态（先在 IDE 登录）", action: nil, keyEquivalent: ""))
            } else {
                menu.addItem(NSMenuItem(title: "⚠ \(err)", action: nil, keyEquivalent: ""))
            }
        } else {
            // 计划池：与官网一致的两项
            let planTitle = NSMenuItem()
            planTitle.attributedTitle = NSAttributedString(string: "计划池（Included）", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            menu.addItem(planTitle)

            menu.addItem(makeRow(
                text: "Cursor Models  \(fmtPct(snap.cursorModelsPercent))%",
                pct: snap.cursorModelsPercent))
            menu.addItem(makeRow(
                text: "Other Models   \(fmtPct(snap.otherModelsPercent))%",
                pct: snap.otherModelsPercent))

            if let end = snap.cycleEnd {
                menu.addItem(NSMenuItem(title: "  周期重置 · \(fmtCountdown(end))后", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())

            // On-demand
            let odTitle = NSMenuItem()
            odTitle.attributedTitle = NSAttributedString(string: "按需用量（On-demand）", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            menu.addItem(odTitle)
            if snap.onDemandEnabled == true {
                let odUsed = fmtCents(snap.onDemandUsedCents)
                if let lim = snap.onDemandLimitCents {
                    let pct = lim > 0 ? ((snap.onDemandUsedCents ?? 0) / lim) * 100 : nil
                    menu.addItem(makeRow(text: "\(odUsed) / \(fmtCents(lim))", pct: pct))
                } else {
                    menu.addItem(NSMenuItem(title: "  已用 \(odUsed) · 无硬限额", action: nil, keyEquivalent: ""))
                }
            } else {
                menu.addItem(NSMenuItem(title: "  未开启", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())

            // 用量热力图：折叠/合计用菜单项（可点）；网格单独视图
            let expanded = UserDefaults.standard.object(forKey: HEATMAP_EXPANDED_KEY) as? Bool ?? true
            let summary = UserDefaults.standard.string(forKey: HEATMAP_SUMMARY_KEY) ?? "week"
            let today = startOfDay(Date())
            let weekTok = tokensInRange(days: snap.dailyTokens, from: startOfWeek(today), to: today)
            let monthTok = tokensInRange(days: snap.dailyTokens, from: startOfMonth(today), to: today)

            let heatToggle = NSMenuItem(
                title: expanded ? "▼  用量热力图" : "▶  用量热力图",
                action: #selector(toggleHeatmapExpand),
                keyEquivalent: "")
            heatToggle.target = self
            menu.addItem(heatToggle)

            let summaryTitle = summary == "month"
                ? "本月合计  \(fmtTokens(monthTok))   ↺ 切本周"
                : "本周合计  \(fmtTokens(weekTok))   ↺ 切本月"
            let summaryItem = NSMenuItem(
                title: summaryTitle,
                action: #selector(toggleHeatmapSummary),
                keyEquivalent: "")
            summaryItem.target = self
            menu.addItem(summaryItem)

            if expanded {
                menu.addItem(makeHeatmapGridItem(days: snap.dailyTokens))
            }
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let dash = NSMenuItem(title: "打开 Cursor Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        dash.target = self
        menu.addItem(dash)
        menu.addItem(.separator())

        let modeTitle = NSMenuItem()
        modeTitle.attributedTitle = NSAttributedString(string: "菜单栏显示", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        menu.addItem(modeTitle)
        for (i, m) in DISPLAY_MODES.enumerated() {
            let item = NSMenuItem(title: DISPLAY_LABELS[i], action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = (m == displayMode()) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func selectDisplay(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < DISPLAY_MODES.count else { return }
        UserDefaults.standard.set(DISPLAY_MODES[sender.tag], forKey: DISPLAY_KEY)
        rebuildTitle()
        rebuildMenu()
    }

    @objc func toggleHeatmapExpand() {
        let cur = UserDefaults.standard.object(forKey: HEATMAP_EXPANDED_KEY) as? Bool ?? true
        UserDefaults.standard.set(!cur, forKey: HEATMAP_EXPANDED_KEY)
        rebuildMenu()
        reopenStatusMenu(statusItem)
    }

    @objc func toggleHeatmapSummary() {
        let cur = UserDefaults.standard.string(forKey: HEATMAP_SUMMARY_KEY) ?? "week"
        UserDefaults.standard.set(cur == "week" ? "month" : "week", forKey: HEATMAP_SUMMARY_KEY)
        rebuildMenu()
        reopenStatusMenu(statusItem)
    }

    @objc func doRefresh() { refresh() }
    @objc func openDashboard() {
        NSWorkspace.shared.open(dashboardURLForRecentRange())
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

if CommandLine.arguments.contains("--unregister-login-item"), #available(macOS 13.0, *) {
    try? SMAppService.mainApp.unregister()
    print("unregistered, status=\(SMAppService.mainApp.status.rawValue)")
    exit(0)
}

app.run()
