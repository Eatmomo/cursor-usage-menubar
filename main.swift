// cursor-usage-menubar — macOS 菜单栏 Cursor 订阅用量监视器
// 数据源:
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents
//   GET  https://cursor.com/api/usage-summary  (on-demand 池)
// 鉴权: 本机 Cursor IDE 登录态 ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
//
// 注意: autoPercentUsed / apiPercentUsed 已是「百分点」数值（0.69 ≈ 官网 1%），不要再 ×100。
// 官网计划池两项 = Cursor (auto*) + API (api*/named*)。
import AppKit
import ServiceManagement
import SQLite3
import UniformTypeIdentifiers

let DASHBOARD_BASE = "https://cursor.com/dashboard"
let API2 = "https://api2.cursor.sh"
let USAGE_SUMMARY = "https://cursor.com/api/usage-summary"
let STATE_DB = NSString(string: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb").expandingTildeInPath
let DISPLAY_KEY = "displayMetric"
let HEATMAP_EXPANDED_KEY = "heatmapExpanded"
let HEATMAP_SUMMARY_KEY = "heatmapSummary" // week | month
let REFRESH_INTERVAL_KEY = "refreshInterval" // 1m | 5m | manual
let RECEIPT_SAVE_DIR_KEY = "receiptSaveDirectory"
/// 菜单栏可选显示：Cursor（auto*）/ API（api*/named*）
let DISPLAY_MODES = ["cursorModels", "otherModels"]
let DISPLAY_LABELS = ["Cursor", "API"]
let REFRESH_MODES = ["1m", "5m", "manual"]
let REFRESH_LABELS = ["1 分钟", "5 分钟", "手动"]
/// Codex 风格贡献图周数（菜单栏宽度折中；Codex 桌面为 53）
let HEATMAP_WEEKS = 26

/// 打开菜单时补刷的宽限（相对所选频率）；手动模式不自动补刷
let OPEN_REFRESH_GRACE: TimeInterval = 5
/// 全量对账间隔；其余时间只拉最近一段
let FULL_SYNC_INTERVAL: TimeInterval = 6 * 3600
/// 全量对账只重拉最近这么多天（覆盖本月小票）；首次或换账号时仍拉整个热力图窗口
let FULL_SYNC_RECONCILE_DAYS = 35
/// 增量窗口向前重叠，兜住延迟入库的事件
let INCREMENTAL_OVERLAP_MS: Double = 2 * 3600 * 1000
let EVENTS_PAGE_SIZE = 100
let FULL_SYNC_MAX_PAGES = 100
let INCREMENTAL_MAX_PAGES = 20

/// 自动刷新间隔：计划池 / 事件（手动模式返回 nil）
func refreshIntervals(for mode: String) -> (light: TimeInterval, events: TimeInterval)? {
    switch mode {
    case "1m": return (60, 300)
    case "5m": return (300, 900)
    default: return nil
    }
}
let EVENT_CACHE_URL: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("cursor-usage-menubar", isDirectory: true)
    return dir.appendingPathComponent("events-v1.json")
}()

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

struct DayTokens: Equatable {
    var day: Date   // 当天 00:00
    var tokens: Int64
    var events: Int
}

/// 单条用量事件，只保留热力图和小票用到的字段
struct UsageEvent: Codable, Hashable {
    var ts: Double          // ms
    var model: String
    var input: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite: Int64
}

struct EventCache: Codable {
    var userId: String
    var events: [UsageEvent]   // 按 ts 升序
    var syncedTo: Double       // 上次请求的起点时刻（ms）
    var lastFullSync: Date
}

/// 计划池 / On-demand 等轻量数据
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
}

/// 公开价（USD / 百万 tokens），对齐 cursor.com/docs/models-and-pricing
struct ModelRate {
    var inputPerM: Double
    var cacheWritePerM: Double
    var cacheReadPerM: Double
    var outputPerM: Double
    init(inputPerM: Double, cacheWritePerM: Double, cacheReadPerM: Double, outputPerM: Double) {
        self.inputPerM = inputPerM
        self.cacheWritePerM = cacheWritePerM
        self.cacheReadPerM = cacheReadPerM
        self.outputPerM = outputPerM
    }
    init(_ inputPerM: Double, _ cacheWritePerM: Double, _ cacheReadPerM: Double, _ outputPerM: Double) {
        self.init(inputPerM: inputPerM, cacheWritePerM: cacheWritePerM,
                  cacheReadPerM: cacheReadPerM, outputPerM: outputPerM)
    }
}

/// Auto / 无法匹配模型时按 Composer 2.5 估算（Cursor 公开价）
let FALLBACK_RATE = ModelRate(inputPerM: 0.5, cacheWritePerM: 0.5, cacheReadPerM: 0.2, outputPerM: 2.5)
let FALLBACK_RATE_LABEL = "Composer 2.5"

struct ReceiptLine {
    /// 展示名（已合并同名变体）
    var model: String
    var rateLabel: String
    var usedFallback: Bool
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheWriteTokens: Int64
    var eventCount: Int
    var usd: Double
    var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

enum ReceiptPeriod {
    case day, week, month

    var title: String {
        switch self {
        case .day: return "每日 AI 账单"
        case .week: return "本周 AI 账单"
        case .month: return "本月 AI 账单"
        }
    }

    var emptyMessage: String {
        switch self {
        case .day: return "今日暂无用量事件"
        case .week: return "本周暂无用量事件"
        case .month: return "本月暂无用量事件"
        }
    }

    var fileTag: String {
        switch self {
        case .day: return "daily"
        case .week: return "week"
        case .month: return "month"
        }
    }
}

/// 小票底部随机短句（本地缓存，出单时抽一条，重绘不变）
let RECEIPT_MOTTOS: [String] = [
    "Ship small, ship often.",
    "Make it work, then make it nice.",
    "Done is better than perfect.",
    "Leave the code better than you found it.",
    "Curiosity compounds.",
    "Build in public, learn in private.",
    "Slow is smooth, smooth is fast.",
    "One commit closer.",
    "Read the error twice.",
    "Delete more than you add.",
    "今日事，今日毕。",
    "先跑通，再跑快。",
    "少即是多。",
    "保持好奇。",
    "写给三个月后的自己。",
    "休息也是进度。",
    "问题比答案更珍贵。",
    "把复杂留给实现，把简单留给接口。",
]

func randomReceiptMotto() -> String {
    RECEIPT_MOTTOS.randomElement() ?? "Keep building."
}

struct UsageReceipt {
    var period: ReceiptPeriod
    var rangeStart: Date
    var rangeEnd: Date
    var printedAt: Date
    var lines: [ReceiptLine]
    var motto: String
    var day: Date { rangeEnd } // 兼容保存文件名
    var inputTokens: Int64 { lines.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int64 { lines.reduce(0) { $0 + $1.outputTokens } }
    var cacheReadTokens: Int64 { lines.reduce(0) { $0 + $1.cacheReadTokens } }
    var cacheWriteTokens: Int64 { lines.reduce(0) { $0 + $1.cacheWriteTokens } }
    var eventCount: Int { lines.reduce(0) { $0 + $1.eventCount } }
    var totalTokens: Int64 { lines.reduce(0) { $0 + $1.totalTokens } }
    var totalUSD: Double { lines.reduce(0) { $0 + $1.usd } }
    var cacheHitRate: Double {
        let den = Double(inputTokens + cacheReadTokens)
        guard den > 0 else { return 0 }
        return Double(cacheReadTokens) / den
    }

    var rangeCaption: String {
        switch period {
        case .day:
            return Fmt.ymd.string(from: rangeEnd)
        case .week, .month:
            return "\(Fmt.md.string(from: rangeStart)) – \(Fmt.md.string(from: rangeEnd))"
        }
    }
}

typealias DailyReceipt = UsageReceipt

/// DateFormatter 创建开销大，统一复用
enum Fmt {
    private static func zh(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = format
        return f
    }
    private static func posix(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = format
        return f
    }
    static let ymd = zh("yyyy年M月d日")
    static let md = zh("M月d日")
    static let month = zh("M月")
    static let ymdWeekday = zh("yyyy年M月d日 EEEE")
    static let ymdHM = zh("yyyy年M月d日 HH:mm")
    static let hms = posix("HH:mm:ss")
    static let fileDay = posix("yyyyMMdd")
    static let isoDay = posix("yyyy-MM-dd")
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

func parseISO(_ s: String) -> Date? {
    Fmt.isoFrac.date(from: s) ?? Fmt.iso.date(from: s)
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

struct Auth: Equatable {
    var token: String
    var userId: String
    var expiresAt: Date?
}

func loadAuth() -> Auth? {
    guard let token = readSQLiteValue(dbPath: STATE_DB, key: "cursorAuth/accessToken"), !token.isEmpty else { return nil }
    let payload = jwtPayload(token) ?? [:]
    var sub = (payload["sub"] as? String) ?? ""
    if sub.hasPrefix("auth0|") { sub = String(sub.dropFirst(6)) }
    guard !sub.isEmpty else { return nil }
    let exp = asDouble(payload["exp"]).map { Date(timeIntervalSince1970: $0) }
    return Auth(token: token, userId: sub, expiresAt: exp)
}

let CURSOR_BUNDLE_ID = "com.todesktop.230313mzl4w4u92"
let CURSOR_SETTINGS_DEEPLINK = "cursor://anysphere.cursor-deeplink/settings"

func cursorAppURL() -> URL? {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CURSOR_BUNDLE_ID) {
        return url
    }
    let paths = ["/Applications/Cursor.app",
                 NSString(string: "~/Applications/Cursor.app").expandingTildeInPath]
    for p in paths where FileManager.default.fileExists(atPath: p) {
        return URL(fileURLWithPath: p)
    }
    return nil
}

/// 唤起 Cursor IDE 登录：打开应用 → 点托盘 Log In（与 IDE 同源）→ 失败则打开设置页 Sign In
@discardableResult
func triggerCursorIDELogin() -> String {
    guard let appURL = cursorAppURL() else {
        return "未找到 Cursor.app"
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, _ in }

    // 等主进程起来后再点托盘；设置页作兜底
    DispatchQueue.global(qos: .userInitiated).async {
        Thread.sleep(forTimeInterval: 1.2)
        let trayOK = clickCursorTrayLogIn()
        if !trayOK, let settings = URL(string: CURSOR_SETTINGS_DEEPLINK) {
            DispatchQueue.main.async { NSWorkspace.shared.open(settings) }
        }
    }
    return "ok"
}

/// 点击 Cursor 菜单栏托盘里的 Log In（发送 vscode:trayLogIn，打开官网登录页）
func clickCursorTrayLogIn() -> Bool {
    let script = """
    tell application "Cursor" to activate
    delay 0.4
    tell application "System Events"
      if not (exists process "Cursor") then return "no-process"
      tell process "Cursor"
        set barCount to count of menu bars
        repeat with bi from 1 to barCount
          set mb to menu bar bi
          set itemCount to count of menu bar items of mb
          repeat with ii from itemCount to 1 by -1
            set mbi to menu bar item ii of mb
            set itemTitle to ""
            try
              set itemTitle to title of mbi
            end try
            if itemTitle is "" or itemTitle is missing value then
              try
                click mbi
                delay 0.12
                if exists menu item "Log In" of menu 1 of mbi then
                  click menu item "Log In" of menu 1 of mbi
                  return "ok"
                else if exists menu item "Log in" of menu 1 of mbi then
                  click menu item "Log in" of menu 1 of mbi
                  return "ok"
                end if
                key code 53
                delay 0.05
              end try
            end if
          end repeat
        end repeat
      end tell
    end tell
    return "not-found"
    """
    // NSAppleScript 只能在主线程用；这里在后台线程，改走 osascript 子进程
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return false }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return proc.terminationStatus == 0 && result == "ok"
}

/// 缓存 token，临近过期或遇到 401/403 才重读 state.vscdb
final class AuthCache: @unchecked Sendable {
    static let shared = AuthCache()
    private let lock = NSLock()
    private var cached: Auth?

    func get(forceReload: Bool = false) -> Auth? {
        lock.lock(); defer { lock.unlock() }
        // 即将过期时重读：Cursor IDE 可能已写入新 token
        if !forceReload, let c = cached, (c.expiresAt.map { $0.timeIntervalSinceNow > 120 } ?? true) {
            return c
        }
        cached = loadAuth()
        return cached
    }
}

func isAuthError(_ error: Error) -> Bool {
    let code = (error as NSError).code
    return (error as NSError).domain == "cursor-usage" && (code == 401 || code == 403)
}

/// 用缓存 token 执行请求；鉴权失败时重读一次 token 再试
func withAuth<T>(_ body: (Auth) async throws -> T) async throws -> T {
    guard let auth = AuthCache.shared.get() else { throw AuthMissing() }
    do {
        return try await body(auth)
    } catch where isAuthError(error) {
        guard let fresh = AuthCache.shared.get(forceReload: true) else { throw AuthMissing() }
        guard fresh.token != auth.token else { throw error }
        return try await body(fresh)
    }
}

struct AuthMissing: Error {}

let apiSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpShouldSetCookies = false
    c.httpCookieAcceptPolicy = .never
    c.timeoutIntervalForRequest = 20
    c.timeoutIntervalForResource = 60
    c.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: c)
}()

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
    let (data, resp) = try await apiSession.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        let msg = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
        throw NSError(domain: "cursor-usage", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "http-\(http.statusCode) \(msg)"])
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "cursor-usage", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad-json"])
    }
    return obj
}

/// 展示用官方名（对齐 cursor.com/docs/models-and-pricing）；API 常带 effort / Fast 后缀
func displayModelName(_ raw: String) -> String {
    modelInfo(raw).display
}

/// 未知型号：slug → 可读标题（保留版本号小数点）
func humanizeModelSlug(_ key: String) -> String {
    key.split(separator: "-").map { part -> String in
        let s = String(part)
        if s.first?.isNumber == true { return s }
        if s == "gpt" { return "GPT" }
        if s == "api" { return "API" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }.joined(separator: " ")
}

func fmtPct(_ p: Double?) -> String {
    guard let p else { return "—" }
    return String(format: "%.1f", p)
}

func fmtCents(_ cents: Double?) -> String {
    guard let c = cents else { return "—" }
    return String(format: "$%.2f", c / 100.0)
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

/// 热力图用固定公历 + 本地时区；weekday 仍是 1=周日 … 7=周六
let heatCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .autoupdatingCurrent
    cal.locale = Locale(identifier: "zh_CN")
    cal.firstWeekday = 1 // 周日为一周之首（贡献图列）
    return cal
}()

func startOfDay(_ d: Date) -> Date {
    heatCalendar.startOfDay(for: d)
}

/// 「本周」合计：周一为一周起点（与国内习惯一致；热力图列仍为周日首）
func startOfWeek(_ d: Date) -> Date {
    let day = startOfDay(d)
    let weekday = heatCalendar.component(.weekday, from: day) // 1=Sun … 7=Sat
    let daysFromMonday = (weekday + 5) % 7
    return heatCalendar.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
}

/// 事件时间戳 → 本地日历日（API 一般为 ms；偶发秒级则自动识别）
func eventDay(_ timestamp: Double) -> Date {
    let sec = timestamp > 1e12 ? timestamp / 1000.0 : timestamp
    return startOfDay(Date(timeIntervalSince1970: sec))
}

/// 稳定日键，避免 TimeInterval 字典对不齐
func dayKey(_ d: Date) -> Int {
    let c = heatCalendar.dateComponents([.year, .month, .day], from: d)
    return (c.year! * 10_000) + (c.month! * 100) + c.day!
}

func buildDailyTokens(from events: [UsageEvent]) -> [DayTokens] {
    var map: [Int: (Date, Int64, Int)] = [:]
    for e in events {
        let day = eventDay(e.ts)
        let key = dayKey(day)
        let tok = e.input + e.output + e.cacheRead + e.cacheWrite
        let cur = map[key] ?? (day, 0, 0)
        map[key] = (cur.0, cur.1 + tok, cur.2 + 1)
    }
    return map.keys.sorted().compactMap { k in
        guard let v = map[k] else { return nil }
        return DayTokens(day: v.0, tokens: v.1, events: v.2)
    }
}


func normalizeModelKey(_ raw: String) -> String {
    var s = raw.lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    if s.hasPrefix("cursor-") {
        s = String(s.dropFirst("cursor-".count))
    }
    // API 常用 5-5 / 3-1 表示版本号 → 5.5 / 3.1
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    s = VERSION_DASH_RE.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1.$2")
    return s
}

let VERSION_DASH_RE = try! NSRegularExpression(pattern: #"(\d)-(\d)"#)

/// 具体型号优先（含 Fast / 500k 变体）；第三列为官网展示名
let RATE_TABLE: [(String, ModelRate, String)] = [
        ("grok-4.7-500k-fast", ModelRate(6, 6, 1.5, 18), "Grok 4.7 500k (Fast)"),
        ("grok-4.7-500k", ModelRate(4, 4, 1, 12), "Grok 4.7 500k"),
        ("grok-4.7-fast", ModelRate(4, 4, 1, 12), "Grok 4.7 (Fast)"),
        ("grok-4.7", ModelRate(2, 2, 0.5, 6), "Grok 4.7"),
        ("grok-4.6-fast", ModelRate(4, 4, 1, 12), "Grok 4.6 (Fast)"),
        ("grok-4.6", ModelRate(2, 2, 0.5, 6), "Grok 4.6"),
        ("grok-4.5-fast", ModelRate(4, 4, 1, 18), "Grok 4.5 (Fast)"),
        ("grok-4.5", ModelRate(2, 2, 0.5, 6), "Grok 4.5"),
        ("composer-2.5-fast", ModelRate(3, 3, 0.5, 15), "Composer 2.5 (Fast)"),
        ("composer-2.5", ModelRate(0.5, 0.5, 0.2, 2.5), "Composer 2.5"),
        ("composer-2", ModelRate(0.5, 0.5, 0.2, 2.5), "Composer 2.5"),
        ("claude-fable-5.1", ModelRate(10, 12.5, 0.25, 50), "Claude Fable 5.1"),
        ("claude-opus-5.5", ModelRate(4, 5, 0.2, 20), "Claude Opus 5.5"),
        ("claude-opus-4", ModelRate(15, 18.75, 1.5, 75), "Claude Opus 4"),
        ("claude-sonnet-5", ModelRate(2, 2.5, 0.2, 10), "Claude Sonnet 5"),
        ("claude-4.5-sonnet", ModelRate(3, 3.75, 0.3, 15), "Claude Sonnet 4.5"),
        ("claude-sonnet-4.5", ModelRate(3, 3.75, 0.3, 15), "Claude Sonnet 4.5"),
        ("claude-sonnet-4", ModelRate(3, 3.75, 0.3, 15), "Claude Sonnet 4"),
        ("claude-4-sonnet", ModelRate(3, 3.75, 0.3, 15), "Claude Sonnet 4"),
        ("claude-3.5-sonnet", ModelRate(3, 3.75, 0.3, 15), "Claude 3.5 Sonnet"),
        ("gemini-3.1-pro", ModelRate(2, 2, 0.2, 12), "Gemini 3.1 Pro"),
        ("gemini-3.8-flash", ModelRate(0.75, 0.75, 0.075, 3.5), "Gemini 3.8 Flash"),
        ("gemini-2.5-pro", ModelRate(1.25, 1.25, 0.125, 10), "Gemini 2.5 Pro"),
        ("gemini-2.5-flash", ModelRate(0.3, 0.3, 0.03, 2.5), "Gemini 2.5 Flash"),
        ("gpt-5.6-luna", ModelRate(0.2, 0.25, 0.02, 1.2), "GPT-5.6 Luna"),
        ("gpt-5.6-sol", ModelRate(4, 5, 0.4, 20), "GPT-5.6 Sol"),
        ("gpt-5.6-terra", ModelRate(2, 2.5, 0.2, 12), "GPT-5.6 Terra"),
        ("gpt-5.4", ModelRate(2.5, 2.5, 0.25, 15), "GPT-5.4"),
        ("gpt-5", ModelRate(1.25, 1.25, 0.125, 10), "GPT-5"),
        ("o3", ModelRate(2, 2, 0.5, 8), "o3"),
        ("o4-mini", ModelRate(1.1, 1.1, 0.275, 4.4), "o4-mini"),
        ("muse-spark-1.3", ModelRate(1.25, 1.25, 0.15, 4.25), "Muse Spark 1.3"),
    ]

/// 未进价表的变体按家族归类；需全部包含才命中，展示名须在 RATE_TABLE 中
let MODEL_FAMILIES: [([String], String)] = [
    (["grok-4.7", "fast"], "Grok 4.7 (Fast)"),
    (["grok-4.7"], "Grok 4.7"),
    (["grok-4.6", "fast"], "Grok 4.6 (Fast)"),
    (["grok-4.6"], "Grok 4.6"),
    (["grok-4", "fast"], "Grok 4.5 (Fast)"),
    (["grok-4"], "Grok 4.5"),
    (["composer", "fast"], "Composer 2.5 (Fast)"),
    (["composer"], "Composer 2.5"),
    (["fable"], "Claude Fable 5.1"),
    (["opus"], "Claude Opus 5.5"),
    (["sonnet", "4.5"], "Claude Sonnet 4.5"),
    (["sonnet", "3.5"], "Claude 3.5 Sonnet"),
    (["sonnet-4"], "Claude Sonnet 4"),
    (["4-sonnet"], "Claude Sonnet 4"),
    (["sonnet"], "Claude Sonnet 5"),
    (["gemini", "flash"], "Gemini 3.8 Flash"),
    (["gemini"], "Gemini 3.1 Pro"),
    (["luna"], "GPT-5.6 Luna"),
    (["sol"], "GPT-5.6 Sol"),
    (["terra"], "GPT-5.6 Terra"),
    (["muse"], "Muse Spark 1.3"),
    (["gpt-5.4"], "GPT-5.4"),
    (["gpt-5"], "GPT-5"),
]

struct ModelInfo {
    var display: String
    var rate: ModelRate
    var rateLabel: String
    var fallback: Bool
}

/// 展示名与价格同一套匹配：价表 → 家族 → Composer 2.5 兜底
func modelInfo(_ raw: String) -> ModelInfo {
    let k = normalizeModelKey(raw)
    func fallback(_ display: String) -> ModelInfo {
        ModelInfo(display: display, rate: FALLBACK_RATE, rateLabel: FALLBACK_RATE_LABEL, fallback: true)
    }
    if k.isEmpty || k == "?" { return fallback(raw.isEmpty ? "?" : raw) }
    if k == "default" || k == "auto" || k.hasPrefix("auto-") || k.hasSuffix("-auto") || k == "grok-bot-default" {
        return fallback("Auto")
    }
    for (pat, rate, display) in RATE_TABLE where k == pat || k.hasPrefix(pat + "-") || k.contains(pat) {
        return ModelInfo(display: display, rate: rate, rateLabel: display, fallback: false)
    }
    for (parts, display) in MODEL_FAMILIES where parts.allSatisfy({ k.contains($0) }) {
        if let rate = RATE_TABLE.first(where: { $0.2 == display })?.1 {
            return ModelInfo(display: display, rate: rate, rateLabel: display, fallback: false)
        }
    }
    return fallback(humanizeModelSlug(k))
}

func estimateUSD(input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, rate: ModelRate) -> Double {
    let m = 1_000_000.0
    return Double(input) / m * rate.inputPerM
        + Double(cacheWrite) / m * rate.cacheWritePerM
        + Double(cacheRead) / m * rate.cacheReadPerM
        + Double(output) / m * rate.outputPerM
}

func buildUsageReceipt(
    from events: [UsageEvent],
    period: ReceiptPeriod,
    from start: Date,
    to end: Date,
    printedAt: Date
) -> UsageReceipt {
    let lo = startOfDay(start).timeIntervalSince1970 * 1000
    let hi = (heatCalendar.date(byAdding: .day, value: 1, to: startOfDay(end)) ?? end).timeIntervalSince1970 * 1000
    // 按展示名合并：同一模型的不同 effort 变体（-high / -medium）归为一行
    var map: [String: ReceiptLine] = [:]
    var infos: [String: ModelInfo] = [:]
    for ev in events where ev.ts >= lo && ev.ts < hi {
        let input = ev.input
        let output = ev.output
        let cacheRead = ev.cacheRead
        let cacheWrite = ev.cacheWrite
        let matched: ModelInfo
        if let r = infos[ev.model] {
            matched = r
        } else {
            matched = modelInfo(ev.model)
            infos[ev.model] = matched
        }
        let name = matched.display
        let usd = estimateUSD(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, rate: matched.rate)
        var cur = map[name] ?? ReceiptLine(
            model: name, rateLabel: matched.rateLabel, usedFallback: matched.fallback,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            eventCount: 0, usd: 0)
        cur.inputTokens += input
        cur.outputTokens += output
        cur.cacheReadTokens += cacheRead
        cur.cacheWriteTokens += cacheWrite
        cur.eventCount += 1
        cur.usd += usd
        if !matched.fallback {
            cur.rateLabel = matched.rateLabel
            cur.usedFallback = false
        }
        map[name] = cur
    }
    let lines = map.values.sorted {
        if $0.usd != $1.usd { return $0.usd > $1.usd }
        return $0.totalTokens > $1.totalTokens
    }
    return UsageReceipt(
        period: period,
        rangeStart: startOfDay(start),
        rangeEnd: startOfDay(end),
        printedAt: printedAt,
        lines: lines,
        motto: randomReceiptMotto())
}

func emptyReceipt(period: ReceiptPeriod) -> UsageReceipt {
    let today = startOfDay(Date())
    let start: Date
    switch period {
    case .day: start = today
    case .week: start = startOfWeek(today)
    case .month: start = startOfMonth(today)
    }
    return UsageReceipt(period: period, rangeStart: start, rangeEnd: today, printedAt: Date(),
                        lines: [], motto: randomReceiptMotto())
}

func makeReceipt(period: ReceiptPeriod, events: [UsageEvent]) -> UsageReceipt {
    let today = startOfDay(Date())
    let start: Date
    switch period {
    case .day: start = today
    case .week: start = startOfWeek(today)
    case .month: start = startOfMonth(today)
    }
    return buildUsageReceipt(from: events, period: period, from: start, to: today, printedAt: Date())
}

func fmtUSDAmount(_ v: Double) -> String {
    if v >= 100 { return String(format: "$%.0f", v) }
    if v >= 10 { return String(format: "$%.1f", v) }
    return String(format: "$%.2f", v)
}

/// 行内金额：US + 空格 + $金额
func fmtUSD(_ v: Double) -> String {
    "US \(fmtUSDAmount(v))"
}

/// Token 数：满 1 亿用「亿」，满 1 万用「万」
func fmtTokensCN(_ n: Int64) -> String {
    func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
    let v = Double(n)
    // 下限略低于 1 亿：否则「万」取整后会显示成 10000万
    if n >= 99_995_000 { return trimZeros(String(format: "%.2f", v / 100_000_000)) + "亿" }
    if n >= 10_000_000 { return String(format: "%.0f万", v / 10_000) }
    if n >= 10_000 { return trimZeros(String(format: "%.2f", v / 10_000)) + "万" }
    return "\(n)"
}

/// 直接从 NSDictionary 取字段，避免整页事件桥接成 Swift 字典
func parseUsageEvents(_ arr: [NSDictionary]) -> [UsageEvent] {
    var out: [UsageEvent] = []
    out.reserveCapacity(arr.count)
    for e in arr {
        guard var ts = asDouble(e["timestamp"]) else { continue }
        if ts < 1e12 { ts *= 1000 }
        let model = (e["model"] as? String) ?? (e["modelIntent"] as? String) ?? "?"
        let tu = e["tokenUsage"] as? NSDictionary
        out.append(UsageEvent(
            ts: ts, model: model,
            input: asInt64(tu?["inputTokens"]),
            output: asInt64(tu?["outputTokens"]),
            cacheRead: asInt64(tu?["cacheReadTokens"]),
            cacheWrite: asInt64(tu?["cacheWriteTokens"])))
    }
    return out
}

/// 拉取 [startMs, endMs] 内的事件；首页拿到总数后其余页并发请求
func fetchEventRange(auth: Auth, startMs: Double, endMs: Double, maxPages: Int) async throws -> (events: [UsageEvent], complete: Bool) {
    @Sendable func page(_ p: Int) async throws -> (events: [UsageEvent], total: Int) {
        let resp = try await httpJSON(
            url: "\(API2)/aiserver.v1.DashboardService/GetFilteredUsageEvents",
            method: "POST", token: auth.token, userId: auth.userId,
            body: ["startDate": Int64(startMs), "endDate": Int64(endMs), "page": p, "pageSize": EVENTS_PAGE_SIZE])
        let arr = resp["usageEventsDisplay"] as? [NSDictionary] ?? []
        let total = asDouble(resp["totalUsageEventsCount"]).map { Int($0) } ?? arr.count
        return (parseUsageEvents(arr), total)
    }

    let first = try await page(1)
    var all = first.events
    let pagesNeeded = first.events.isEmpty ? 1 : Int((Double(first.total) / Double(EVENTS_PAGE_SIZE)).rounded(.up))
    let lastPage = min(pagesNeeded, maxPages)
    if lastPage >= 2 {
        try await withThrowingTaskGroup(of: [UsageEvent].self) { group in
            let maxConcurrent = 4
            var next = 2
            while next <= lastPage && next < 2 + maxConcurrent {
                let p = next
                group.addTask { try await page(p).events }
                next += 1
            }
            while let batch = try await group.next() {
                all.append(contentsOf: batch)
                if next <= lastPage {
                    let p = next
                    group.addTask { try await page(p).events }
                    next += 1
                }
            }
        }
    }
    // 分页期间有新事件写入时，页边界可能出现重复
    var seen = Set<UsageEvent>()
    seen.reserveCapacity(all.count)
    all = all.filter { seen.insert($0).inserted }
    all.sort { $0.ts < $1.ts }
    return (all, pagesNeeded <= maxPages)
}

/// 热力图 + 本月小票需要的最早时刻
func eventWindowStartMs() -> Double {
    let days = Double(HEATMAP_WEEKS * 7 + 7)
    return Date().addingTimeInterval(-days * 86400).timeIntervalSince1970 * 1000
}

/// 有可用缓存时只拉最近一段并替换该时间窗；否则全量拉取
func syncEvents(cache: EventCache?, auth: Auth, forceFull: Bool) async throws -> EventCache {
    let nowMs = Date().timeIntervalSince1970 * 1000
    let windowStart = eventWindowStartMs()
    let endMs = nowMs + 5 * 60 * 1000

    if !forceFull, let c = cache, c.userId == auth.userId,
       Date().timeIntervalSince(c.lastFullSync) < FULL_SYNC_INTERVAL,
       nowMs - c.syncedTo < 3 * 86400 * 1000 {
        let incStart = max(c.syncedTo - INCREMENTAL_OVERLAP_MS, windowStart)
        let r = try await fetchEventRange(auth: auth, startMs: incStart, endMs: endMs, maxPages: INCREMENTAL_MAX_PAGES)
        if r.complete {
            var merged = c.events.filter { $0.ts >= windowStart && $0.ts < incStart }
            merged.append(contentsOf: r.events.lazy.filter { $0.ts >= incStart })
            merged.sort { $0.ts < $1.ts }
            return EventCache(userId: auth.userId, events: merged, syncedTo: nowMs, lastFullSync: c.lastFullSync)
        }
    }

    // 同账号已有缓存：只对账最近一段，更早的历史不会再变
    var keep: [UsageEvent] = []
    var fullStart = windowStart
    if let c = cache, c.userId == auth.userId, !c.events.isEmpty {
        let recent = nowMs - Double(FULL_SYNC_RECONCILE_DAYS) * 86400 * 1000
        fullStart = max(windowStart, min(recent, c.syncedTo - INCREMENTAL_OVERLAP_MS))
        keep = c.events.filter { $0.ts >= windowStart && $0.ts < fullStart }
    }
    let r = try await fetchEventRange(auth: auth, startMs: fullStart, endMs: endMs, maxPages: FULL_SYNC_MAX_PAGES)
    if !r.complete {
        NSLog("usage events truncated at \(FULL_SYNC_MAX_PAGES) pages from \(Int64(fullStart))")
    }
    keep.append(contentsOf: r.events.lazy.filter { $0.ts >= fullStart })
    keep.sort { $0.ts < $1.ts }
    return EventCache(userId: auth.userId, events: keep, syncedTo: nowMs, lastFullSync: Date())
}

func loadEventCache() -> EventCache? {
    guard let data = try? Data(contentsOf: EVENT_CACHE_URL) else { return nil }
    return try? JSONDecoder().decode(EventCache.self, from: data)
}

func saveEventCache(_ cache: EventCache) {
    let fm = FileManager.default
    try? fm.createDirectory(at: EVENT_CACHE_URL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? data.write(to: EVENT_CACHE_URL, options: .atomic)
}

enum LightResult {
    case ok(Snapshot)
    case noAuth
    /// 本地有 token 但服务端拒绝（重读后仍 401）
    case authExpired(token: String?)
    case failed(String)
}

func fetchLight() async -> LightResult {
    do {
        return .ok(try await withAuth { try await fetchSnapshot(auth: $0) })
    } catch is AuthMissing {
        return .noAuth
    } catch where (error as NSError).domain == "cursor-usage" && (error as NSError).code == 401 {
        return .authExpired(token: AuthCache.shared.get()?.token)
    } catch {
        return .failed(String(error.localizedDescription.prefix(140)))
    }
}

func fetchSnapshot(auth: Auth) async throws -> Snapshot {
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
            onDemandLimitCents: nil
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
        return snap
    }
}

/// 横向用量进度条
final class BarView: NSView {
    var pct: Double = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        let h = min(bounds.height, 6)
        let y = (bounds.height - h) / 2
        let track = NSRect(x: 0, y: y, width: bounds.width, height: h)
        let path = NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
        path.fill()
        let p = min(max(pct, 0), 100)
        guard p > 0 else { return }
        let fillW = max(h, track.width * CGFloat(p / 100))
        let fill = NSRect(x: track.minX, y: track.minY, width: fillW, height: h)
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2)
        barColor.setFill()
        fillPath.fill()
    }
}

/// 用量行：名称 | 进度条 | 百分比 | 勾选；点击切换菜单栏显示且不关菜单
final class UsageMetricRowView: NSView {
    static let height: CGFloat = 26
    private static let padX: CGFloat = 12
    private static let nameW: CGFloat = 52
    private static let pctW: CGFloat = 44
    private static let checkW: CGFloat = 14
    private static let gap: CGFloat = 8

    private let onSelect: () -> Void
    private let nameLabel: NSTextField
    private let bar: BarView
    private let pctLabel: NSTextField
    private let check: NSImageView
    private let highlight = NSVisualEffectView()
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            highlight.isHidden = !hovering
            let c: NSColor = hovering ? .selectedMenuItemTextColor : .labelColor
            nameLabel.textColor = c
            pctLabel.textColor = c
            check.contentTintColor = c
        }
    }

    var selected: Bool {
        didSet {
            guard selected != oldValue else { return }
            check.isHidden = !selected
        }
    }

    init(name: String, pct: Double?, selected: Bool, width: CGFloat = HeatmapGridView.width, onSelect: @escaping () -> Void) {
        self.selected = selected
        self.onSelect = onSelect
        self.nameLabel = NSTextField(labelWithString: name)
        self.bar = BarView()
        self.pctLabel = NSTextField(labelWithString: "\(fmtPct(pct))%")
        self.check = NSImageView()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))

        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.blendingMode = .behindWindow
        highlight.frame = bounds.insetBy(dx: 0, dy: 1)
        highlight.autoresizingMask = [.width, .height]
        highlight.maskImage = MenuActionRowView.roundedMask(radius: 5)
        highlight.isHidden = true
        addSubview(highlight)

        let midY = (Self.height - 16) / 2
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .left
        nameLabel.frame = NSRect(x: Self.padX, y: midY, width: Self.nameW, height: 16)
        addSubview(nameLabel)

        let barX = Self.padX + Self.nameW + Self.gap
        let rightFixed = Self.gap + Self.pctW + Self.gap + Self.checkW + Self.padX
        let barW = max(40, width - barX - rightFixed)
        bar.frame = NSRect(x: barX, y: (Self.height - 6) / 2, width: barW, height: 6)
        bar.autoresizingMask = [.width]
        bar.pct = pct ?? 0
        bar.barColor = pct.map { colorFor($0) } ?? .secondaryLabelColor
        addSubview(bar)

        pctLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pctLabel.textColor = .labelColor
        pctLabel.alignment = .right
        pctLabel.frame = NSRect(x: width - Self.padX - Self.checkW - Self.gap - Self.pctW,
                                y: midY, width: Self.pctW, height: 16)
        pctLabel.autoresizingMask = [.minXMargin]
        addSubview(pctLabel)

        let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.image = symbol
        check.contentTintColor = .labelColor
        check.imageScaling = .scaleProportionallyDown
        check.frame = NSRect(x: width - Self.padX - Self.checkW, y: midY, width: Self.checkW, height: 16)
        check.autoresizingMask = [.minXMargin]
        check.isHidden = !selected
        addSubview(check)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(pct: Double?) {
        pctLabel.stringValue = "\(fmtPct(pct))%"
        bar.pct = pct ?? 0
        bar.barColor = pct.map { colorFor($0) } ?? .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let midY = (Self.height - 16) / 2
        nameLabel.frame = NSRect(x: Self.padX, y: midY, width: Self.nameW, height: 16)
        let barX = Self.padX + Self.nameW + Self.gap
        let rightFixed = Self.gap + Self.pctW + Self.gap + Self.checkW + Self.padX
        bar.frame = NSRect(x: barX, y: (Self.height - 6) / 2, width: max(40, w - barX - rightFixed), height: 6)
        pctLabel.frame = NSRect(x: w - Self.padX - Self.checkW - Self.gap - Self.pctW,
                                y: midY, width: Self.pctW, height: 16)
        check.frame = NSRect(x: w - Self.padX - Self.checkW, y: midY, width: Self.checkW, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hovering = false }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect() }
    }
}

func makeUsageRow(name: String, pct: Double?, selected: Bool, onSelect: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem()
    item.view = UsageMetricRowView(name: name, pct: pct, selected: selected, onSelect: onSelect)
    return item
}

/// 视图型菜单行；外观对齐 macOS 26 原生菜单项（行高 24pt、13pt 字体）。
/// 自定义颜色的文字不要用 attributedTitle：菜单打开后重建时，动态颜色会按另一种外观解析。
/// onClick 为 nil 时是不可点的标题行；否则点击不关闭菜单。
final class MenuActionRowView: NSView {
    static let height: CGFloat = 24
    /// 与带勾选列的原生菜单项标题对齐
    static let textX: CGFloat = 23

    var title: String {
        didSet { if title != oldValue { label.stringValue = title } }
    }
    private let onClick: (() -> Void)?
    private let label: NSTextField
    private let textColor: NSColor
    private let highlight = NSVisualEffectView()
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            highlight.isHidden = !hovering
            label.textColor = hovering ? .selectedMenuItemTextColor : textColor
        }
    }

    /// wraps 为 true 时按内容换行并增高；标题会原地变化的行不要开，避免菜单高度跳动
    init(title: String, font: NSFont = NSFont.menuFont(ofSize: 0), textColor: NSColor = .labelColor,
         wraps: Bool = false, width: CGFloat = HeatmapGridView.width, onClick: (() -> Void)? = nil) {
        self.title = title
        self.onClick = onClick
        self.textColor = textColor
        let field = wraps ? NSTextField(wrappingLabelWithString: title) : NSTextField(labelWithString: title)
        field.font = font
        let textW = width - Self.textX - 10
        let textH: CGFloat
        if wraps {
            field.preferredMaxLayoutWidth = textW
            textH = ceil(field.sizeThatFits(NSSize(width: textW, height: .greatestFiniteMagnitude)).height)
        } else {
            field.sizeToFit()
            textH = field.frame.height
        }
        self.label = field
        let rowH = max(Self.height, textH + 8)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))

        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.blendingMode = .behindWindow
        highlight.frame = bounds.insetBy(dx: 0, dy: 1)
        highlight.autoresizingMask = [.width, .height]
        highlight.maskImage = Self.roundedMask(radius: 5)
        highlight.isHidden = true
        addSubview(highlight)

        label.textColor = textColor
        if !wraps { label.lineBreakMode = .byTruncatingTail }
        label.frame = NSRect(x: Self.textX, y: (rowH - textH) / 2, width: textW, height: textH)
        label.autoresizingMask = [.width]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func roundedMask(radius r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard onClick != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hovering = false }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

/// 本周 / 本月 Token 合计
func tokensInRange(days: [DayTokens], from start: Date, to end: Date) -> Int64 {
    let s = startOfDay(start).timeIntervalSince1970
    let e = startOfDay(end).timeIntervalSince1970
    return days.filter { $0.day.timeIntervalSince1970 >= s && $0.day.timeIntervalSince1970 <= e }
        .reduce(Int64(0)) { $0 + $1.tokens }
}

func startOfMonth(_ d: Date) -> Date {
    let cal = heatCalendar
    let c = cal.dateComponents([.year, .month], from: d)
    return cal.date(from: c).map(startOfDay) ?? startOfDay(d)
}

/// 周日为一周起点（Codex / GitHub 贡献图）
func startOfSundayWeek(_ d: Date) -> Date {
    let cal = heatCalendar
    let day = startOfDay(d)
    let weekday = cal.component(.weekday, from: day) // 1=Sun … 7=Sat
    return cal.date(byAdding: .day, value: -(weekday - 1), to: day) ?? day
}

/// Codex 风格绿阶贡献图（仅网格 + 悬停浮窗；折叠/合计用菜单项）
final class HeatmapGridView: NSView {
    static let width: CGFloat = 320
    private static let leftPad: CGFloat = 28
    private static let topPad: CGFloat = 16
    private static let rightPad: CGFloat = 10
    private static let gap: CGFloat = 2

    var days: [DayTokens] = [] {
        didSet {
            guard days != oldValue else { return }
            layoutDirty = true
            needsDisplay = true
        }
    }
    var weekCount: Int = HEATMAP_WEEKS {
        didSet { layoutDirty = true; needsDisplay = true }
    }

    private struct Cell {
        var rect: NSRect
        var day: Date
        var tokens: Int64
        var level: Int
    }

    /// 下标 = 周 * 7 + 星期；未来日期为 nil
    private var cells: [Cell?] = []
    private var monthLabels: [(text: String, at: NSPoint)] = []
    private var pitch: CGFloat = 0
    private var legendY: CGFloat = 0
    private var todayIndex: Int?
    private var layoutDirty = true
    private var layoutDayKey = 0
    private var layoutWidth: CGFloat = 0

    private var hoveredIndex: Int?
    private var tooltipRect: NSRect = .zero
    private var tooltipTitle = ""
    private var tooltipSubtitle = ""
    private var tracking: NSTrackingArea?

    private static func rgb(_ h: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat((h >> 16) & 0xFF) / 255,
                green: CGFloat((h >> 8) & 0xFF) / 255,
                blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
    private static let levelColors: [NSColor] = [rgb(0xEBEDF0), rgb(0x9BE9A8), rgb(0x40C463), rgb(0x30A14E), rgb(0x216E39)]
    private static let emptyDark = NSColor(calibratedWhite: 0.22, alpha: 1)
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor]
    private static let tipTitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
    private static let tipSubAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]

    private func heatColor(level: Int, dark: Bool) -> NSColor {
        if level == 0 && dark { return Self.emptyDark }
        return Self.levelColors[min(max(level, 0), 4)]
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 仅在数据、宽度或日期变化时重算格子
    private func ensureLayout() {
        let today = startOfDay(Date())
        let todayKey = dayKey(today)
        guard layoutDirty || todayKey != layoutDayKey || bounds.width != layoutWidth else { return }
        layoutDirty = false
        layoutDayKey = todayKey
        layoutWidth = bounds.width

        let cal = heatCalendar
        // 右端对齐本周（含今天），避免末列停在上周
        let thisSunday = startOfSundayWeek(today)
        let gridStart = cal.date(byAdding: .day, value: -7 * (weekCount - 1), to: thisSunday) ?? thisSunday

        var tokenByDay: [Int: Int64] = [:]
        var maxTok: Int64 = 1
        for d in days where d.day >= gridStart && d.day <= today {
            tokenByDay[dayKey(d.day), default: 0] += d.tokens
            maxTok = max(maxTok, d.tokens)
        }

        pitch = (bounds.width - Self.leftPad - Self.rightPad) / CGFloat(weekCount)
        let size = max(pitch - Self.gap, 2)
        legendY = Self.topPad + 7 * pitch + 6

        cells = []
        cells.reserveCapacity(weekCount * 7)
        todayIndex = nil
        for i in 0..<(weekCount * 7) {
            guard let raw = cal.date(byAdding: .day, value: i, to: gridStart) else { cells.append(nil); continue }
            let sod = startOfDay(raw)
            guard sod <= today else { cells.append(nil); continue }
            let key = dayKey(sod)
            let tok = tokenByDay[key] ?? 0
            let x = Self.leftPad + CGFloat(i / 7) * pitch + (pitch - size) / 2
            let y = Self.topPad + CGFloat(i % 7) * pitch + (pitch - size) / 2
            cells.append(Cell(rect: NSRect(x: x, y: y, width: size, height: size),
                              day: sod, tokens: tok, level: level(for: tok, maxTok: maxTok)))
            if key == todayKey { todayIndex = i }
        }

        monthLabels = []
        var lastMonth = -1
        for w in 0..<weekCount {
            guard let weekStart = cells[w * 7]?.day else { continue }
            let m = cal.component(.month, from: weekStart)
            if m != lastMonth, cal.component(.day, from: weekStart) <= 7 {
                lastMonth = m
                monthLabels.append((Fmt.month.string(from: weekStart), NSPoint(x: Self.leftPad + CGFloat(w) * pitch, y: 1)))
            }
        }

        if let i = hoveredIndex {
            if cells.indices.contains(i), cells[i] != nil {
                updateTooltip(for: i)
            } else {
                hoveredIndex = nil
            }
        }
    }

    /// 按格距（含间隙）命中，鼠标在格子之间移动时浮窗不会闪
    private func hitIndex(_ p: NSPoint) -> Int? {
        guard pitch > 0 else { return nil }
        let col = Int(floor((p.x - Self.leftPad) / pitch))
        let row = Int(floor((p.y - Self.topPad) / pitch))
        guard col >= 0, col < weekCount, row >= 0, row < 7 else { return nil }
        let i = col * 7 + row
        return cells.indices.contains(i) && cells[i] != nil ? i : nil
    }

    private func updateTooltip(for i: Int) {
        guard let c = cells[i] else { return }
        tooltipTitle = "\(fmtTokensCN(c.tokens)) tokens"
        tooltipSubtitle = Fmt.ymdWeekday.string(from: c.day)
        let tw = max((tooltipTitle as NSString).size(withAttributes: Self.tipTitleAttrs).width,
                     (tooltipSubtitle as NSString).size(withAttributes: Self.tipSubAttrs).width) + 16
        let th: CGFloat = 40
        let gridTop = Self.topPad
        let ox = min(max(c.rect.midX - tw / 2, 8), bounds.width - tw - 8)
        var oy = c.rect.minY - th - 6
        if oy < gridTop { oy = c.rect.minY + 14 }
        if oy + th > bounds.height - 4 { oy = max(gridTop, bounds.height - th - 4) }
        tooltipRect = NSRect(x: ox, y: oy, width: tw, height: th)
    }

    private func invalidateHover() {
        guard let i = hoveredIndex, let c = cells[i] else { return }
        setNeedsDisplay(c.rect.insetBy(dx: -2, dy: -2))
        setNeedsDisplay(tooltipRect.insetBy(dx: -2, dy: -2))
    }

    private func setHovered(_ i: Int?) {
        guard i != hoveredIndex else { return }
        invalidateHover()
        hoveredIndex = i
        if let i { updateTooltip(for: i) }
        invalidateHover()
    }

    override func mouseMoved(with event: NSEvent) {
        ensureLayout()
        setHovered(hitIndex(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureLayout()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let attrs = Self.labelAttrs

        if dirtyRect.minY < Self.topPad {
            for label in monthLabels {
                (label.text as NSString).draw(at: label.at, withAttributes: attrs)
            }
        }
        if dirtyRect.minX < Self.leftPad {
            // Sun=0 … Sat=6；标签放在一/三/五
            for (i, name) in ["", "一", "", "三", "", "五", ""].enumerated() where !name.isEmpty {
                let y = Self.topPad + CGFloat(i) * pitch + (pitch - 10) / 2
                (name as NSString).draw(at: NSPoint(x: 6, y: y), withAttributes: attrs)
            }
        }

        let corner = min(max(pitch - Self.gap, 2) * 0.22, 2.5)
        for (i, cell) in cells.enumerated() {
            guard let c = cell, c.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }
            heatColor(level: c.level, dark: dark).setFill()
            let path = NSBezierPath(roundedRect: c.rect, xRadius: corner, yRadius: corner)
            path.fill()
            let isHover = i == hoveredIndex
            if isHover || i == todayIndex {
                NSColor.labelColor.withAlphaComponent(isHover ? 0.75 : 0.45).setStroke()
                path.lineWidth = isHover ? 1.5 : 1
                path.stroke()
            }
        }

        if dirtyRect.maxY > legendY {
            let lx0 = Self.leftPad
            ("少" as NSString).draw(at: NSPoint(x: lx0, y: legendY), withAttributes: attrs)
            var lx = lx0 + 16
            for lv in 0...4 {
                heatColor(level: lv, dark: dark).setFill()
                NSBezierPath(roundedRect: NSRect(x: lx, y: legendY + 1, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
                lx += 11
            }
            ("多" as NSString).draw(at: NSPoint(x: lx + 2, y: legendY), withAttributes: attrs)
        }

        if hoveredIndex != nil, tooltipRect.intersects(dirtyRect) {
            let bg = NSBezierPath(roundedRect: tooltipRect, xRadius: 7, yRadius: 7)
            NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
            bg.fill()
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            bg.lineWidth = 1
            bg.stroke()
            (tooltipTitle as NSString).draw(at: NSPoint(x: tooltipRect.minX + 8, y: tooltipRect.minY + 6), withAttributes: Self.tipTitleAttrs)
            (tooltipSubtitle as NSString).draw(at: NSPoint(x: tooltipRect.minX + 8, y: tooltipRect.minY + 22), withAttributes: Self.tipSubAttrs)
        }
    }

    static func preferredSize(weeks: Int) -> NSSize {
        let pitch = (width - leftPad - rightPad) / CGFloat(weeks)
        let h: CGFloat = topPad + 7 * pitch + 22
        return NSSize(width: width, height: h)
    }
}

func dashboardURLForRecentRange(days: Int = 7) -> URL {
    let to = startOfDay(Date())
    let from = heatCalendar.date(byAdding: .day, value: -(days - 1), to: to) ?? to
    return URL(string: "\(DASHBOARD_BASE)?from=\(Fmt.isoDay.string(from: from))&to=\(Fmt.isoDay.string(from: to))")!
}



// MARK: - 每日小票（热敏纸风格）

final class ReceiptPaperView: NSView {
    var receipt: UsageReceipt = emptyReceipt(period: .day) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    static let paperWidth: CGFloat = 320
    static let zigzag: CGFloat = 8

    static func contentHeight(for receipt: DailyReceipt) -> CGFloat {
        // 与 draw(_:) 布局保持一致
        var y: CGFloat = 16
        y += 22 + 14 + 14 + 18 + 14 // 标题区 + 虚线前
        y += 14 + 18 + 42 + 18 + 12 // 费用区 + 虚线
        if receipt.lines.isEmpty {
            y += 24
        } else {
            y += CGFloat(receipt.lines.count) * 36
        }
        y += 12 // 虚线后
        y += 18 * 7 // kv：总/输入/缓存读/缓存写/输出/命中率/会话
        y += 8 + 14 + 14 + 14 // 底注
        y += zigzag + 8
        return y
    }

    private func paperColor() -> NSColor {
        NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)
    }
    private func ink() -> NSColor {
        NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)
    }
    private func muted() -> NSColor {
        NSColor(calibratedRed: 0.45, green: 0.42, blue: 0.38, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 18
        let w = bounds.width
        let h = bounds.height
        let zig = Self.zigzag

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: w, y: 0))
        path.line(to: NSPoint(x: w, y: h - zig))
        var x: CGFloat = w
        var up = false
        while x > 0 {
            let nx = max(0, x - zig)
            path.line(to: NSPoint(x: nx, y: h - (up ? 0 : zig)))
            x = nx
            up.toggle()
        }
        path.close()
        paperColor().setFill()
        path.fill()

        NSColor.black.withAlphaComponent(0.06).setStroke()
        path.lineWidth = 1
        path.stroke()

        var y: CGFloat = 16
        let titleFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let monoSmall = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let regionFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold)

        let printedLine = Fmt.ymdHM.string(from: receipt.printedAt)

        drawCentered(receipt.period.title, at: y, font: titleFont, color: ink(), width: w)
        y += 22
        drawCentered(receipt.rangeCaption, at: y, font: monoSmall, color: muted(), width: w)
        y += 14
        drawCentered("出单 \(printedLine)", at: y, font: monoSmall, color: muted(), width: w)
        y += 14
        drawCentered(receipt.motto, at: y, font: monoSmall, color: muted(), width: w)
        y += 18
        drawDashed(y: y, pad: pad, width: w)
        y += 14

        drawCentered("API 总费用", at: y, font: monoSmall, color: muted(), width: w)
        y += 18
        drawCenteredUSD(receipt.totalUSD, at: y, width: w,
                        regionFont: regionFont, amountFont: amountFont,
                        regionColor: muted(), amountColor: ink())
        y += 42
        drawCentered("等值估算 · 非实际账单", at: y, font: monoSmall, color: muted(), width: w)
        y += 18
        drawDashed(y: y, pad: pad, width: w)
        y += 12

        if receipt.lines.isEmpty {
            (receipt.period.emptyMessage as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: [
                .font: mono, .foregroundColor: muted()])
            y += 24
        } else {
            let lineRegionFont = NSFont.systemFont(ofSize: 10, weight: .medium)
            let lineAmountFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            for line in receipt.lines {
                let left = line.model as NSString
                let leftAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: ink()]
                left.draw(at: NSPoint(x: pad, y: y), withAttributes: leftAttrs)
                let usdW = drawUSD(line.usd, at: NSPoint(x: 0, y: y),
                                   regionFont: lineRegionFont, amountFont: lineAmountFont,
                                   regionColor: muted(), amountColor: ink(),
                                   alignRightAt: w - pad)
                _ = usdW
                y += 16
                var sub = "\(fmtTokensCN(line.totalTokens)) tokens"
                if line.usedFallback {
                    sub += " · 按 \(line.rateLabel) 估价"
                }
                (sub as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: [
                    .font: monoSmall, .foregroundColor: muted()])
                y += 20
            }
        }

        drawDashed(y: y, pad: pad, width: w)
        y += 12

        func kv(_ k: String, _ v: String) {
            let ka: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: muted()]
            let va: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: ink()]
            (k as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: ka)
            let vs = v as NSString
            let vw = vs.size(withAttributes: va).width
            vs.draw(at: NSPoint(x: w - pad - vw, y: y), withAttributes: va)
            y += 18
        }
        // 总 Token = 输入 + 缓存读取 + 缓存写入 + 输出
        kv("总 Token 数", fmtTokensCN(receipt.totalTokens))
        kv("输入", fmtTokensCN(receipt.inputTokens))
        kv("缓存读取", fmtTokensCN(receipt.cacheReadTokens))
        kv("缓存写入", fmtTokensCN(receipt.cacheWriteTokens))
        kv("输出", fmtTokensCN(receipt.outputTokens))
        kv("缓存命中率", String(format: "%.0f%%", receipt.cacheHitRate * 100))
        kv("会话数", "\(receipt.eventCount)")

        y += 8
        drawDashed(y: y, pad: pad, width: w)
        y += 14
        drawCentered("cursor-usage-menubar", at: y, font: monoSmall, color: muted(), width: w)
        y += 14
        drawCentered("公开 API 价估算", at: y, font: monoSmall, color: muted(), width: w)
    }

    private func drawCentered(_ s: String, at y: CGFloat, font: NSFont, color: NSColor, width: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: (width - sz.width) / 2, y: y), withAttributes: attrs)
    }

    /// US（区域）与 $金额分字体绘制，居中
    private func drawCenteredUSD(_ v: Double, at y: CGFloat, width: CGFloat,
                                 regionFont: NSFont, amountFont: NSFont,
                                 regionColor: NSColor, amountColor: NSColor) {
        let region = "US" as NSString
        let gap: CGFloat = 6
        let amount = fmtUSDAmount(v) as NSString
        let ra: [NSAttributedString.Key: Any] = [.font: regionFont, .foregroundColor: regionColor]
        let aa: [NSAttributedString.Key: Any] = [.font: amountFont, .foregroundColor: amountColor]
        let rw = region.size(withAttributes: ra).width
        let aw = amount.size(withAttributes: aa).width
        let total = rw + gap + aw
        let x0 = (width - total) / 2
        let regionH = region.size(withAttributes: ra).height
        let amountH = amount.size(withAttributes: aa).height
        // 区域字相对金额垂直居中
        let regionY = y + (amountH - regionH) / 2
        region.draw(at: NSPoint(x: x0, y: regionY), withAttributes: ra)
        amount.draw(at: NSPoint(x: x0 + rw + gap, y: y), withAttributes: aa)
    }

    /// 右对齐绘制 US + $金额，返回总宽度
    @discardableResult
    private func drawUSD(_ v: Double, at point: NSPoint,
                         regionFont: NSFont, amountFont: NSFont,
                         regionColor: NSColor, amountColor: NSColor,
                         alignRightAt rightX: CGFloat) -> CGFloat {
        let region = "US" as NSString
        let gap: CGFloat = 3
        let amount = fmtUSDAmount(v) as NSString
        let ra: [NSAttributedString.Key: Any] = [.font: regionFont, .foregroundColor: regionColor]
        let aa: [NSAttributedString.Key: Any] = [.font: amountFont, .foregroundColor: amountColor]
        let rw = region.size(withAttributes: ra).width
        let aw = amount.size(withAttributes: aa).width
        let total = rw + gap + aw
        let x0 = rightX - total
        let regionH = region.size(withAttributes: ra).height
        let amountH = amount.size(withAttributes: aa).height
        let regionY = point.y + (amountH - regionH) / 2
        region.draw(at: NSPoint(x: x0, y: regionY), withAttributes: ra)
        amount.draw(at: NSPoint(x: x0 + rw + gap, y: point.y), withAttributes: aa)
        return total
    }

    private func drawDashed(y: CGFloat, pad: CGFloat, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pad, y: y))
        p.line(to: NSPoint(x: width - pad, y: y))
        p.lineWidth = 1
        let dashes: [CGFloat] = [3, 3]
        p.setLineDash(dashes, count: 2, phase: 0)
        NSColor(calibratedRed: 0.75, green: 0.72, blue: 0.68, alpha: 1).setStroke()
        p.stroke()
    }

    /// 导出倍率：聊天软件、网页通常忽略 dpi 按像素显示，2 倍图放大后会糊
    static let exportScale: CGFloat = 4

    func renderPNG() -> Data? {
        renderBitmap().representation(using: .png, properties: [:])
    }

    func renderBitmap(scale: CGFloat = exportScale) -> NSBitmapImageRep {
        let size = NSSize(width: Self.paperWidth, height: Self.contentHeight(for: receipt))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        // 位图上下文原点在左下；draw(_:) 按 isFlipped 布局，需翻转坐标并告知文字绘制方向
        let bitmapCtx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapCtx.cgContext, flipped: true)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        let savedFrame = frame
        frame = NSRect(origin: .zero, size: size)
        draw(NSRect(origin: .zero, size: size))
        frame = savedFrame
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}


/// 窗口内容根视图：y=0 在上方，方便「上出票口、下按钮」布局
final class FlippedRootView: NSView {
    override var isFlipped: Bool { true }
}

/// 裁剪容器同样翻转，纸张用负 y 藏在出票口上方再向下译出
final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

/// 热敏小票机出票口（上方壳体 + 深缝）
final class ReceiptSlotView: NSView {
    override var isFlipped: Bool { true }
    override var wantsLayer: Bool {
        get { true }
        set {}
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        // 外轮廓：略宽于纸面的打印机嘴
        let body = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: b.width, height: b.height),
                               xRadius: 7, yRadius: 7)

        // 深灰塑料壳体
        let g = NSGradient(colors: [
            NSColor(calibratedWhite: 0.28, alpha: 1),
            NSColor(calibratedWhite: 0.16, alpha: 1),
            NSColor(calibratedWhite: 0.10, alpha: 1),
        ])!
        g.draw(in: body, angle: 90)

        // 上沿高光
        let hi = NSBezierPath()
        hi.move(to: NSPoint(x: 8, y: 2.5))
        hi.line(to: NSPoint(x: b.width - 8, y: 2.5))
        NSColor.white.withAlphaComponent(0.22).setStroke()
        hi.lineWidth = 1.2
        hi.stroke()

        // 两侧“耳朵”
        let earL = NSRect(x: 3, y: b.height * 0.22, width: 7, height: b.height * 0.55)
        let earR = NSRect(x: b.width - 10, y: b.height * 0.22, width: 7, height: b.height * 0.55)
        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: earL, xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: earR, xRadius: 2, yRadius: 2).fill()

        // 出纸缝：凹槽 + 内阴影
        let slitW = b.width - 28
        let slitH: CGFloat = 5.5
        let slit = NSRect(x: (b.width - slitW) / 2, y: b.height * 0.42, width: slitW, height: slitH)
        let slitPath = NSBezierPath(roundedRect: slit, xRadius: 2.2, yRadius: 2.2)
        NSColor.black.withAlphaComponent(0.85).setFill()
        slitPath.fill()
        // 缝内下沿一点纸色微光（像纸刚露出）
        let glow = NSRect(x: slit.minX + 4, y: slit.maxY - 1.6, width: slit.width - 8, height: 1.2)
        NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.90, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: glow, xRadius: 0.6, yRadius: 0.6).fill()

        // 下唇：压纸舌
        let lipY = slit.maxY + 2
        let lip = NSBezierPath(roundedRect: NSRect(x: slit.minX - 2, y: lipY, width: slit.width + 4, height: 3.5),
                               xRadius: 1.5, yRadius: 1.5)
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        lip.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        lip.lineWidth = 0.6
        lip.stroke()

        // 小指示灯
        let led = NSRect(x: b.width - 18, y: 5, width: 5, height: 5)
        NSColor.systemGreen.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: led).fill()

        // 外描边
        NSColor.black.withAlphaComponent(0.45).setStroke()
        body.lineWidth = 1
        body.stroke()
    }
}

/// 无边框 NSPanel 默认不能成为 key window，收不到 Esc
final class ReceiptPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

final class ReceiptWindowController: NSWindowController, NSWindowDelegate {
    private let paper = ReceiptPaperView(frame: .zero)
    private let slot = ReceiptSlotView(frame: .zero)
    private let clip = FlippedClipView(frame: .zero)
    private let btnHost = NSView(frame: .zero)
    private let statusPill = NSView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "正在打印小票…")
    private let skipBtn = NSButton(title: "跳过", target: nil, action: nil)
    private var receipt: DailyReceipt
    private var paperHeight: CGFloat = 0
    private var animating = false
    private var printWorkItem: DispatchWorkItem?

    private let sidePad: CGFloat = 20
    private let slotH: CGFloat = 28
    private let slotOverlap: CGFloat = 6 // 出票口压住纸顶，像纸从缝里出来
    private let btnAreaH: CGFloat = 52
    private let topPad: CGFloat = 8
    private let bottomPad: CGFloat = 10

    init(receipt: DailyReceipt) {
        self.receipt = receipt
        self.paperHeight = ReceiptPaperView.contentHeight(for: receipt)
        let winW = ReceiptPaperView.paperWidth + sidePad * 2
        // 上：出票口 → 纸面；下：按钮
        let winH = topPad + slotH + paperHeight + btnAreaH + bottomPad
        let win = ReceiptPanel(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.isFloatingPanel = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = FlippedRootView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        win.center()
        super.init(window: win)
        win.delegate = self
        win.onEscape = { [weak self] in
            guard let self else { return }
            if self.animating { self.skipPrint() } else { self.closeWindow() }
        }
        buildUI()
        parkPaperHidden()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var paperW: CGFloat { ReceiptPaperView.paperWidth }
    /// 纸面顶边略伸入出票口下唇
    private var clipTop: CGFloat { topPad + slotH - slotOverlap }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor

        let x = sidePad

        // 1) 出票口固定在窗口最上方
        slot.frame = NSRect(x: x - 6, y: topPad, width: paperW + 12, height: slotH)
        content.addSubview(slot)

        // 2) 纸面裁剪区在出票口下方，整页高度、无滚动
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.frame = NSRect(x: x, y: clipTop, width: paperW, height: paperHeight)
        content.addSubview(clip)

        paper.receipt = receipt
        paper.wantsLayer = true
        paper.layerContentsRedrawPolicy = .onSetNeedsDisplay
        clip.addSubview(paper)

        // 出票口盖在纸顶之上（再提一次 z）
        content.addSubview(slot)

        // 3) 按钮固定在窗口最下方
        btnHost.frame = NSRect(
            x: x,
            y: clipTop + paperHeight + 8,
            width: paperW,
            height: 40)
        btnHost.alphaValue = 0
        content.addSubview(btnHost)
        installButtons(in: btnHost, width: paperW)

        // 打印中状态条
        statusPill.wantsLayer = true
        statusPill.alphaValue = 0
        content.addSubview(statusPill)
        installStatusPill()

        window?.acceptsMouseMovedEvents = true
    }

    private func installStatusPill() {
        statusPill.wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 14
            glass.translatesAutoresizingMaskIntoConstraints = false
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = inner
            statusPill.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor),
                glass.topAnchor.constraint(equalTo: statusPill.topAnchor),
                glass.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor),
            ])
            placeStatusControls(in: inner)
        } else {
            let ve = NSVisualEffectView()
            ve.material = .hudWindow
            ve.blendingMode = .behindWindow
            ve.state = .active
            ve.wantsLayer = true
            ve.layer?.cornerRadius = 14
            ve.translatesAutoresizingMaskIntoConstraints = false
            statusPill.addSubview(ve)
            NSLayoutConstraint.activate([
                ve.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor),
                ve.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor),
                ve.topAnchor.constraint(equalTo: statusPill.topAnchor),
                ve.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor),
            ])
            placeStatusControls(in: ve)
        }
        layoutStatusPill()
    }

    private func placeStatusControls(in host: NSView) {
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        skipBtn.target = self
        skipBtn.action = #selector(skipPrint)
        skipBtn.bezelStyle = .rounded
        skipBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        skipBtn.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(statusLabel)
        host.addSubview(skipBtn)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            skipBtn.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 12),
            skipBtn.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            skipBtn.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
    }

    private func layoutStatusPill() {
        let w: CGFloat = 200
        let y = clipTop + min(paperHeight * 0.55, paperHeight - 48)
        statusPill.frame = NSRect(x: sidePad + (paperW - w) / 2, y: y, width: w, height: 32)
    }

    private func installButtons(in host: NSView, width: CGFloat) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        func makeBtn(_ title: String, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.isBordered = true
            b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            return b
        }
        for b in [makeBtn("拷贝", action: #selector(copyImage)),
                  makeBtn("保存", action: #selector(saveImage)),
                  makeBtn("关闭", action: #selector(closeWindow))] {
            stack.addArrangedSubview(b)
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.translatesAutoresizingMaskIntoConstraints = false
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = inner
            inner.addSubview(stack)
            host.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                glass.topAnchor.constraint(equalTo: host.topAnchor),
                glass.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: inner.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -6),
            ])
        } else {
            let ve = NSVisualEffectView()
            ve.material = .hudWindow
            ve.blendingMode = .behindWindow
            ve.state = .active
            ve.wantsLayer = true
            ve.layer?.cornerRadius = 18
            ve.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(ve)
            ve.addSubview(stack)
            NSLayoutConstraint.activate([
                ve.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                ve.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                ve.topAnchor.constraint(equalTo: host.topAnchor),
                ve.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: ve.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: ve.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: ve.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: ve.bottomAnchor, constant: -6),
            ])
        }
    }

    /// 纸完全藏在出票口上方
    private func parkPaperHidden() {
        paper.frame = NSRect(x: 0, y: -paperHeight, width: paperW, height: paperHeight)
    }

    private func setPaperOffset(_ y: CGFloat) {
        paper.frame = NSRect(x: 0, y: y, width: paperW, height: paperHeight)
    }

    /// 多段步进平移：进纸 → 短停 → 再进纸（像热敏机走纸）
    func playPrintAnimation() {
        guard !animating else { return }
        animating = true
        btnHost.alphaValue = 0
        parkPaperHidden()
        layoutStatusPill()
        statusPill.alphaValue = 1

        // 步长约一行字高；偶发稍长一步模拟走纸段
        let baseStep: CGFloat = 28
        var offsets: [CGFloat] = []
        var pos: CGFloat = -paperHeight
        var i = 0
        while pos < -0.5 {
            i += 1
            var step = baseStep
            // 每 4 步一次稍大走纸；每 7 步一次更长段
            if i % 7 == 0 { step = 52 }
            else if i % 4 == 0 { step = 38 }
            pos = min(0, pos + step)
            offsets.append(pos)
        }
        if offsets.last != 0 { offsets.append(0) }

        runPrintSteps(offsets, index: 0)
    }

    private func runPrintSteps(_ offsets: [CGFloat], index: Int) {
        guard animating else { return }
        if index >= offsets.count {
            finishPrint()
            return
        }
        let target = offsets[index]
        // 走纸短促线性；段间停顿像电机间歇
        let moveDur: TimeInterval = (index % 7 == 6) ? 0.14 : 0.075
        let pauseDur: TimeInterval = (index % 4 == 3) ? 0.11 : 0.045

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = moveDur
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            self.paper.animator().frame = NSRect(x: 0, y: target, width: self.paperW, height: self.paperHeight)
        }, completionHandler: { [weak self] in
            guard let self, self.animating else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.runPrintSteps(offsets, index: index + 1)
            }
            self.printWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pauseDur, execute: work)
        })
    }

    private func finishPrint() {
        printWorkItem?.cancel()
        printWorkItem = nil
        animating = false
        setPaperOffset(0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.statusPill.animator().alphaValue = 0
            self.btnHost.animator().alphaValue = 1
        }
    }

    @objc private func skipPrint() {
        printWorkItem?.cancel()
        printWorkItem = nil
        paper.layer?.removeAllAnimations()
        finishPrint()
    }

    func windowWillClose(_ notification: Notification) {
        printWorkItem?.cancel()
        if retainedReceiptWC === self { retainedReceiptWC = nil }
    }

    @objc private func copyImage() {
        let rep = paper.renderBitmap()
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.title = "保存小票"
        panel.nameFieldStringValue = "cursor-\(receipt.period.fileTag)-receipt-\(Fmt.fileDay.string(from: receipt.day)).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = UserDefaults.standard.url(forKey: RECEIPT_SAVE_DIR_KEY)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        // 小票窗口是 floating 层级，非模态面板会被它压住
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: RECEIPT_SAVE_DIR_KEY)
        do {
            guard let png = paper.renderPNG() else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func closeWindow() {
        printWorkItem?.cancel()
        window?.close()
    }
}

private var retainedReceiptWC: ReceiptWindowController?

func presentUsageReceipt(_ receipt: UsageReceipt) {
    retainedReceiptWC?.close()
    let wc = ReceiptWindowController(receipt: receipt)
    retainedReceiptWC = wc
    wc.showWindow(nil)
    wc.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        wc.playPrintAnimation()
    }
}

/// 事件同步 + 按日汇总 + 落盘，都在主线程之外完成
func performEventSync(cache: EventCache?, forceFull: Bool) async throws -> (EventCache, [DayTokens]) {
    let fresh = try await withAuth { try await syncEvents(cache: cache, auth: $0, forceFull: forceFull) }
    if fresh.events != cache?.events || fresh.lastFullSync != cache?.lastFullSync {
        saveEventCache(fresh)
    }
    return (fresh, buildDailyTokens(from: fresh.events))
}

/// 读取磁盘缓存；账号不一致则丢弃
func loadCachedEvents() async -> (EventCache, [DayTokens])? {
    guard let c = loadEventCache(), c.userId == AuthCache.shared.get()?.userId else { return nil }
    return (c, buildDailyTokens(from: c.events))
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// 最多等 seconds 秒；任务本身不会被取消
func waitAtMost(_ seconds: Double, for task: Task<Void, Never>) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let once = Once()
        Task { await task.value; if once.fire() { cont.resume() } }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.fire() { cont.resume() }
        }
    }
}

func isStale(_ date: Date?, _ maxAge: TimeInterval) -> Bool {
    guard let date else { return true }
    return Date().timeIntervalSince(date) >= maxAge
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    var snapshot: Snapshot?
    var lightUpdatedAt: Date?
    var lightError: String?
    var noAuth = false
    /// 服务端拒绝的旧 token；登录等待期间要等 state.vscdb 换成新 token 才算成功
    var expiredToken: String?
    var authExpired = false
    /// 正在等待用户在 Cursor IDE 完成登录
    var awaitingIDELogin = false

    var eventCache: EventCache?
    var dailyTokens: [DayTokens] = []
    var eventsUpdatedAt: Date?
    var eventsError: String?

    private var lightTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var countdownTimer: Timer?
    private var loginWatchTimer: Timer?
    private var loginWatchDeadline: Date?
    private weak var headerRow: MenuActionRowView?
    private weak var statusRow: MenuActionRowView?
    private weak var cursorUsageRow: UsageMetricRowView?
    private weak var apiUsageRow: UsageMetricRowView?
    private weak var heatToggleRow: MenuActionRowView?
    private weak var heatSummaryRow: MenuActionRowView?
    private weak var heatSummaryItem: NSMenuItem?
    private var menuIsOpen = false
    /// 上次整体构建菜单时的结构；结构不变时只原地改文字和数值
    private var builtMenuShape = ""
    private var loginProbeInFlight = false
    private var pauseReasons = Set<String>()
    private var titleKey = ""

    private lazy var heatmapView: HeatmapGridView = {
        let v = HeatmapGridView(frame: NSRect(origin: .zero, size: HeatmapGridView.preferredSize(weeks: HEATMAP_WEEKS)))
        v.weekCount = HEATMAP_WEEKS
        return v
    }()
    private lazy var heatmapItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = heatmapView
        return item
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.image = iconImage
            button.imagePosition = .imageLeft
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildTitle()
        observeSystemState()
        startTimer()

        refreshLight()
        Task { [weak self] in
            let cached = await loadCachedEvents()
            guard let self else { return }
            if self.eventCache == nil, let cached {
                self.eventCache = cached.0
                self.dailyTokens = cached.1
                self.menuDataChanged()
            }
            self.refreshEvents()
        }
    }

    // MARK: 调度

    private func refreshMode() -> String {
        let v = UserDefaults.standard.string(forKey: REFRESH_INTERVAL_KEY) ?? "1m"
        return REFRESH_MODES.contains(v) ? v : "1m"
    }

    private func refreshModeLabel(_ mode: String = "") -> String {
        let m = mode.isEmpty ? refreshMode() : mode
        return REFRESH_LABELS[REFRESH_MODES.firstIndex(of: m) ?? 0]
    }

    private func startTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard pauseReasons.isEmpty else { return }
        guard let iv = refreshIntervals(for: refreshMode()) else { return }
        // 按计划池间隔触发；到点再决定是否刷事件
        let t = Timer(timeInterval: iv.light, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        t.tolerance = min(15, iv.light * 0.1)
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    @objc private func timerFired() { tick() }

    private func tick() {
        guard let iv = refreshIntervals(for: refreshMode()) else { return }
        // 定时器已按 light 间隔对齐，到点刷新计划池
        refreshLight()
        if isStale(eventsUpdatedAt, iv.events) { refreshEvents() }
    }

    @discardableResult
    func refreshLight() -> Task<Void, Never> {
        if let t = lightTask { return t }
        let t = Task { [weak self] in
            let result = await fetchLight()
            guard let self else { return }
            switch result {
            case .ok(let s):
                self.snapshot = s
                self.lightUpdatedAt = s.updatedAt
                self.lightError = nil
                self.noAuth = false
                self.authExpired = false
                self.expiredToken = nil
                if self.awaitingIDELogin { self.stopLoginWatch(success: true) }
            case .noAuth:
                self.snapshot = nil
                self.lightError = nil
                self.noAuth = true
                self.authExpired = false
            case .authExpired(let token):
                self.lightError = nil
                self.noAuth = true
                self.authExpired = true
                self.expiredToken = token
            case .failed(let msg):
                self.lightError = msg
            }
            self.lightTask = nil
            self.rebuildTitle()
            self.menuDataChanged()
        }
        lightTask = t
        refreshStatusLine()
        return t
    }

    @discardableResult
    func refreshEvents(forceFull: Bool = false) -> Task<Void, Never> {
        if let t = eventsTask { return t }
        let cache = eventCache
        let t = Task { [weak self] in
            let result: Result<(EventCache, [DayTokens]), Error>
            do {
                result = .success(try await performEventSync(cache: cache, forceFull: forceFull))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            switch result {
            case .success(let (c, daily)):
                self.eventCache = c
                if daily != self.dailyTokens { self.dailyTokens = daily }
                self.eventsUpdatedAt = Date()
                self.eventsError = nil
            case .failure(let error):
                self.eventsError = error is AuthMissing ? nil : String(error.localizedDescription.prefix(140))
            }
            self.eventsTask = nil
            self.menuDataChanged()
        }
        eventsTask = t
        refreshStatusLine()
        return t
    }

    private func observeSystemState() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(sysWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(sysDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func sysWillSleep() { pause("sleep") }
    @objc private func sysDidWake() { resume("sleep") }
    @objc private func screensSlept() { pause("display") }
    @objc private func screensWoke() { resume("display") }
    @objc private func sessionResigned() { pause("session") }
    @objc private func sessionActivated() { resume("session") }
    @objc private func screenLocked() { pause("lock") }
    @objc private func screenUnlocked() { resume("lock") }

    private func pause(_ reason: String) {
        pauseReasons.insert(reason)
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func resume(_ reason: String) {
        pauseReasons.remove(reason)
        guard pauseReasons.isEmpty, tickTimer == nil else { return }
        startTimer()
        // 刚唤醒时网络可能还没就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pauseReasons.isEmpty else { return }
            self.tick()
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
        let text: String
        let color: NSColor
        let colorKey: String
        var tip: String?
        if noAuth {
            (text, color, colorKey) = ("⚠", .systemOrange, "warn")
            if awaitingIDELogin {
                tip = "Cursor 用量 — 等待 IDE 登录完成"
            } else if authExpired {
                tip = "Cursor 用量 — 登录已过期（打开菜单可重新登录）"
            } else {
                tip = "Cursor 用量 — 未找到登录态（打开菜单可登录）"
            }
        } else if let snap = snapshot, let pct = titlePercent(snap) {
            text = "\(fmtPct(pct))%"
            color = colorFor(pct)
            colorKey = pct >= 80 ? "red" : pct >= 60 ? "orange" : "green"
            let modeLabel = DISPLAY_LABELS[DISPLAY_MODES.firstIndex(of: displayMode()) ?? 0]
            tip = "Cursor 用量（\(modeLabel)）— 点击查看详情"
            if lightError != nil { tip! += "\n上次更新失败，显示的是旧数据" }
        } else if snapshot != nil {
            (text, color, colorKey) = ("—", .secondaryLabelColor, "dim")
        } else if let err = lightError {
            (text, color, colorKey) = ("⚠", .systemOrange, "warn")
            tip = "Cursor 用量 — \(err)"
        } else {
            (text, color, colorKey) = ("…", .secondaryLabelColor, "dim")
        }
        let key = "\(text)|\(colorKey)|\(tip ?? "")"
        guard key != titleKey else { return }
        titleKey = key
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        button.toolTip = tip
    }

    // MARK: 菜单（打开时才构建）

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        startCountdownTimer()
        // 打开菜单时按所选频率判断是否过期，避免 30 秒补刷盖过「5 分钟」设定
        if let iv = refreshIntervals(for: refreshMode()) {
            if isStale(lightUpdatedAt, max(iv.light - OPEN_REFRESH_GRACE, OPEN_REFRESH_GRACE)) {
                refreshLight()
            }
            if isStale(eventsUpdatedAt, max(iv.events - OPEN_REFRESH_GRACE, OPEN_REFRESH_GRACE)) {
                refreshEvents()
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// 菜单开着时尽量原地刷新（避免闪烁和高度跳动）；关着时等下次打开再构建
    private func menuDataChanged() {
        guard menuIsOpen else { return }
        if menuShape() == builtMenuShape {
            updateMenuInPlace()
        } else {
            populate(menu)
        }
    }

    /// 决定菜单有哪些行的状态；说明行会换行，文字变了也要重建
    private func menuShape() -> String {
        let eventsSection = !noAuth && (eventCache != nil || eventsError != nil)
        return [
            noAuth ? "noauth" : "auth",
            authExpired ? "expired" : "",
            awaitingIDELogin ? "await" : "",
            snapshot != nil ? "snap" : "",
            lightError ?? "",
            eventsSection ? "events" : "",
            eventCache == nil ? (eventsError ?? "") : "",
        ].joined(separator: "|")
    }

    private func updateMenuInPlace() {
        headerRow?.title = headerTitle()
        refreshStatusLine()
        if let snap = snapshot {
            cursorUsageRow?.update(pct: snap.cursorModelsPercent)
            apiUsageRow?.update(pct: snap.otherModelsPercent)
        }
        heatSummaryRow?.title = heatSummaryTitle()
        if heatmapItem.menu === menu { heatmapView.days = dailyTokens }
    }

    private func headerTitle() -> String {
        snapshot.map { "Cursor 用量 · \(($0.membership ?? "—").capitalized)" } ?? "Cursor 用量"
    }

    private func statusLineText() -> String {
        var s = lightUpdatedAt.map { "更新于 \(Fmt.hms.string(from: $0))" } ?? "尚未更新"
        if lightTask != nil || eventsTask != nil { s += " · 刷新中…" }
        if let end = snapshot?.cycleEnd {
            s += "  周期重置 · \(fmtCountdown(end))后"
        }
        return s
    }

    private func refreshStatusLine() {
        guard menuIsOpen, let row = statusRow else { return }
        row.title = statusLineText()
    }

    /// 不可点的说明行（替代原生禁用项，颜色跟随菜单实际外观）
    private func infoItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.view = MenuActionRowView(title: text, textColor: .secondaryLabelColor, wraps: true)
        return item
    }

    /// 菜单不展示邮箱、显示名等账号标识，避免截图/录屏泄漏隐私
    private func accountRowTitle() -> String {
        if noAuth {
            if awaitingIDELogin {
                return "等待登录…  请在浏览器完成"
            }
            if authExpired {
                return "登录已过期  ·  点击在 Cursor 中重新登录"
            }
            return "未登录  ·  点击在 Cursor 中登录"
        }
        return "账号  ·  已登录"
    }

    private func makeAccountRow() -> NSMenuItem {
        let title = accountRowTitle()
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if noAuth {
            let row = MenuActionRowView(title: title, textColor: .systemOrange) { [weak self] in
                self?.beginIDELoginFromMenu()
            }
            item.view = row
        } else {
            let row = MenuActionRowView(title: title, textColor: .secondaryLabelColor) { [weak self] in
                self?.openDashboard()
            }
            item.view = row
        }
        return item
    }

    private func beginIDELoginFromMenu() {
        menu.cancelTracking()
        let result = triggerCursorIDELogin()
        if result != "ok" {
            lightError = result
            menuDataChanged()
            rebuildTitle()
            return
        }
        startLoginWatch()
    }

    private func startLoginWatch() {
        awaitingIDELogin = true
        loginWatchDeadline = Date().addingTimeInterval(180)
        loginWatchTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, target: self, selector: #selector(loginWatchFired), userInfo: nil, repeats: true)
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        loginWatchTimer = t
        rebuildTitle()
        menuDataChanged()
        // 立刻探一次，避免已登录却仍显示等待
        loginWatchFired()
    }

    private func stopLoginWatch(success: Bool) {
        loginWatchTimer?.invalidate()
        loginWatchTimer = nil
        loginWatchDeadline = nil
        awaitingIDELogin = false
        if success {
            authExpired = false
            expiredToken = nil
        }
        rebuildTitle()
        menuDataChanged()
    }

    /// 在后台重读 state.vscdb；过期场景下 token 变了才算登录完成
    @objc private func loginWatchFired() {
        guard !loginProbeInFlight else { return }
        loginProbeInFlight = true
        let stale = expiredToken
        Task { [weak self] in
            let auth = await Task.detached { AuthCache.shared.get(forceReload: true) }.value
            guard let self else { return }
            self.loginProbeInFlight = false
            guard self.awaitingIDELogin else { return }
            if let auth, auth.token != stale {
                self.stopLoginWatch(success: true)
                self.refreshLight()
                self.refreshEvents(forceFull: true)
                return
            }
            if let deadline = self.loginWatchDeadline, Date() >= deadline {
                self.stopLoginWatch(success: false)
            }
        }
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let t = Timer(timeInterval: 1, target: self, selector: #selector(countdownFired), userInfo: nil, repeats: true)
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    @objc private func countdownFired() {
        refreshStatusLine()
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        cursorUsageRow = nil
        apiUsageRow = nil
        heatSummaryRow = nil
        builtMenuShape = menuShape()

        let title = headerTitle()
        let hdr = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let hdrRow = MenuActionRowView(title: title, font: .boldSystemFont(ofSize: 13))
        hdr.view = hdrRow
        headerRow = hdrRow
        menu.addItem(hdr)
        let statusText = statusLineText()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        let row = MenuActionRowView(title: statusText, font: .systemFont(ofSize: 12), textColor: .secondaryLabelColor)
        status.view = row
        statusRow = row
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(makeAccountRow())

        if noAuth {
            if awaitingIDELogin {
                menu.addItem(infoItem("已打开 Cursor，请在浏览器完成登录…"))
            }
            menu.addItem(.separator())
        } else if let snap = snapshot {
            if let err = lightError {
                menu.addItem(infoItem("⚠ 更新失败，以下为上次数据：\(err)"))
            }
            let mode = displayMode()
            let cursorItem = makeUsageRow(
                name: "Cursor",
                pct: snap.cursorModelsPercent,
                selected: mode == "cursorModels") { [weak self] in
                    self?.selectDisplayMode("cursorModels")
                }
            cursorUsageRow = cursorItem.view as? UsageMetricRowView
            menu.addItem(cursorItem)

            let apiItem = makeUsageRow(
                name: "API",
                pct: snap.otherModelsPercent,
                selected: mode == "otherModels") { [weak self] in
                    self?.selectDisplayMode("otherModels")
                }
            apiUsageRow = apiItem.view as? UsageMetricRowView
            menu.addItem(apiItem)
            menu.addItem(.separator())
        } else if let err = lightError {
            menu.addItem(infoItem("⚠ \(err)"))
            menu.addItem(.separator())
        } else {
            menu.addItem(infoItem("加载中…"))
            menu.addItem(.separator())
        }

        if !noAuth && (eventCache != nil || eventsError != nil) {
            if eventCache == nil, let err = eventsError {
                menu.addItem(infoItem("⚠ 用量事件加载失败：\(err)"))
            }
            // 用量热力图：折叠/合计行点击后原地更新，菜单保持打开；键盘回车仍走 action
            let expanded = heatmapExpanded
            let heatToggle = NSMenuItem(title: heatToggleTitle(expanded), action: #selector(toggleHeatmapExpand), keyEquivalent: "")
            heatToggle.target = self
            let toggleRow = MenuActionRowView(title: heatToggle.title) { [weak self] in self?.toggleHeatmapExpand() }
            heatToggle.view = toggleRow
            heatToggleRow = toggleRow
            menu.addItem(heatToggle)

            let summaryItem = NSMenuItem(title: heatSummaryTitle(), action: #selector(toggleHeatmapSummary), keyEquivalent: "")
            summaryItem.target = self
            let summaryRow = MenuActionRowView(title: summaryItem.title) { [weak self] in self?.toggleHeatmapSummary() }
            summaryItem.view = summaryRow
            heatSummaryRow = summaryRow
            heatSummaryItem = summaryItem
            menu.addItem(summaryItem)

            if expanded {
                heatmapView.days = dailyTokens
                menu.addItem(heatmapItem)
            }
            menu.addItem(.separator())
        }

        let receiptRoot = NSMenuItem(title: "打印小票", action: nil, keyEquivalent: "")
        let receiptSub = NSMenu()
        let dayItem = NSMenuItem(title: "今日用量", action: #selector(printDayReceipt), keyEquivalent: "")
        dayItem.target = self
        receiptSub.addItem(dayItem)
        let weekItem = NSMenuItem(title: "本周用量", action: #selector(printWeekReceipt), keyEquivalent: "")
        weekItem.target = self
        receiptSub.addItem(weekItem)
        let monthItem = NSMenuItem(title: "本月用量", action: #selector(printMonthReceipt), keyEquivalent: "")
        monthItem.target = self
        receiptSub.addItem(monthItem)
        receiptRoot.submenu = receiptSub
        menu.addItem(receiptRoot)
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(doRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let refreshRoot = NSMenuItem(title: "刷新频率：\(refreshModeLabel())", action: nil, keyEquivalent: "")
        let refreshSub = NSMenu()
        let currentRefresh = refreshMode()
        for (i, mode) in REFRESH_MODES.enumerated() {
            let item = NSMenuItem(title: REFRESH_LABELS[i], action: #selector(selectRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = mode == currentRefresh ? .on : .off
            refreshSub.addItem(item)
        }
        refreshRoot.submenu = refreshSub
        menu.addItem(refreshRoot)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func selectDisplayMode(_ mode: String) {
        guard DISPLAY_MODES.contains(mode), mode != displayMode() else { return }
        UserDefaults.standard.set(mode, forKey: DISPLAY_KEY)
        cursorUsageRow?.selected = mode == "cursorModels"
        apiUsageRow?.selected = mode == "otherModels"
        rebuildTitle()
    }

    @objc func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String,
              REFRESH_MODES.contains(mode),
              mode != refreshMode() else { return }
        UserDefaults.standard.set(mode, forKey: REFRESH_INTERVAL_KEY)
        // 切换频率只重设定时器，不立刻刷；到点或点「立即刷新」再拉
        startTimer()
    }

    private var heatmapExpanded: Bool {
        UserDefaults.standard.object(forKey: HEATMAP_EXPANDED_KEY) as? Bool ?? true
    }

    private func heatToggleTitle(_ expanded: Bool) -> String {
        expanded ? "▼  用量热力图" : "▶  用量热力图"
    }

    private func heatSummaryTitle() -> String {
        let today = startOfDay(Date())
        if UserDefaults.standard.string(forKey: HEATMAP_SUMMARY_KEY) == "month" {
            return "本月合计  \(fmtTokensCN(tokensInRange(days: dailyTokens, from: startOfMonth(today), to: today)))   ↺ 切本周"
        }
        return "本周合计  \(fmtTokensCN(tokensInRange(days: dailyTokens, from: startOfWeek(today), to: today)))   ↺ 切本月"
    }

    @objc func toggleHeatmapExpand() {
        let expanded = !heatmapExpanded
        UserDefaults.standard.set(expanded, forKey: HEATMAP_EXPANDED_KEY)
        guard menuIsOpen, let summaryItem = heatSummaryItem, summaryItem.menu === menu else { return }
        heatToggleRow?.title = heatToggleTitle(expanded)
        if expanded {
            guard heatmapItem.menu == nil else { return }
            heatmapView.days = dailyTokens
            menu.insertItem(heatmapItem, at: menu.index(of: summaryItem) + 1)
        } else if heatmapItem.menu === menu {
            menu.removeItem(heatmapItem)
        }
    }

    @objc func toggleHeatmapSummary() {
        let cur = UserDefaults.standard.string(forKey: HEATMAP_SUMMARY_KEY) ?? "week"
        UserDefaults.standard.set(cur == "week" ? "month" : "week", forKey: HEATMAP_SUMMARY_KEY)
        guard menuIsOpen else { return }
        heatSummaryRow?.title = heatSummaryTitle()
    }

    @objc func doRefresh() {
        refreshLight()
        refreshEvents()
    }
    @objc func printDayReceipt() { presentReceipt(period: .day) }
    @objc func printWeekReceipt() { presentReceipt(period: .week) }
    @objc func printMonthReceipt() { presentReceipt(period: .month) }

    /// 事件较旧时先补一次增量（最多等 2.5 秒），保证今天的小票是新的
    private func presentReceipt(period: ReceiptPeriod) {
        guard isStale(eventsUpdatedAt, 120) else {
            showReceipt(period: period)
            return
        }
        let t = refreshEvents()
        Task { [weak self] in
            await waitAtMost(2.5, for: t)
            self?.showReceipt(period: period)
        }
    }

    private func showReceipt(period: ReceiptPeriod) {
        let events = eventCache?.events ?? []
        let receipt = events.isEmpty ? emptyReceipt(period: period) : makeReceipt(period: period, events: events)
        presentUsageReceipt(receipt)
    }
    @objc func openDashboard() {
        NSWorkspace.shared.open(dashboardURLForRecentRange())
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// 自启只走 LaunchAgent；这个开关清理旧版本用 SMAppService 注册过的登录项
if CommandLine.arguments.contains("--unregister-login-item") {
    if #available(macOS 13.0, *) {
        try? SMAppService.mainApp.unregister()
        print("unregistered, status=\(SMAppService.mainApp.status.rawValue)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
