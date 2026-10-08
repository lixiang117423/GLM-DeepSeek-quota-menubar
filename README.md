# AI Quota MenuBar

macOS 菜单栏小工具,实时查看 **GLM(智谱)** 与 **DeepSeek** 的用量和余额。
原生 **Swift + AppKit** 实现,零第三方依赖。

菜单栏标题示例:

```
GLM🟢82% 🟡94% | DS🟡¥37.6 剩¥206.00
```

> 前两段为 5 小时配额与每周配额(Pro 会员);非 Pro 会员只显示 5h。
> `DS` 段默认是团队看板里本人(李详)的**今日费用**和**本月剩余额度**(两位小数),图标按剩余额度比例变色;菜单里取消勾选「标题栏显示团队数据」可切换为个人 API 余额(如 `DS🟡¥37.60`)。

## 功能

**GLM**
- 5 小时滚动 token 配额(已用 / 剩余百分比,绿/黄/红指示)
- 每周 token 配额(Pro 会员)
- MCP / 时长配额
- 配额重置时间
- 当日 token 消耗、调用次数及各模型明细

**DeepSeek**
- **团队看板**(公司 Key,主显示):当日费用、本月已用 / 剩余额度(¥600/月,超 80% 菜单里警告)
  - 数据来自领导维护的局域网看板(只读拉取,无需 API Key,按名字认领本人条目)
  - 口径与 `deepseeq-token-money` 项目的 `my_usage.js` 一致:按看板原始自然日直读(今天 09-14 就显示 09-14),本月合计已与看板 `months` 字段核对吻合
  - 看板服务端有 1 小时缓存;顶栏拉取带 `force=1` 穿透缓存,与 web 端刷新按钮同为实时口径(**每 5 分钟一次,已与看板维护者确认**);上游查询慢时(实测 ~20s)自动降级读该缓存,避免标题空白
- **个人 API**:账户余额(CNY),默认在下拉菜单;菜单里可切换显示到标题栏
- > 团队数据额度常量 ¥600 写在 `swift/Sources/GlmQuotaMenubar/Models.swift` 的 `TeamConfig.quota`;调整额度时 `my_usage.html`、`my_usage.js` 里的同名常量要一起改(三处暂无共享文件)

**其它**
- 自动刷新:GLM/DeepSeek/团队看板统一**每 5 分钟**一轮;23:00–08:00 视为休息时段跳过
- GLM 额度耗尽时**只暂停 GLM 拉取**(到重置点自动恢复),DeepSeek/团队数据照常刷新
- 不用 GLM 时可在菜单里取消勾选 **显示 GLM**:标题栏和菜单都不再出现 GLM 段,也不再调用 GLM 接口(状态持久化,重启保留)
- 网络请求在**后台线程**执行,不会卡住菜单栏
- 请求失败时**保留上一次的有效数据**,不会清空显示
- 菜单里点 **Quit** 能真正退出(launchd 仅在崩溃时才自动重启)

## 目录结构

```
.
├── swift/                               # Swift 原生实现(主版本)
│   ├── Sources/GlmQuotaMenubar/         # main / AppDelegate / MenuBarController /
│   │                                    # ApiService / SecretsLoader / Models
│   ├── Makefile                         # make build | run | install | uninstall
│   ├── run.sh                           # 独立启动 / 安装入口
│   └── com.lixiang.glm-quota-menubar.plist
├── run.sh                               # 根入口(自动编译 swift/ 并安装)
├── com.lixiang.glm-quota-menubar.plist  # launchd 模板(指向 swift 二进制)
├── glm_quota_menubar.py                 # 旧 Python + rumps 版本(保留作参考)
└── README.md
```

## 依赖

- macOS
- Swift 命令行工具(Xcode Command Line Tools 自带 `swiftc`,无需安装 Xcode)
- 零第三方库,纯系统 AppKit

> 注:当前 macOS beta 上 Swift Package Manager 的 manifest 编译有问题,故直接用 `swiftc` 编译,不依赖 SPM。

## 配置 API Token

把 key 写入 `~/.config/zsh/ai-secrets.env`(路径写死在 `swift/Sources/GlmQuotaMenubar/SecretsLoader.swift`):

```sh
export ANTHROPIC_AUTH_TOKEN_GLM="你的智谱 api key"
export ANTHROPIC_AUTH_TOKEN_DEEPSEEK="你的 deepseek api key"
```

> 变量名沿用 `ANTHROPIC_AUTH_TOKEN_*` 前缀,仅为兼容既有配置,实际放的是对应平台的 key。

## 运行

仓库里**没有写死任何用户路径**。首次运行 `run.sh` 会自动用 `swiftc` 编译出二进制(`swift/.build/glm-quota-menubar`),之后直接复用。

### 手动启动

```sh
./run.sh
```

后台运行,日志在 `/tmp/glm-quota-menubar.log`。

### 开机自启(launchd)

```sh
./run.sh --install     # 安装(自动把本机绝对路径写入 plist)
./run.sh --uninstall   # 卸载
```

`--install` 会以模板方式把 `__BINARY__` 替换为本机实际路径——因为 launchd 不展开 `~` 和环境变量,plist 必须是绝对路径。

也可以单独在 `swift/` 里用 `make`:

```sh
cd swift
make build        # 仅编译
make run          # 手动启动
make install      # 安装 launchd 自启
make uninstall    # 卸载
```

## 已知限制

- 团队看板数据非实时:新鲜度取决于领导的导出频率和看板 1 小时缓存;今天的费用是持续累计中的实时值,和领导看板一致
- 看板地址 `10.33.44.42:8088` 写死在 `TeamConfig.dashboardURL`,领导换 IP/端口时改这一处
- GLM 当日用量按本机时区的“今天”统计;若机器时区与北京时间不一致,边界可能有偏差
- 夜间 23:00–08:00 不刷新

## License

MIT
