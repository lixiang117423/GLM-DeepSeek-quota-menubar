import Foundation

// MARK: - Coercion helpers
// GLM/DeepSeek return numbers and strings inconsistently across fields, so we
// coerce defensively rather than rely on strict Decodable mapping.

private func toDouble(_ v: Any?) -> Double {
    guard let v else { return 0 }
    if let n = v as? Double { return n }
    if let n = v as? Int { return Double(n) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) ?? 0 }
    return 0
}

private func toInt(_ v: Any?) -> Int {
    guard let v else { return 0 }
    if let n = v as? Int { return n }
    if let n = v as? Double { return Int(n) }
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) ?? 0 }
    return 0
}

// MARK: - Formatting helpers
// 定义在 Models 而非 MenuBarController:dsTitleSegment(标题栏文本,可单测)
// 也要用,而 make test 只编译 Models.swift + tests。

func icon(for pct: Double) -> String {
    if pct <= 10 { return "\u{1F534}" }   // red
    if pct <= 50 { return "\u{1F7E1}" }   // yellow
    return "\u{1F7E2}"                     // green
}

func fmtMoney(_ v: Double, decimals: Int = 0) -> String {
    if decimals <= 0 { return "\(Int(v))" }
    return String(format: "%.\(decimals)f", v)
}

// MARK: - App state models

struct ModelUsage {
    let name: String
    let tokens: Int
}

struct GLMState {
    var ok = false
    var q5h = 0.0        // remaining percentage
    var r5h = ""          // reset time string
    var reset5h: Date?    // 5h window reset instant (used to pause refresh when exhausted)
    var qWeekly = 0.0     // remaining percentage (Pro plan only)
    var rWeekly = ""      // reset time string
    var resetWeekly: Date?  // weekly window reset instant
    var qMcp = 0.0        // remaining percentage
    var rMcp = ""         // reset time string
    var tokens = 0
    var calls = 0
    var models: [ModelUsage] = []

    /// `quota` is the `data` object from the quota-limit endpoint;
    /// `daily` is the `data` object from the model-usage endpoint.
    static func fromApi(quota: [String: Any]?, daily: [String: Any]?) -> GLMState {
        var state = GLMState()
        guard let quota else { return state }
        state.ok = true
        let limits = quota["limits"] as? [[String: Any]] ?? []
        for lim in limits {
            let type = (lim["type"] as? String) ?? ""
            let rp = 100.0 - toDouble(lim["percentage"])
            var rst = ""
            var resetDate: Date? = nil
            let ms = toDouble(lim["nextResetTime"])
            if ms > 0 {
                let date = Date(timeIntervalSince1970: ms / 1000.0)
                resetDate = date
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                formatter.timeZone = TimeZone.current
                rst = formatter.string(from: date)
            }
            switch type {
            case "TOKENS_LIMIT":
                // GLM labels the window by `unit`: 3 = 5h, 6 = weekly (Pro).
                // Classify by `unit`, NOT by reset-time span — the weekly window
                // shrinks below 24h as it nears reset and would be mistaken for 5h.
                let unit = toInt(lim["unit"])
                if unit == 6 {
                    state.qWeekly = rp
                    state.rWeekly = rst
                    state.resetWeekly = resetDate
                } else {
                    state.q5h = rp
                    state.r5h = rst
                    state.reset5h = resetDate
                }
            case "TIME_LIMIT":
                state.qMcp = rp
                state.rMcp = rst
            default:
                break
            }
        }
        // weekly 是一周总额度上限:它耗尽时,5h 窗口即便 API 报有余量也实际不可用
        // (一周的消耗不能超过 weekly),把 5h 一并置零,避免 UI 误导。
        if !state.rWeekly.isEmpty, state.qWeekly <= 0 {
            state.q5h = 0
        }
        if let daily, let tu = daily["totalUsage"] as? [String: Any] {
            state.tokens = toInt(tu["totalTokensUsage"])
            state.calls = toInt(tu["totalModelCallCount"])
            let list = tu["modelSummaryList"] as? [[String: Any]] ?? []
            state.models = list.map {
                ModelUsage(
                    name: ($0["modelName"] as? String) ?? "?",
                    tokens: toInt($0["totalTokens"])
                )
            }
        }
        return state
    }

    /// 额度已耗尽且未到重置点 → 再拉 GLM 只会得到同样的 0%,跳过以省调用;
    /// weekly 优先(weekly 耗尽时 5h 也被置零)。只作用于 GLM 拉取,
    /// DS/团队数据照常刷新(2026-09 起 DeepSeek 是主用渠道,不能被 GLM 拖累)。
    static func shouldSkipGLMFetch(state: GLMState, now: Date = Date()) -> Bool {
        guard state.ok else { return false }
        if !state.rWeekly.isEmpty, state.qWeekly <= 0,
           let reset = state.resetWeekly, now < reset {
            return true
        }
        if state.q5h <= 0, let reset = state.reset5h, now < reset {
            return true
        }
        return false
    }
}

struct DSState {
    var ok = false
    var balance = 0.0
    var currency = "CNY"

    /// `data` is the whole DeepSeek balance response dict.
    static func fromApi(data: [String: Any]?) -> DSState {
        var state = DSState()
        guard let data else { return state }
        var total = 0.0
        var currency = "CNY"
        for info in data["balance_infos"] as? [[String: Any]] ?? [] {
            total += toDouble(info["total_balance"])
            currency = (info["currency"] as? String) ?? "CNY"
        }
        if total > 0 {
            state.ok = true
            state.balance = total
            state.currency = currency
        }
        return state
    }
}

// MARK: - 团队看板(DeepSeek)

/// 团队看板口径常量。改额度/看板地址时,deepseeq-token-money 的 my_usage.html、
/// my_usage.js 里的同名常量要一起改(三处目前没有共享文件)。
enum TeamConfig {
    static let dashboardURL = "http://10.33.44.42:8088"  // 领导维护的局域网看板
    /// days=45:days 参数在老版本看板上不生效(只回显),传 45 保证它生效后窗口也覆盖整月;
    /// force=1:穿透看板 1 小时缓存拿实时数,与领导 web 端刷新按钮的口径一致
    /// (2026-09-16 实测:缓存快照比实时数少 ¥6.8/日,顶栏与 web 端对不上)。
    static let usageURL = "\(dashboardURL)/api/usage?days=45&force=1"
    /// 不带 force 的缓存路径,force=1 超时(上游查询慢,2026-10-08 实测稳定 18~21s)时降级用
    static let usageURLCached = "\(dashboardURL)/api/usage?days=45"
    static let myName = "李详"                            // 按名字认领自己的条目,无需 API Key
    static let quota = 600.0                              // 公司每人每月额度(¥)
    static let dayShift = 0                               // 看板按自然日记账,无需校正;若再出现记到前一天的情况改回 1
    static let timezone = TimeZone(identifier: "Asia/Shanghai")!
}

/// 团队看板里「李详」那条的聚合结果:今日费用 + 本月已用/剩余。
/// 口径与 deepseeq-token-money/my_usage.js 一致。
struct TeamState {
    var ok = false
    var errorText = ""        // 解析失败的原因(网络失败由 AppDelegate 填)
    var displayCost = 0.0     // 显示为"今日"的费用;今天还没出数时为最近一天
    var displayDate = ""      // displayCost 对应的日期(已按 dayShift 平移,当前 0 = 看板原始日)
    var todayFound = false    // 平移后的序列里有没有"今天"
    var monthUsed = 0.0
    var quotaLeft = 0.0
    var asofText = ""         // 如 "数据截至 09-13(滞后 1 天)",空串=已到今天

    var nearLimit: Bool { TeamConfig.quota > 0 && monthUsed / TeamConfig.quota >= 0.8 }
    var leftPct: Double { TeamConfig.quota > 0 ? quotaLeft / TeamConfig.quota * 100 : 0 }

    /// `data` 是团队看板 /api/usage 的完整返回;按名字认领自己的条目。
    /// `now` 可注入:测试夹具的日期是写死的,用真实时钟「今天」会随天数漂移。
    static func fromApi(data: [String: Any]?, name: String, now: Date = Date()) -> TeamState {
        var state = TeamState()
        guard let data, let keyDaily = data["key_daily"] as? [String: Any] else {
            state.errorText = "看板返回里没有 key_daily"
            return state
        }
        guard let arr = keyDaily[name] as? [[String: Any]] else {
            state.errorText = "看板里没找到「\(name)」的条目"
            return state
        }
        // 源数据省略零用量的天,缺的天就是 ¥0,聚合计数不受影响
        let daily = arr.compactMap { entry -> (date: String, cost: Double)? in
            guard let date = entry["date"] as? String else { return nil }
            return (shiftDate(date, days: TeamConfig.dayShift), toDouble(entry["cost"]))
        }.sorted { $0.date < $1.date }
        guard !daily.isEmpty else {
            state.errorText = "「\(name)」的每日序列为空"
            return state
        }

        let today = isoDateString(now)
        let month = String(today.prefix(7))
        // 账户级 daily 连续含零用量天,末日即看板数据的覆盖终点。
        var dataEnd = ""
        if let accountDaily = data["daily"] as? [[String: Any]] {
            if let lastRaw = accountDaily.last?["date"] as? String {
                dataEnd = shiftDate(lastRaw, days: TeamConfig.dayShift)
            }
        }

        if let todayEntry = daily.first(where: { $0.date == today }) {
            state.todayFound = true
            state.displayCost = todayEntry.cost
            state.displayDate = todayEntry.date
        } else if !dataEnd.isEmpty, dataEnd >= today {
            // 个人序列省略零用量的天:看板已覆盖到今天而个人缺今天 → 判定今天 ¥0。
            // 2026-10-09 放宽:此前要求"全团队今天零用量"才敢判定(2026-09-16 担心个人
            // 序列滞后于账户级,实测落后 1 小时+),结果自己零消费、同事有消费的日子,
            // 标题退回显示最近一天的旧值(标题不带日期,看着像今天的数,当天实际踩过)。
            // 当天实测逐人数据与总额一分不差,滞后不常见,故放宽。
            // 残余风险:当天首次消费后、看板导出前,今日会短暂显示 ¥0 再跳为真实值。
            state.todayFound = true
            state.displayCost = 0
            state.displayDate = today
        } else {
            // 看板还没导出到今天,无法判定:显示最近一天,菜单里注明日期
            let last = daily[daily.count - 1]
            state.displayCost = last.cost
            state.displayDate = last.date
        }

        state.monthUsed = daily.filter { $0.date.hasPrefix(month) }.reduce(0) { $0 + $1.cost }
        state.quotaLeft = max(0, TeamConfig.quota - state.monthUsed)

        if !dataEnd.isEmpty {
            let lagDays = daysBetween(dataEnd, today)
            if lagDays > 0 {
                state.asofText = "数据截至 \(shortDate(dataEnd))(滞后 \(lagDays) 天)"
            }
        }

        state.ok = true
        return state
    }

    // ---- 日期工具 ----

    /// "今天"按看板口径(Asia/Shanghai)算,不随本机时区漂移
    private static func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TeamConfig.timezone
        return formatter.string(from: date)
    }

    /// 同 my_usage.js 的 shift_date:按 UTC 整日平移,不受本地时区/夏令时干扰
    private static func shiftDate(_ date: String, days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let d = formatter.date(from: date) else { return date }
        return formatter.string(from: d.addingTimeInterval(Double(days) * 86400))
    }

    private static func daysBetween(_ from: String, _ to: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let f = formatter.date(from: from), let t = formatter.date(from: to) else { return 0 }
        return Int(t.timeIntervalSince(f) / 86400)
    }

    /// yyyy-MM-dd → MM-dd
    static func shortDate(_ date: String) -> String {
        return date.count >= 10 ? String(date.suffix(5)) : date
    }
}

// MARK: - 标题栏文本

/// 标题栏 DeepSeek 段:showTeam=true 用团队口径(今日费用+本月余额),
/// false 只显示个人余额(DeepSeek API 没有每日用量接口,花费拿不到)。
/// 返回 nil 表示整段省略——所选口径没拉到数据时不回落到另一口径,
/// 免得用户以为切过去了、显示的其实还是旧口径。
/// showGLM=false 时标题没有 GLM 段,DS 用全称;并排时缩写省宽度。
func dsTitleSegment(team: TeamState?, ds: DSState, showTeam: Bool, showGLM: Bool) -> String? {
    let label = showGLM ? "DS" : "DeepSeek"
    if showTeam {
        guard let team, team.ok else { return nil }
        return "\(label)\(icon(for: team.leftPct))¥\(fmtMoney(team.displayCost, decimals: 1)) 余额¥\(fmtMoney(team.quotaLeft, decimals: 2))"
    }
    guard ds.ok else { return nil }
    return "\(label)\(icon(for: balanceIconPct(ds.balance)))¥\(fmtMoney(ds.balance, decimals: 2))"
}

/// 个人余额没有百分比额度,图标色按余额定档:<¥10 红、<¥50 黄,否则绿。
/// 返回喂给 icon(for:) 的伪百分比。
func balanceIconPct(_ balance: Double) -> Double {
    if balance < 10 { return 10 }
    if balance < 50 { return 50 }
    return 100
}
