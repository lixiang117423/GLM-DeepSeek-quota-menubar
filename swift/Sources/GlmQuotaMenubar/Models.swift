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

// MARK: - App state models

struct ModelUsage {
    let name: String
    let tokens: Int
}

struct GLMState {
    var ok = false
    var q5h = 0.0        // remaining percentage
    var r5h = ""          // reset time string
    var qWeekly = 0.0     // remaining percentage (Pro plan only)
    var rWeekly = ""      // reset time string
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
            let ms = toDouble(lim["nextResetTime"])
            if ms > 0 {
                let date = Date(timeIntervalSince1970: ms / 1000.0)
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                formatter.timeZone = TimeZone.current
                rst = formatter.string(from: date)
            }
            switch type {
            case "TOKENS_LIMIT":
                // Pro plans return two TOKENS_LIMIT entries (5h + weekly).
                // Tell them apart by reset-window length, not the opaque `unit`
                // enum: a 5h window resets within a day, a weekly one in ~7 days.
                let nowMs = Date().timeIntervalSince1970 * 1000
                let spanHours = (ms - nowMs) / 1000.0 / 3600.0
                if spanHours >= 24 {
                    state.qWeekly = rp
                    state.rWeekly = rst
                } else {
                    state.q5h = rp
                    state.r5h = rst
                }
            case "TIME_LIMIT":
                state.qMcp = rp
                state.rMcp = rst
            default:
                break
            }
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
