import Foundation

// Models.swift 的回归测试。编译运行:make test
// 覆盖两块纯逻辑:TeamState.fromApi(团队看板解析)和 GLMState.shouldSkipGLMFetch(额度耗尽判定)。

var failures = 0
var cases = 0
func check(_ label: String, _ cond: Bool) {
    cases += 1
    print("\(cond ? "✅" : "❌ FAIL") \(label)")
    if !cond { failures += 1 }
}

// MARK: - TeamState.fromApi

// 固定"今天"= 2026-09-16(夹具数据的记账日)。fromApi 默认用真实时钟,
// 夹具日期写死,不注入的话用例随真实日期漂移(2026-09-17 起就挂过)。
let fixedNow: Date = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return f.date(from: "2026-09-16 12:00")!
}()
func teamFrom(_ data: [String: Any]) -> TeamState {
    return TeamState.fromApi(data: data, name: "李详", now: fixedNow)
}

// 复现 2026-09-16 早上的真实场景:看板 key_daily 个人序列滞后于账户级 daily
func makeTeamData(accountTodayCost: Double) -> [String: Any] {
    return [
        "key_daily": [
            "李详": [
                ["date": "2026-09-14", "cost": 18.5],
                ["date": "2026-09-15", "cost": 21.32],
            ]
        ],
        "daily": [
            ["date": "2026-09-14", "cost": 228.53],
            ["date": "2026-09-15", "cost": 232.96],
            ["date": "2026-09-16", "cost": accountTodayCost],
        ]
    ]
}

// Case 1: 看板已覆盖今天、个人序列缺今天 → 判定今天 ¥0(2026-10-09 改)。
// 此前要求"全团队今天零用量"才敢判定,导致自己零消费但同事有消费的日子
// 标题退回显示最近一天的旧值(看起来像今天的数,2026-10-09 实际踩过)。
let s1 = teamFrom(makeTeamData(accountTodayCost: 20.87))
check("team: case1 ok", s1.ok)
check("team: 个人缺今天且看板覆盖今天 → ¥0 (实际 \(s1.displayCost))", s1.displayCost == 0)
check("team: 个人缺今天且看板覆盖今天 → todayFound=true (实际 \(s1.todayFound))", s1.todayFound == true)
check("team: 个人缺今天且看板覆盖今天 → displayDate=今天 (实际 \(s1.displayDate))", s1.displayDate == "2026-09-16")
check("team: 本月含昨天=39.82 (实际 \(s1.monthUsed))", abs(s1.monthUsed - 39.82) < 0.001)

// Case 2: 团队今天整体零用量,个人缺今天 → 照实显示 ¥0(与 case1 同一条规则)
let s2 = teamFrom(makeTeamData(accountTodayCost: 0.0))
check("team: 团队零用量时 displayCost=0 (实际 \(s2.displayCost))", s2.displayCost == 0)
check("team: 团队零用量时 todayFound=true (实际 \(s2.todayFound))", s2.todayFound == true)

// Case 2b: 看板还没导出到今天(数据截至 09-15)→ 无法判定今天,
// 退回最近一天并注明日期(标题只显示数值,日期在菜单里)
var d5 = makeTeamData(accountTodayCost: 20.87)
d5["daily"] = [
    ["date": "2026-09-14", "cost": 228.53],
    ["date": "2026-09-15", "cost": 232.96],
]
let s5 = teamFrom(d5)
check("team: 看板未覆盖今天时退回最近一天 (实际 \(s5.displayCost))", s5.displayCost == 21.32)
check("team: 看板未覆盖今天时 todayFound=false (实际 \(s5.todayFound))", s5.todayFound == false)
check("team: 看板未覆盖今天时 displayDate=09-15 (实际 \(s5.displayDate))", s5.displayDate == "2026-09-15")

// Case 3: 个人序列含今天 → 正常显示今天的数
var d3 = makeTeamData(accountTodayCost: 20.87)
d3["key_daily"] = ["李详": [["date": "2026-09-16", "cost": 7.09]]]
let s3 = teamFrom(d3)
check("team: 个人含今天时显示今日值 (实际 \(s3.displayCost))", abs(s3.displayCost - 7.09) < 1e-9)
check("team: 个人含今天时 todayFound=true", s3.todayFound)

// Case 4: 返回里没有 key_daily → 报错文案
let s4 = teamFrom(["daily": []])
check("team: 缺 key_daily 时 ok=false", !s4.ok)
check("team: 缺 key_daily 时有错误文案", !s4.errorText.isEmpty)

// MARK: - TeamConfig.usageURL

// 2026-09-16:看板服务端有 1 小时缓存,web 端刷新按钮走 force=1 拿实时数;
// app 不带 force 时拉到缓存快照,和领导 web 端对不上(实测差 ¥6.8/日)。
check("team: usageURL 带 force=1 穿透缓存", TeamConfig.usageURL.contains("force=1"))
check("team: usageURL 基于看板地址", TeamConfig.usageURL.hasPrefix(TeamConfig.dashboardURL))
check("team: usageURL 带 days 窗口", TeamConfig.usageURL.contains("days="))

// force=1 超时(上游查询慢,实测 ~20s)时的降级路径:走看板 1 小时缓存(实测 ~50ms)。
// 2026-10-08:标题栏空白事故——force=1 稳定 18-21s 超过 app 10s 超时,团队段整段消失。
check("team: cached URL 不带 force", !TeamConfig.usageURLCached.contains("force"))
check("team: cached URL 基于看板地址", TeamConfig.usageURLCached.hasPrefix(TeamConfig.dashboardURL))
check("team: cached URL 带 days 窗口", TeamConfig.usageURLCached.contains("days="))

// MARK: - GLMState.shouldSkipGLMFetch

let future = Date().addingTimeInterval(3600)
let past = Date().addingTimeInterval(-3600)

func glmState(ok: Bool, q5h: Double, reset5h: Date?, qWeekly: Double = 100, rWeekly: String = "", resetWeekly: Date? = nil) -> GLMState {
    var s = GLMState()
    s.ok = ok
    s.q5h = q5h
    s.reset5h = reset5h
    s.qWeekly = qWeekly
    s.rWeekly = rWeekly
    s.resetWeekly = resetWeekly
    return s
}

// weekly 耗尽未重置 → 跳过(weekly 耗尽时 5h 已被置零)
check("glm: weekly 耗尽未重置 → true",
      GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 0, reset5h: future, qWeekly: 0, rWeekly: "x", resetWeekly: future), now: Date()))
// weekly 耗尽但已过重置点 → 恢复拉取
check("glm: weekly 耗尽已重置 → false",
      !GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 50, reset5h: future, qWeekly: 0, rWeekly: "x", resetWeekly: past), now: Date()))
// 5h 耗尽未重置 → 跳过
check("glm: 5h 耗尽未重置 → true",
      GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 0, reset5h: future), now: Date()))
// 5h 耗尽但已过重置点 → 恢复拉取
check("glm: 5h 耗尽已重置 → false",
      !GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 0, reset5h: past), now: Date()))
// 额度正常 → 不跳过
check("glm: 额度正常 → false",
      !GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 50, reset5h: future), now: Date()))
// 还没拉到过数据(ok=false)→ 不跳过,必须先拉一轮
check("glm: 无数据 → false",
      !GLMState.shouldSkipGLMFetch(state: glmState(ok: false, q5h: 0, reset5h: future), now: Date()))
// 耗尽但缺重置时间 → 无法判定恢复点,不跳过
check("glm: 耗尽但无重置时间 → false",
      !GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 0, reset5h: nil), now: Date()))
// weekly 有余量 → 不跳过
check("glm: weekly 有余量 → false",
      !GLMState.shouldSkipGLMFetch(state: glmState(ok: true, q5h: 0, reset5h: nil, qWeekly: 30, rWeekly: "x", resetWeekly: future), now: Date()))

// MARK: - dsTitleSegment(标题栏 DeepSeek 段)

func makeDS(_ balance: Double) -> DSState {
    return DSState.fromApi(data: [
        "is_available": true,
        "balance_infos": [["total_balance": balance, "currency": "CNY"]],
    ])
}
let dsRich = makeDS(87.5)
check("ds: fixture ok (实际 \(dsRich.balance))", dsRich.ok)

// 团队模式:今日费用(1 位小数)+ 余额(2 位,团队月度剩余);s5=看板未覆盖今天,回退显示 09-15 的 21.32,余 600-39.82=560.18
// 标题栏一律缩写(OC/DS):全称只在下拉菜单里出现,标题栏放不下
check("title: 团队模式用 DS 缩写",
      dsTitleSegment(team: s5, ds: dsRich, showTeam: true) == "DS🟢¥21.3 余额¥560.18")

// 个人模式:只显示余额,2 位小数
check("title: 个人模式只显示余额",
      dsTitleSegment(team: s1, ds: dsRich, showTeam: false) == "DS🟢¥87.50")

// 个人余额阈值配色:<¥10 红、<¥50 黄、否则绿
check("title: 个人余额<¥10 红",
      dsTitleSegment(team: s1, ds: makeDS(8.5), showTeam: false) == "DS🔴¥8.50")
check("title: 个人余额<¥50 黄",
      dsTitleSegment(team: s1, ds: makeDS(49.9), showTeam: false) == "DS🟡¥49.90")

// 所选口径没数据时整段省略,不回落到另一口径(免得以为切过去了显示的还是旧口径)
check("title: 个人模式无个人数据 → nil(不回落团队)",
      dsTitleSegment(team: s1, ds: DSState(), showTeam: false) == nil)
check("title: 团队模式没拉到 → nil",
      dsTitleSegment(team: nil, ds: dsRich, showTeam: true) == nil)
check("title: 团队模式解析失败 → nil",
      dsTitleSegment(team: s4, ds: dsRich, showTeam: true) == nil)
// 反向同理:个人模式不受团队失败影响
check("title: 个人模式不受团队失败影响",
      dsTitleSegment(team: s4, ds: dsRich, showTeam: false) == "DS🟢¥87.50")

// MARK: - OCState.fromApi(OpenCode GO 解析)

// 夹具取自 2026-10-10 用真实 key 抓的响应;fetchOpenCodeUsage 返回的就是这个 usage 字典。
// 注意 percent 是"已用",app 一律显示"剩余",所以解析要取反。
func ocWindow(_ percent: Any, status: String = "ok",
              resetsAt: String = "2026-10-10T11:18:08.000Z") -> [String: Any] {
    return ["status": status, "percent": percent, "resetsAt": resetsAt]
}
func ocData(rolling: Any, weekly: Any, monthly: Any) -> [String: Any] {
    return ["rolling": rolling, "weekly": weekly, "monthly": monthly]
}
// 抓到的真实响应:三个窗口都是 0% 已用,各自的重置时刻不同
let ocFresh = OCState.fromApi(data: ocData(
    rolling: ocWindow(0, resetsAt: "2026-10-10T11:18:08.000Z"),
    weekly: ocWindow(0, resetsAt: "2026-10-12T00:00:00.000Z"),
    monthly: ocWindow(0, resetsAt: "2026-11-10T05:58:37.000Z")))
check("oc: 真实响应解析 ok", ocFresh.ok)
check("oc: 已用 0% → 剩 100% (实际 5h=\(ocFresh.rollingLeft) w=\(ocFresh.weeklyLeft) m=\(ocFresh.monthlyLeft))",
      ocFresh.rollingLeft == 100 && ocFresh.weeklyLeft == 100 && ocFresh.monthlyLeft == 100)

// 已用 12% → 剩 88%,$12 上限下剩 $10.56
let ocUsed = OCState.fromApi(data: ocData(
    rolling: ocWindow(12), weekly: ocWindow(40), monthly: ocWindow(3)))
check("oc: 5h 已用 12% → 剩 88% (实际 \(ocUsed.rollingLeft))", ocUsed.rollingLeft == 88)
check("oc: weekly 已用 40% → 剩 60% (实际 \(ocUsed.weeklyLeft))", ocUsed.weeklyLeft == 60)
check("oc: monthly 已用 3% → 剩 97% (实际 \(ocUsed.monthlyLeft))", ocUsed.monthlyLeft == 97)
check("oc: 5h 剩 $10.56 (实际 \(ocUsed.rollingUSD))", abs(ocUsed.rollingUSD - 10.56) < 1e-9)
check("oc: weekly 剩 $18.00 (实际 \(ocUsed.weeklyUSD))", abs(ocUsed.weeklyUSD - 18.0) < 1e-9)
check("oc: monthly 剩 $58.20 (实际 \(ocUsed.monthlyUSD))", abs(ocUsed.monthlyUSD - 58.2) < 1e-9)

// percent 字段各家返回类型不一致(GLM 那边就见过 Int/Double/String 混着来),统一走 toDouble
let ocStr = OCState.fromApi(data: ocData(
    rolling: ocWindow("12"), weekly: ocWindow(12.0), monthly: ocWindow(12)))
check("oc: percent 为字符串时同样解析 (实际 \(ocStr.rollingLeft))", ocStr.rollingLeft == 88)

// resetsAt 是 UTC ISO8601(带毫秒),解析成瞬时值后按本机时区显示
let isoFormatter = ISO8601DateFormatter()
isoFormatter.timeZone = TimeZone(identifier: "UTC")
check("oc: 5h 重置时刻解析为 2026-10-10T11:18:08Z",
      ocFresh.resetRolling == isoFormatter.date(from: "2026-10-10T11:18:08Z"))
check("oc: weekly 重置时刻解析为 2026-10-12T00:00:00Z",
      ocFresh.resetWeekly == isoFormatter.date(from: "2026-10-12T00:00:00Z"))
check("oc: monthly 重置时刻解析为 2026-11-10T05:58:37Z",
      ocFresh.resetMonthly == isoFormatter.date(from: "2026-11-10T05:58:37Z"))
// 显示串按 GLM 的 MM-dd HH:mm 惯例,长度固定 11(如 "10-10 19:18")
check("oc: 5h 重置串形如 MM-dd HH:mm (实际 \"\(ocFresh.rRolling)\")",
      ocFresh.rRolling.count == 11 && ocFresh.rRolling.contains("-") && ocFresh.rRolling.contains(":"))

// status != "ok":限流/耗尽窗口按已用满额处理,不能显示成"还有额度"
let ocBad = OCState.fromApi(data: ocData(
    rolling: ocWindow(5, status: "rate_limited"), weekly: ocWindow(0), monthly: ocWindow(0)))
check("oc: status!=ok 的窗口按耗尽处理 (实际 \(ocBad.rollingLeft))", ocBad.rollingLeft == 0)

// 越界 percent 夹到 0...100,避免负额度或 >100% 显示
let ocOver = OCState.fromApi(data: ocData(
    rolling: ocWindow(120), weekly: ocWindow(-5), monthly: ocWindow(50)))
check("oc: 已用 >100% → 剩 0 (实际 \(ocOver.rollingLeft))", ocOver.rollingLeft == 0)
check("oc: 已用 <0% → 剩 100 (实际 \(ocOver.weeklyLeft))", ocOver.weeklyLeft == 100)

// 缺窗口 / 空响应 / 顶层为 nil → ok=false。
// 宁可整段 ⚠️ 也不要显示成"🔴0%":三个窗口不知道哪个是缺的,零值会被误读成额度用尽
// (GLM 段曾因无解释地消失排查了一轮,2026-10-08)。
check("oc: data 为 nil → ok=false", !OCState.fromApi(data: nil).ok)
check("oc: 空字典 → ok=false", !OCState.fromApi(data: [:]).ok)
check("oc: 缺 weekly → ok=false", !OCState.fromApi(data: ["rolling": ocWindow(0), "monthly": ocWindow(0)]).ok)
check("oc: 缺 rolling → ok=false", !OCState.fromApi(data: ["weekly": ocWindow(0), "monthly": ocWindow(0)]).ok)
check("oc: 缺 monthly → ok=false", !OCState.fromApi(data: ["rolling": ocWindow(0), "weekly": ocWindow(0)]).ok)
// 窗口在但 resetsAt 缺失:百分比仍可信,照常解析,只是没有重置时间
let ocNoReset = OCState.fromApi(data: ocData(
    rolling: ["status": "ok", "percent": 10],
    weekly: ["status": "ok", "percent": 10],
    monthly: ["status": "ok", "percent": 10]))
check("oc: 无 resetsAt 仍解析百分比 (实际 \(ocNoReset.rollingLeft))", ocNoReset.rollingLeft == 90)
check("oc: 无 resetsAt 时重置串为空", ocNoReset.rRolling.isEmpty)
check("oc: 无 resetsAt 时重置瞬间为 nil", ocNoReset.resetRolling == nil)

// MARK: - ocTitleSegment(标题栏 OpenCode 段)

// 标题只放 5h + weekly(monthly 在菜单里)。标题栏一律缩写成 OC,
// 全称只在下拉菜单里出现 —— 与 dsTitleSegment 同一套惯例。
check("title: opencode 缩写成 OC",
      ocTitleSegment(ocFresh) == "OC🟢100% 🟢100%")
check("title: opencode 显示剩余而非已用",
      ocTitleSegment(ocUsed) == "OC🟢88% 🟢60%")
// 图标阈值沿用 icon(for:):≤10 红、≤50 黄、否则绿
check("title: opencode 低额度转黄/红",
      ocTitleSegment(OCState.fromApi(data: ocData(
        rolling: ocWindow(95), weekly: ocWindow(85), monthly: ocWindow(0))))
        == "OC🔴5% 🟡15%")
// 没拉到数据时整段省略(标题不出现 "OC0% 0%")
check("title: opencode 无数据 → nil", ocTitleSegment(OCState()) == nil)
check("title: opencode 解析失败 → nil",
      ocTitleSegment(OCState.fromApi(data: [:])) == nil)

print(failures == 0 ? "\nALL \(cases) PASS" : "\n\(failures)/\(cases) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
