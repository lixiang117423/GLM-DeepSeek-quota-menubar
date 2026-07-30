import AppKit

/// Global refresh interval in seconds (matching Python version's 2 minutes)
private let refreshInterval: TimeInterval = 120

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

    /// Timer fires every 2 min; skip 23:00–08:00
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
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.fetchWorker(seq: seq)
        }
    }

    private func fetchWorker(seq: Int) {
        let secrets = SecretsLoader.load()
        let glmToken = secrets["glm"]
        let dsToken = secrets["deepseek"]

        var glmNew = GLMState()
        var dsNew = DSState()
        var failed = false

        if let glmToken {
            let quota = ApiService.fetchGLMQuota(token: glmToken)
            let daily = ApiService.fetchGLMDaily(token: glmToken)
            if quota == nil {
                failed = true
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

        // Drop stale result if a newer fetch was triggered
        if seq != fetchSeq { return }

        DispatchQueue.main.async { [weak self] in
            self?.menuBarController.applyFetch(glm: glmNew, ds: dsNew, failed: failed)
        }
    }
}
