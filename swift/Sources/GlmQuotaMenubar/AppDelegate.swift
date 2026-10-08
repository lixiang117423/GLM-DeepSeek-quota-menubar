import AppKit

/// Refresh interval in seconds;GLM/DS/团队看板统一 5 分钟。
/// 团队走 force=1 实时口径,频率已与看板维护者确认。
private let refreshInterval: TimeInterval = 300

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var timer: Timer?
    private var fetchSeq = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(refreshAction: { [weak self] _ in
            self?.doFetch()
        })
        doFetch()
        timer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.onTimer()
        }
    }

    /// 每 5 分钟一轮,统一拉 GLM/DS/团队;skip 23:00–08:00 (night, data doesn't move)。
    /// GLM 额度耗尽的暂停在 shouldFetchGLM 里处理,只停 GLM,DS/团队照常刷新。
    private func onTimer() {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 23 || hour < 8 { return }
        doFetch()
    }

    /// Dispatch a fetch. Uses a sequence number to discard stale results,
    /// matching the Python version's race guard.
    private func doFetch() {
        fetchSeq += 1
        let seq = fetchSeq
        // 主线程先取好开关状态,避免后台线程读 UI 状态
        let fetchGLM = menuBarController.shouldFetchGLM()
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.fetchWorker(seq: seq, fetchGLM: fetchGLM)
        }
    }

    private func fetchWorker(seq: Int, fetchGLM: Bool) {
        let secrets = SecretsLoader.load()
        let glmToken = secrets["glm"]
        let dsToken = secrets["deepseek"]

        var glmNew: GLMState?
        var glmFailed = false
        var dsNew = DSState()
        var teamNew: TeamState?
        var failed = false

        // GLM 开关关闭或额度耗尽未重置时跳过,glmNew 保持 nil → UI 保留旧值
        if fetchGLM, let glmToken {
            let quota = ApiService.fetchGLMQuota(token: glmToken)
            let daily = ApiService.fetchGLMDaily(token: glmToken)
            if quota == nil {
                failed = true
                glmFailed = true
                // 接口 200 + 业务错误码(如"当前用户不存在coding plan")在这里是静默的,
                // 补一行日志,否则 GLM 段消失后无从查起(2026-10-08 实际踩过)
                print("[GLM] 拉取失败:令牌过期、套餐不存在或网络错误", to: &stderr)
            } else {
                glmNew = GLMState.fromApi(quota: quota, daily: daily)
            }
        }

        if let dsToken {
            let balance = ApiService.fetchDeepSeekBalance(token: dsToken)
            if balance == nil {
                failed = true
            } else {
                dsNew = DSState.fromApi(data: balance)
            }
        }

        let team = fetchTeamState()
        logTeam(team)
        teamNew = team

        // Drop stale result if a newer fetch was triggered
        if seq != fetchSeq { return }

        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.applyFetch(glm: glmNew, ds: dsNew, team: teamNew, failed: failed, glmFailed: glmFailed)
        }
    }

    /// 拉团队看板并解析;force=1 超时(上游慢)时降级到看板缓存路径,
    /// 两条都不通才返回带 errorText 的状态,统一走 apply 渲染 ⚠️。
    private func fetchTeamState() -> TeamState {
        if let teamData = ApiService.fetchTeamUsage() {
            return TeamState.fromApi(data: teamData, name: TeamConfig.myName)
        }
        if let cached = ApiService.fetchTeamUsageCached() {
            print("[TEAM] force=1 超时,已降级到看板缓存(最多 1 小时旧)", to: &stderr)
            return TeamState.fromApi(data: cached, name: TeamConfig.myName)
        }
        var err = TeamState()
        err.errorText = "看板不可达(\(TeamConfig.dashboardURL))"
        return err
    }

    private func logTeam(_ t: TeamState) {
        if t.ok {
            print("[TEAM] 今日 ¥\(t.displayCost) · 本月已用 ¥\(t.monthUsed) 剩 ¥\(t.quotaLeft) · \(t.asofText.isEmpty ? "数据已到今天" : t.asofText)", to: &stderr)
        } else {
            print("[TEAM] 解析失败: \(t.errorText)", to: &stderr)
        }
    }
}
