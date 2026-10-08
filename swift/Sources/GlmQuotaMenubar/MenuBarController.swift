import AppKit

// MARK: - Formatting helpers

private func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000.0) }
    if n >= 1_000 { return "\(n / 1_000)K" }
    return "\(n)"
}

// MARK: - Menu bar controller

class MenuBarController {
    private let statusItem: NSStatusItem
    private var secrets: [String: String] = [:]
    private var glmState = GLMState()
    private var dsState = DSState()
    private var teamState: TeamState?  // 团队看板数据;nil=还没拉过
    private var updatedAt: Date?
    private var fetchFailed = false
    /// GLM 展示开关,菜单里可切。2026-09 起主用 DeepSeek,后续可能弃用 GLM。
    private var showGLM: Bool
    /// 标题栏 DeepSeek 段的口径:团队(今日费用+剩余)或个人余额。默认团队。
    private var showDSTeam: Bool
    /// 本轮 GLM 拉取是否失败(接口 200 + 业务错误码也算)。失败时菜单里显示原因,
    /// 否则 GLM 段凭空消失,用户无从判断(2026-10-08 套餐不存在事故)。
    private var glmFailed = false

    init(refreshAction: @escaping (_ sender: Any?) -> Void) {
        self.refreshAction = refreshAction
        self.showGLM = UserDefaults.standard.object(forKey: "show_glm") as? Bool ?? true
        self.showDSTeam = UserDefaults.standard.object(forKey: "show_ds_team") as? Bool ?? true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI"
        reloadSecrets()
    }

    private let refreshAction: (_ sender: Any?) -> Void

    /// Re-read the secrets file (called on startup and on "Reload tokens")
    func reloadSecrets() {
        secrets = SecretsLoader.load()
        rebuildMenu()
    }

    /// Apply fetched data to the UI. `glm`/`team` 为 nil 表示本轮没拉
    /// (GLM 开关关闭或额度耗尽暂停),保留旧值。
    func applyFetch(glm: GLMState?, ds: DSState, team: TeamState?, failed: Bool, glmFailed: Bool) {
        if let glm { glmState = glm }
        dsState = ds
        if let team { teamState = team }
        fetchFailed = failed
        self.glmFailed = glmFailed
        updatedAt = Date()
        rebuildMenu()
    }

    /// 本轮是否该拉 GLM:开关关闭不拉;额度耗尽未重置时也暂停(只停 GLM,
    /// DS/团队照常刷新)。需在主线程调用(doFetch 里先取好再进后台队列)。
    func shouldFetchGLM() -> Bool {
        showGLM && !GLMState.shouldSkipGLMFetch(state: glmState)
    }

    /// footer 提示用:GLM 可见且额度耗尽暂停中;隐藏 GLM 时无需提示。
    private var glmPausedHint: Bool {
        showGLM && glmState.ok && GLMState.shouldSkipGLMFetch(state: glmState)
    }

    // MARK: - Menu rebuild

    private func rebuildMenu() {
        let menu = NSMenu()
        let hasGLM = secrets["glm"] != nil
        let hasDS = secrets["deepseek"] != nil

        if !hasGLM && !hasDS {
            statusItem.button?.title = "AI"
            menu.addItem(infoItem("⚠️ 未读取到 API token"))
            menu.addItem(infoItem("  请配置 \(SecretsLoader.secretsFilePath)"))
            addTeamSection(to: menu)  // 团队数据不依赖 token,没配 key 也能看
            addFooter(to: menu)
            statusItem.menu = menu
            return
        }

        // Title bar — GLM quota (5h, plus weekly when present) + DeepSeek balance.
        var parts: [String] = []
        if showGLM, glmState.ok {
            var part = "GLM\(icon(for: glmState.q5h))\(Int(glmState.q5h))%"
            if !glmState.rWeekly.isEmpty {
                part += " \(icon(for: glmState.qWeekly))\(Int(glmState.qWeekly))%"
            }
            parts.append(part)
        }
        // DS 段:团队(今日费用+剩余)或个人余额,菜单里可切;格式细节见 dsTitleSegment
        if let seg = dsTitleSegment(team: teamState, ds: dsState, showTeam: showDSTeam, showGLM: showGLM) {
            parts.append(seg)
        }
        statusItem.button?.title = parts.isEmpty ? "AI" : parts.joined(separator: " | ")

        // -- GLM section --
        if showGLM {
            if glmState.ok {
                let i5 = icon(for: glmState.q5h)
                let u5 = 100.0 - glmState.q5h
                let im = icon(for: glmState.qMcp)
                let um = 100.0 - glmState.qMcp

                menu.addItem(infoItem("📡 GLM"))

                menu.addItem(infoItem("  \(i5) 5h: used \(Int(u5))%  |  left \(Int(glmState.q5h))%"))
                if !glmState.r5h.isEmpty {
                    menu.addItem(infoItem("        resets: \(glmState.r5h)"))
                }

                // Pro plan only — shown when a weekly reset window is present.
                if !glmState.rWeekly.isEmpty {
                    let iw = icon(for: glmState.qWeekly)
                    let uw = 100.0 - glmState.qWeekly
                    menu.addItem(infoItem("  \(iw) Weekly: used \(Int(uw))%  |  left \(Int(glmState.qWeekly))%"))
                    menu.addItem(infoItem("        resets: \(glmState.rWeekly)"))
                }

                menu.addItem(infoItem("  \(im) MCP: used \(Int(um))%  |  left \(Int(glmState.qMcp))%"))
                if !glmState.rMcp.isEmpty {
                    menu.addItem(infoItem("        resets: \(glmState.rMcp)"))
                }

                if glmState.tokens > 0 {
                    let t = fmtTokens(glmState.tokens)
                    menu.addItem(infoItem("  📊 Today: \(t) tokens  |  \(glmState.calls) calls"))
                    for m in glmState.models {
                        menu.addItem(infoItem("        \(m.name): \(fmtTokens(m.tokens))"))
                    }
                }
            } else if glmFailed {
                menu.addItem(infoItem("📡 GLM  ⚠️ 无数据(令牌过期或套餐不存在)"))
            }
        }

        // -- DeepSeek section --
        addTeamSection(to: menu)
        menu.addItem(.separator())
        if dsState.ok {
            menu.addItem(infoItem("📡 DeepSeek(个人)"))
            menu.addItem(infoItem("  💰 Balance: \(fmtMoney(dsState.balance, decimals: 2)) \(dsState.currency)"))
        } else if hasDS {
            menu.addItem(infoItem("📡 DeepSeek(个人)  ⚠️ No data"))
        }

        // -- Footer --
        addFooter(to: menu)
        statusItem.menu = menu
    }

    /// 团队看板段:无需任何 token,拉到就显示。今天的数还没出来时,在标签里注明实际日期。
    private func addTeamSection(to menu: NSMenu) {
        guard let team = teamState else { return }  // 启动后首拉完成前先不占位
        menu.addItem(.separator())
        if team.ok {
            menu.addItem(infoItem("📡 DeepSeek(团队)"))
            let label = team.todayFound ? "今日" : "今日(\(mmdd(team.displayDate))数据)"
            menu.addItem(infoItem("  📅 \(label): ¥\(fmtMoney(team.displayCost, decimals: 2))"))
            menu.addItem(infoItem("  📆 本月: 已用 ¥\(fmtMoney(team.monthUsed, decimals: 2)) / \(fmtMoney(TeamConfig.quota)) · 剩 ¥\(fmtMoney(team.quotaLeft, decimals: 2))"))
            if team.nearLimit {
                menu.addItem(infoItem("  ⚠️ 已用超 80%,接近月度上限"))
            }
            if !team.asofText.isEmpty {
                menu.addItem(infoItem("  🕐 \(team.asofText)"))
            }
        } else {
            menu.addItem(infoItem("📡 DeepSeek(团队)  ⚠️ \(team.errorText)"))
        }
    }

    /// yyyy-MM-dd → MM-dd
    private func mmdd(_ date: String) -> String {
        return TeamState.shortDate(date)
    }

    private func addFooter(to menu: NSMenu) {
        menu.addItem(.separator())
        if fetchFailed {
            menu.addItem(infoItem("⚠️ 上次刷新部分失败,显示为最近一次成功值"))
        }
        if let updatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let ts = formatter.string(from: updatedAt)
            menu.addItem(infoItem("🕐 Updated: \(ts)"))
        }
        if glmPausedHint {
            // weekly 耗尽时 5h 也被置零,暂停到的是 weekly 重置,提示用对应时间
            let resumeAt = (!glmState.rWeekly.isEmpty && glmState.qWeekly <= 0)
                ? glmState.rWeekly : glmState.r5h
            menu.addItem(infoItem("⏸ GLM 额度用尽,仅暂停 GLM 刷新至 \(resumeAt)"))
        }
        let glmToggle = NSMenuItem(title: "显示 GLM", action: #selector(onToggleGLM(_:)), keyEquivalent: "")
        glmToggle.target = self
        glmToggle.state = showGLM ? .on : .off
        menu.addItem(glmToggle)
        let dsToggle = NSMenuItem(title: "标题栏显示团队数据", action: #selector(onToggleDSTeam(_:)), keyEquivalent: "")
        dsToggle.target = self
        dsToggle.state = showDSTeam ? .on : .off
        menu.addItem(dsToggle)
        menu.addItem(actionItem("🔄 Refresh", action: #selector(onRefresh)))
        menu.addItem(actionItem("🔑 Reload tokens", action: #selector(onReloadTokens)))
        menu.addItem(actionItem("🚪 Quit", action: #selector(onQuit)))
    }

    // MARK: - Menu item factories

    // Informational items stay enabled with a no-op action, so NSMenuItem
    // renders them as normal (system-text-color) items — matching rumps, which
    // gives info items a callback for exactly this reason. A disabled item
    // would render grayed-out.
    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(nop(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func onRefresh(_ sender: Any?) {
        refreshAction(sender)
    }

    // No-op selector for informational (non-interactive) menu items.
    @objc private func nop(_ sender: Any?) { }

    @objc private func onReloadTokens(_ sender: Any?) {
        reloadSecrets()
        refreshAction(sender)
    }

    @objc private func onToggleGLM(_ sender: Any?) {
        showGLM.toggle()
        UserDefaults.standard.set(showGLM, forKey: "show_glm")
        rebuildMenu()
        // 开=立即拉一轮补上 GLM 数据;关=刷新让标题栏立刻只显示 DS 段
        refreshAction(sender)
    }

    @objc private func onToggleDSTeam(_ sender: Any?) {
        showDSTeam.toggle()
        UserDefaults.standard.set(showDSTeam, forKey: "show_ds_team")
        // 两份数据每轮都在拉,切换纯渲染即可,不重拉
        rebuildMenu()
    }

    @objc private func onQuit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}

// Expose the secrets file path for the "no token" error message
extension SecretsLoader {
    static var secretsFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zsh/ai-secrets.env").path
    }
}
