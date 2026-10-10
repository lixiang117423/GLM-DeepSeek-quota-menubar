import Foundation

// MARK: - API service

struct ApiService {
    private static let glmBase = "https://open.bigmodel.cn"
    private static let deepseekApi = "https://api.deepseek.com"
    /// GO 订阅的额度接口;实测 /zen/v1/usage 与 api.opencode.ai 两个变体都是 404,
    /// 只有这一条带 /go 前缀的可用(2026-10-10 用真实 key 验过)。
    private static let openCodeApi = "https://opencode.ai/zen/go/v1"

    /// GET with an optional Bearer token; returns the parsed top-level JSON dictionary.
    /// 默认 10s;团队看板 force=1 上游慢时要 ~20s,单独放宽(见 fetchTeamUsage)。
    private static func apiGet(url: String, token: String?, timeout: TimeInterval = 10) -> [String: Any]? {
        guard let requestUrl = URL(string: url) else { return nil }
        var req = URLRequest(url: requestUrl, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        URLSession.shared.dataTask(with: req) { data, _, error in
            defer { semaphore.signal() }
            guard error == nil, let data else {
                print("[API] \(url) → \(error?.localizedDescription ?? "no data")", to: &stderr)
                return
            }
            do {
                result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                print("[API] \(url) → JSON decode error: \(error.localizedDescription)", to: &stderr)
            }
        }.resume()

        // 比 URLSession 超时多 2s,让 URLSession 先触发、走上面打日志的分支
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return result
    }

    /// GLM endpoints wrap payloads as { code, success, data }.
    private static func glmData(_ dict: [String: Any]?) -> [String: Any]? {
        guard let dict,
              (dict["code"] as? Int) == 200,
              (dict["success"] as? Bool) == true,
              let data = dict["data"] as? [String: Any] else {
            return nil
        }
        return data
    }

    /// GLM quota limits → the `data` object.
    static func fetchGLMQuota(token: String) -> [String: Any]? {
        let dict = apiGet(url: "\(glmBase)/api/monitor/usage/quota/limit", token: token)
        return glmData(dict)
    }

    /// GLM daily usage → the `data` object.
    static func fetchGLMDaily(token: String) -> [String: Any]? {
        let today = isoDateString()
        let url = "\(glmBase)/api/monitor/usage/model-usage?startTime=\(today)%2000:00:00&endTime=\(today)%2023:59:59"
        let dict = apiGet(url: url, token: token)
        return glmData(dict)
    }

    /// DeepSeek balance → the whole response dict if `is_available` is true.
    static func fetchDeepSeekBalance(token: String) -> [String: Any]? {
        guard let dict = apiGet(url: "\(deepseekApi)/user/balance", token: token),
              (dict["is_available"] as? Bool) == true else {
            return nil
        }
        return dict
    }

    /// OpenCode GO 额度 → `usage` 对象(rolling/weekly/monthly)。
    /// 与 GLM 不同,这个接口没有 {code,success,data} 包装,直接取顶层 usage。
    static func fetchOpenCodeUsage(token: String) -> [String: Any]? {
        guard let dict = apiGet(url: "\(openCodeApi)/usage", token: token) else { return nil }
        return dict["usage"] as? [String: Any]
    }

    /// 团队看板按 Key 聚合的用量(局域网明文 HTTP,只读、无需鉴权)。
    /// 口径见 TeamConfig.usageURL:force=1 拿实时数,与 web 端刷新按钮一致。
    /// 超时放宽到 30s:force=1 穿透看板缓存走上游实时查询,2026-10-08 实测稳定 18~21s,
    /// 用默认 10s 会被掐断,团队段整段消失。
    static func fetchTeamUsage() -> [String: Any]? {
        return apiGet(url: TeamConfig.usageURL, token: nil, timeout: 30)
    }

    /// force=1 超时后的降级路径:走看板 1 小时缓存(实测 ~50ms)。
    /// 宁可显示最多 1 小时旧的数据,也不要标题空着(与领导 web 端会有小幅出入,恢复即好)。
    static func fetchTeamUsageCached() -> [String: Any]? {
        return apiGet(url: TeamConfig.usageURLCached, token: nil)
    }

    private static func isoDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// TextOutputStream that writes to stderr, for debug logging.
struct StderrStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

var stderr = StderrStream()
