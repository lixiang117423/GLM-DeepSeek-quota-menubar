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
check("title: 团队模式(有 GLM)用 DS 缩写",
      dsTitleSegment(team: s5, ds: dsRich, showTeam: true, showGLM: true) == "DS🟢¥21.3 余额¥560.18")
check("title: 团队模式(无 GLM)用全称",
      dsTitleSegment(team: s5, ds: dsRich, showTeam: true, showGLM: false) == "DeepSeek🟢¥21.3 余额¥560.18")

// 个人模式:只显示余额,2 位小数
check("title: 个人模式只显示余额",
      dsTitleSegment(team: s1, ds: dsRich, showTeam: false, showGLM: true) == "DS🟢¥87.50")
check("title: 个人模式(无 GLM)用全称",
      dsTitleSegment(team: s1, ds: dsRich, showTeam: false, showGLM: false) == "DeepSeek🟢¥87.50")

// 个人余额阈值配色:<¥10 红、<¥50 黄、否则绿
check("title: 个人余额<¥10 红",
      dsTitleSegment(team: s1, ds: makeDS(8.5), showTeam: false, showGLM: true) == "DS🔴¥8.50")
check("title: 个人余额<¥50 黄",
      dsTitleSegment(team: s1, ds: makeDS(49.9), showTeam: false, showGLM: true) == "DS🟡¥49.90")

// 所选口径没数据时整段省略,不回落到另一口径(免得以为切过去了显示的还是旧口径)
check("title: 个人模式无个人数据 → nil(不回落团队)",
      dsTitleSegment(team: s1, ds: DSState(), showTeam: false, showGLM: true) == nil)
check("title: 团队模式没拉到 → nil",
      dsTitleSegment(team: nil, ds: dsRich, showTeam: true, showGLM: true) == nil)
check("title: 团队模式解析失败 → nil",
      dsTitleSegment(team: s4, ds: dsRich, showTeam: true, showGLM: true) == nil)
// 反向同理:个人模式不受团队失败影响
check("title: 个人模式不受团队失败影响",
      dsTitleSegment(team: s4, ds: dsRich, showTeam: false, showGLM: true) == "DS🟢¥87.50")

print(failures == 0 ? "\nALL \(cases) PASS" : "\n\(failures)/\(cases) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
