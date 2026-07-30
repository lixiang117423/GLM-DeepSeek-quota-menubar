import Foundation

// MARK: - API service

struct ApiService {
    private static let glmBase = "https://open.bigmodel.cn"
    private static let deepseekApi = "https://api.deepseek.com"

    /// GET with a Bearer token; returns the parsed top-level JSON dictionary.
    private static func apiGet(url: String, token: String) -> [String: Any]? {
        guard let requestUrl = URL(string: url) else { return nil }
        var req = URLRequest(url: requestUrl, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

        _ = semaphore.wait(timeout: .now() + 10)
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
