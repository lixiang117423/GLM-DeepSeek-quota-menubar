import AppKit

// MARK: - Formatting helpers

private func icon(for pct: Double) -> String {
    if pct <= 10 { return "\u{1F534}" }   // red
    if pct <= 50 { return "\u{1F7E1}" }   // yellow
    return "\u{1F7E2}"                     // green
}

private func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000.0) }
    if n >= 1_000 { return "\(n / 1_000)K" }
    return "\(n)"
}

private func fmtMoney(_ v: Double, decimals: Int = 0) -> String {
    if decimals <= 0 { return "\(Int(v))" }
    return String(format: "%.\(decimals)f", v)
}

// MARK: - Menu bar controller

class MenuBarController {
    private let statusItem: NSStatusItem
    private var secrets: [String: String] = [:]
    private var glmState = GLMState()
    private var dsState = DSState()
    private var updatedAt: Date?
    private var fetchFailed = false

    private let refreshAction: (_ sender: Any?) -> Void

    init(refreshAction: @escaping (_ sender: Any?) -> Void) {
        self.refreshAction = refreshAction
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI"
        reloadSecrets()
    }

    /// Re-read the secrets file (called on startup and on "Reload tokens")
    func reloadSecrets() {
        secrets = SecretsLoader.load()
        rebuildMenu()
    }

    /// Apply fetched data to the UI
    func applyFetch(glm: GLMState, ds: DSState, failed: Bool) {
        glmState = glm
        dsState = ds
        fetchFailed = failed
        updatedAt = Date()
        rebuildMenu()
    }

    /// 5h quota exhausted and the window hasn't reset yet → refreshing is
    /// pointless (result stays 0%), so the auto-timer should skip. Manual
    /// Refresh bypasses this. Resume happens automatically once now >= reset.
    func shouldSkipAutoRefresh() -> Bool {
        guard glmState.ok, glmState.q5h <= 0, let reset = glmState.reset5h else {
            return false
        }
        return Date() < reset
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
            addFooter(to: menu)
            statusItem.menu = menu
            return
        }

        // Title bar — GLM 5h quota, plus weekly quota when present (Pro plan).
        if glmState.ok {
            var title = "GLM\(icon(for: glmState.q5h))\(Int(glmState.q5h))%"
            if !glmState.rWeekly.isEmpty {
                title += " | \(icon(for: glmState.qWeekly))\(Int(glmState.qWeekly))%"
            }
            statusItem.button?.title = title
        } else {
            statusItem.button?.title = "AI"
        }
        // To restore DS to title bar, uncomment the block below and comment the 4 lines above:
        // var parts: [String] = []
        // if glmState.ok { parts.append("GLM\(icon(for: glmState.q5h))\(Int(glmState.q5h))%") }
        // if dsState.ok { parts.append("DS💰\(fmtMoney(dsState.balance))") }
        // statusItem.button?.title = parts.isEmpty ? "AI" : parts.joined(separator: " | ")

        // -- GLM section --
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
        }

        // -- DeepSeek section --
        menu.addItem(.separator())
        if dsState.ok {
            menu.addItem(infoItem("📡 DeepSeek"))
            menu.addItem(infoItem("  💰 Balance: \(fmtMoney(dsState.balance, decimals: 2)) \(dsState.currency)"))
        } else if hasDS {
            menu.addItem(infoItem("📡 DeepSeek  ⚠️ No data"))
        }

        // -- Footer --
        addFooter(to: menu)
        statusItem.menu = menu
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
        if shouldSkipAutoRefresh() {
            menu.addItem(infoItem("⏸ 额度已用尽,暂停自动刷新至 \(glmState.r5h)"))
        }
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
