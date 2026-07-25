#!/usr/bin/env python3
"""
AI Quota — macOS menu bar monitor for GLM + DeepSeek.

GLM:  5h quota, MCP quota, daily token consumption
DeepSeek: account balance (daily usage requires platform login, not API key)

Refreshes every 5 minutes. Network calls run on a background thread so the
menu bar never blocks on a slow API response.
"""

import json
import ssl
import sys
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import rumps

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SECRETS_FILE = Path.home() / ".config" / "zsh" / "ai-secrets.env"
REFRESH_MINUTES = 2
GLM_BASE = "https://open.bigmodel.cn"
DEEPSEEK_API = "https://api.deepseek.com"


def load_secrets() -> dict[str, str]:
    tokens: dict[str, str] = {}
    if not SECRETS_FILE.exists():
        return tokens
    for line in SECRETS_FILE.read_text().splitlines():
        line = line.strip()
        if not line.startswith("export "):
            continue
        if "ANTHROPIC_AUTH_TOKEN_GLM" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                tokens["glm"] = parts[1].strip().strip('"').strip("'")
        elif "ANTHROPIC_AUTH_TOKEN_DEEPSEEK" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                tokens["deepseek"] = parts[1].strip().strip('"').strip("'")
    return tokens


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

_SSL_CTX = ssl.create_default_context()


def _api_get(url: str, token: str) -> dict | None:
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10, context=_SSL_CTX) as resp:
            body = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        print(f"[API] {exc}", file=sys.stderr)
        return None
    return body


# ---------------------------------------------------------------------------
# GLM API
# ---------------------------------------------------------------------------

def fetch_glm_quota(token: str) -> dict | None:
    data = _api_get(f"{GLM_BASE}/api/monitor/usage/quota/limit", token)
    if data and data.get("code") == 200 and data.get("success"):
        return data["data"]
    return None


def fetch_glm_daily(token: str) -> dict | None:
    today = datetime.now().strftime("%Y-%m-%d")
    url = (f"{GLM_BASE}/api/monitor/usage/model-usage"
           f"?startTime={today}%2000:00:00&endTime={today}%2023:59:59")
    data = _api_get(url, token)
    if data and data.get("code") == 200 and data.get("success"):
        return data["data"]
    return None


# ---------------------------------------------------------------------------
# DeepSeek API
# ---------------------------------------------------------------------------

def fetch_deepseek_balance(token: str) -> dict | None:
    data = _api_get(f"{DEEPSEEK_API}/user/balance", token)
    if data and data.get("is_available") is True:
        return data
    return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def _fmt_balance(v: float) -> str:
    """For menu bar title: emoji + integer."""
    return f"\U0001f4b0{int(v)}"


def _fmt_amount(v: float) -> str:
    """For dropdown: integer only (emoji is in the label)."""
    return str(int(v))


def _icon(pct: float) -> str:
    if pct <= 10:
        return "\U0001f534"  # red circle
    if pct <= 50:
        return "\U0001f7e1"  # yellow circle
    return "\U0001f7e2"      # green circle


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

class GLMState:
    def __init__(self):
        self.ok = False
        self.q_5h = 0.0
        self.r_5h = ""
        self.q_mcp = 0.0
        self.r_mcp = ""
        self.tokens = 0
        self.calls = 0
        self.models: list[dict] = []

    @staticmethod
    def from_api(quota: dict | None, daily: dict | None) -> "GLMState":
        s = GLMState()
        if not quota:
            return s
        s.ok = True
        for lim in quota.get("limits", []):
            lt = lim.get("type", "")
            rp = 100.0 - float(lim.get("percentage", 0))
            rst = ""
            if lim.get("nextResetTime"):
                try:
                    dt = datetime.fromtimestamp(
                        int(lim["nextResetTime"]) / 1000, tz=timezone.utc
                    )
                    rst = dt.astimezone().strftime("%m-%d %H:%M")
                except (ValueError, OSError):
                    pass
            if lt == "TOKENS_LIMIT":
                s.q_5h = rp
                s.r_5h = rst
            elif lt == "TIME_LIMIT":
                s.q_mcp = rp
                s.r_mcp = rst
        if daily:
            tu = daily.get("totalUsage", {})
            s.tokens = tu.get("totalTokensUsage", 0)
            s.calls = tu.get("totalModelCallCount", 0)
            s.models = [
                {"name": m.get("modelName", "?"), "tokens": m.get("totalTokens", 0)}
                for m in tu.get("modelSummaryList", [])
            ]
        return s


class DSState:
    def __init__(self):
        self.ok = False
        self.balance = 0.0
        self.currency = "CNY"

    @staticmethod
    def from_api(data: dict | None) -> "DSState":
        s = DSState()
        if not data:
            return s
        total = 0.0
        currency = "CNY"
        for info in data.get("balance_infos", []):
            total += float(info.get("total_balance", 0))
            currency = info.get("currency", "CNY")
        if total > 0:
            s.ok = True
            s.balance = total
            s.currency = currency
        return s


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

class AIQuotaApp(rumps.App):
    def __init__(self):
        super().__init__(name="AI", title="AI", quit_button=None)
        self._secrets = load_secrets()
        self._glm = GLMState()
        self._ds = DSState()
        self._updated: datetime | None = None
        self._fetch_failed = False
        self._pending: tuple | None = None
        # polls _pending every 0.5s on the main thread — worker thread cannot
        # create rumps.Timer, because it schedules on the current run-loop,
        # and a daemon thread has none.
        self._apply_timer = rumps.Timer(self._apply_fetch, 0.5)

        self._timer = rumps.Timer(self._on_timer, interval=REFRESH_MINUTES * 60)

    def run(self, **kwargs):
        self._do_fetch()
        self._timer.start()
        self._apply_timer.start()
        super().run(**kwargs)

    def _on_timer(self, _sender=None):
        hour = datetime.now().hour
        if 23 <= hour or hour < 8:
            return  # sleep time — skip refresh
        self._do_fetch()

    # ---- fetch ----
    # urllib is synchronous; calling it on the rumps Timer / menu callback
    # thread would freeze the menu bar for up to the request timeout. So the
    # requests run on a worker thread. The worker only writes self._pending;
    # self._apply_timer (created on the main thread in __init__) polls that
    # flag every 0.5s and hands results to _rebuild on the main thread.

    def _do_fetch(self, _sender=None):
        threading.Thread(target=self._fetch_worker, daemon=True).start()

    def _fetch_worker(self):
        gt = self._secrets.get("glm")
        dt = self._secrets.get("deepseek")
        glm_new = self._glm
        ds_new = self._ds
        failed = False

        # Keep the last good state on failure instead of wiping the menu — a
        # single transient API error should not blank out the display.
        if gt:
            quota = fetch_glm_quota(gt)
            daily = fetch_glm_daily(gt)
            if quota is None:
                failed = True
            else:
                glm_new = GLMState.from_api(quota, daily)
        if dt:
            balance = fetch_deepseek_balance(dt)
            if balance is None:
                failed = True
            else:
                ds_new = DSState.from_api(balance)

        self._pending = (glm_new, ds_new, failed)

    def _apply_fetch(self, _sender=None):
        if self._pending is None:
            return
        glm_new, ds_new, failed = self._pending
        self._pending = None
        self._glm = glm_new
        self._ds = ds_new
        self._fetch_failed = failed
        self._updated = datetime.now()
        self._rebuild()

    # ---- dummy callback ----
    # All informational menu items use this no-op callback so NSMenuItem
    # renders them with the same text attributes as Refresh / Quit.

    def _nop(self, _sender=None):
        pass

    # ---- menu ----

    def _rebuild(self):
        self.menu.clear()
        nop = self._nop

        has_glm = bool(self._secrets.get("glm"))
        has_ds = bool(self._secrets.get("deepseek"))
        if not has_glm and not has_ds:
            self.title = "AI"
            self.menu.add(rumps.MenuItem(
                "⚠️ 未读取到 API token", callback=nop
            ))
            self.menu.add(rumps.MenuItem(
                f"  请配置 {SECRETS_FILE}", callback=nop
            ))
            self.menu.add(rumps.separator)
            self.menu.add(rumps.MenuItem(
                "\U0001f504 Refresh", callback=self._do_fetch
            ))
            self.menu.add(rumps.MenuItem(
                "\U0001f6aa Quit", callback=lambda _: rumps.quit_application()
            ))
            return

        # -- title --
        parts = []
        if self._glm.ok:
            parts.append(f"GLM{_icon(self._glm.q_5h)}{self._glm.q_5h:.0f}%")
        if self._ds.ok:
            parts.append(f"DS{_fmt_balance(self._ds.balance)}")
        self.title = " | ".join(parts) if parts else "AI"

        # -- GLM --
        if self._glm.ok:
            i5 = _icon(self._glm.q_5h)
            u5 = 100.0 - self._glm.q_5h
            im = _icon(self._glm.q_mcp)
            um = 100.0 - self._glm.q_mcp

            self.menu.add(rumps.MenuItem(
                f"\U0001f4e1 GLM", callback=nop
            ))

            self.menu.add(rumps.MenuItem(
                f"  {i5} 5h: used {u5:.0f}%  |  left {self._glm.q_5h:.0f}%",
                callback=nop,
            ))
            if self._glm.r_5h:
                self.menu.add(rumps.MenuItem(
                    f"        resets: {self._glm.r_5h}", callback=nop
                ))

            self.menu.add(rumps.MenuItem(
                f"  {im} MCP: used {um:.0f}%  |  left {self._glm.q_mcp:.0f}%",
                callback=nop,
            ))
            if self._glm.r_mcp:
                self.menu.add(rumps.MenuItem(
                    f"        resets: {self._glm.r_mcp}", callback=nop
                ))

            if self._glm.tokens > 0:
                t = _fmt_tokens(self._glm.tokens)
                self.menu.add(rumps.MenuItem(
                    f"  \U0001f4ca Today: {t} tokens  |  {self._glm.calls} calls",
                    callback=nop,
                ))
                for m in self._glm.models:
                    self.menu.add(rumps.MenuItem(
                        f"        {m['name']}: {_fmt_tokens(m['tokens'])}",
                        callback=nop,
                    ))

        # -- DeepSeek --
        self.menu.add(rumps.separator)
        if self._ds.ok:
            self.menu.add(rumps.MenuItem(
                f"\U0001f4e1 DeepSeek", callback=nop
            ))
            self.menu.add(rumps.MenuItem(
                f"  \U0001f4b0 Balance: {_fmt_amount(self._ds.balance)} {self._ds.currency}",
                callback=nop,
            ))
        elif has_ds:
            self.menu.add(rumps.MenuItem(
                "\U0001f4e1 DeepSeek  ⚠️ No data", callback=nop
            ))
        # no deepseek token configured -> omit the section entirely

        # -- footer --
        self.menu.add(rumps.separator)
        if self._fetch_failed:
            self.menu.add(rumps.MenuItem(
                "⚠️ 上次刷新部分失败,显示为最近一次成功值", callback=nop
            ))
        if self._updated:
            ts = self._updated.strftime("%H:%M:%S")
            self.menu.add(rumps.MenuItem(f"\U0001f552 Updated: {ts}", callback=nop))
        self.menu.add(rumps.MenuItem(
            "\U0001f504 Refresh", callback=self._do_fetch
        ))
        self.menu.add(rumps.MenuItem(
            "\U0001f6aa Quit", callback=lambda _: rumps.quit_application()
        ))


def main():
    AIQuotaApp().run()


if __name__ == "__main__":
    main()
